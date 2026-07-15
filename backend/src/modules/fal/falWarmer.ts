/**
 * fal keep-warm loop — keeps the hosted `fal-ai/flux-2/klein/realtime` pool
 * warm so a user's first stroke gets its first image in ~1s instead of the
 * ~2-3.5 min cold spin-up (measured 2026-07-13; see fal-spike/README.md).
 *
 * Why this exists: fal's marketplace pool scales to zero, warmth lapses in
 * under ~15 min of disuse, and during spin-up fal silently drops every input
 * (and closes the WS clean at ~30s). Nothing app-open-triggered can hide a
 * multi-minute warmup, so the only lever that makes first strokes fast is
 * keeping the pool warm before the user shows up. One warmer covers all
 * users — warmth is pool-level on fal's side (inferred from probes: a brand
 * new connection is served instantly once any prior connection warmed it).
 *
 * Mechanics per ping: open the realtime WS via the same `FalImageRelay` the
 * drawing path uses, send a tiny 64² gray JPEG at 1 step, wait for the first
 * returned frame, close. Warm pool → ~1-2s of billed open time. Cold pool →
 * the ping keeps re-sending (the relay lazily reconnects through fal's ~30s
 * closes) until the pool warms or `COLD_WAIT_MS` gives up. At the default
 * 4-min cadence this costs roughly $1-2/day — accepted for launch (decision
 * 2026-07-13); flip off any time from Insights → Ops or FAL_WARMER_ENABLED.
 *
 * Config: env (`FAL_WARMER_*`) seeds the `admin_config.fal_warmer` row at
 * boot if absent; after that the ROW is the runtime truth, re-read every
 * tick, so Kiki Insights (which shares this Postgres) edits it live with no
 * redeploy. Every ping is recorded to `fal_warmer_pings` (Insights charts
 * warm/cold history + billed time) and logged to Sentry as
 * `event:fal.warm_ping` — continuous production measurement of fal's pool
 * behavior, no manual probing needed.
 *
 * The warmer's spend is account-level (not attributed to any user) so it
 * deliberately does NOT touch `monthly_usage`.
 */
import type { FastifyBaseLogger } from 'fastify';

import { config } from '../../config/index.js';
import { query } from '../../postgres/client.js';
import { inBackgroundScope } from '../observability/scope.js';
import { recordFalConnection, WARM_THRESHOLD_MS } from './falConnectionLog.js';
import { FalImageRelay } from './falImageRelay.js';

/** 64×64 gray JPEG (690 bytes) — the warm-up input frame. Content is
 * irrelevant; it just has to be a valid img2img input. */
const WARM_JPEG = Buffer.from(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABQODxIPDRQSEBIXFRQYHjIhHhwcHj0sLiQySUBMS0dARkVQWnNiUFVtVkVGZIhlbXd7gYKBTmCNl4x9lnN+gXz/2wBDARUXFx4aHjshITt8U0ZTfHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHz/wAARCABAAEADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDdooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA//Z',
  'base64',
);

/** How often the loop wakes to re-read config and decide whether a ping is
 * due. Config edits from Insights take effect within one tick. */
const TICK_MS = 30_000;
/** Cold ping: re-send the warm frame this often while waiting (fal drops
 * inputs during spin-up and closes the WS ~30s in; each re-send rides the
 * relay's lazy reconnect). */
const COLD_RESEND_MS = 10_000;
/** Give up on a cold ping after this long. Spin-up measured ~2-3.5 min. */
const COLD_WAIT_MS = 5 * 60_000;
/** Prune ping history older than this on each insert. */
const RETENTION_DAYS = 14;

export interface WarmerConfig {
  enabled: boolean;
  intervalMs: number;
  offStartHour: number; // America/Los_Angeles, inclusive
  offEndHour: number; // exclusive
}

function envDefaults(): WarmerConfig {
  return {
    enabled: config.FAL_WARMER_ENABLED,
    intervalMs: config.FAL_WARMER_INTERVAL_MS,
    offStartHour: config.FAL_WARMER_OFF_START_HOUR,
    offEndHour: config.FAL_WARMER_OFF_END_HOUR,
  };
}

/** Seed the admin_config row from env defaults iff absent, then return the
 * stored value (malformed fields fall back per-field to env defaults so a
 * bad Insights write can never wedge the loop). */
async function loadConfig(): Promise<WarmerConfig> {
  const def = envDefaults();
  const res = await query<{ value: Partial<WarmerConfig> }>(
    `INSERT INTO admin_config (key, value)
     VALUES ('fal_warmer', $1)
     ON CONFLICT (key) DO UPDATE SET key = admin_config.key
     RETURNING value`,
    [JSON.stringify(def)],
  );
  const v = res.rows[0]?.value ?? {};
  return {
    enabled: typeof v.enabled === 'boolean' ? v.enabled : def.enabled,
    intervalMs:
      typeof v.intervalMs === 'number' && v.intervalMs >= TICK_MS ? v.intervalMs : def.intervalMs,
    offStartHour: isHour(v.offStartHour) ? v.offStartHour : def.offStartHour,
    offEndHour: isHour(v.offEndHour) ? v.offEndHour : def.offEndHour,
  };
}

function isHour(n: unknown): n is number {
  return typeof n === 'number' && Number.isInteger(n) && n >= 0 && n <= 24;
}

/** Current hour-of-day in America/Los_Angeles (DST-correct). */
function pacificHour(now: Date): number {
  return Number(
    new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Los_Angeles',
      hour: 'numeric',
      hour12: false,
    }).format(now),
  ) % 24; // Intl yields "24" for midnight in some ICU versions
}

/** True when `hour` falls in [start, end), with wraparound (e.g. 22→6)
 * supported. start === end means no off-window. */
export function inOffWindow(hour: number, start: number, end: number): boolean {
  if (start === end) return false;
  return start < end ? hour >= start && hour < end : hour >= start || hour < end;
}

interface PingResult {
  foundWarm: boolean | null;
  msToFirstFrame: number | null;
  openMs: number;
  error: string | null;
}

/** One keep-warm ping: open → tiny frame → first result → close. Re-sends
 * through cold spin-up (relay reconnects through fal's ~30s closes). */
async function ping(logger: FastifyBaseLogger): Promise<PingResult> {
  const relay = new FalImageRelay(config.FAL_KEY, {
    logger,
    ctx: { warmer: true },
    onConnection: (rec) => recordFalConnection('warmer', {}, rec, logger),
  });
  const started = Date.now();
  let resend: NodeJS.Timeout | null = null;
  try {
    const msToFirstFrame = await new Promise<number | null>((resolve) => {
      const deadline = setTimeout(() => resolve(null), COLD_WAIT_MS);
      relay.onMessage((_data, isBinary) => {
        if (!isBinary) return; // frame_meta — the binary follows
        clearTimeout(deadline);
        resolve(Date.now() - started);
      });
      relay.sendConfig({ prompt: 'warm-up ping', num_inference_steps: 1, image_size: 'square' });
      relay.sendFrame(WARM_JPEG);
      resend = setInterval(() => relay.sendFrame(WARM_JPEG), COLD_RESEND_MS);
      resend.unref?.();
    });
    return {
      foundWarm: msToFirstFrame === null ? null : msToFirstFrame < WARM_THRESHOLD_MS,
      msToFirstFrame,
      openMs: relay.cumulativeOpenMs(),
      error: msToFirstFrame === null ? 'no frame within cold-wait deadline' : null,
    };
  } catch (err) {
    return {
      foundWarm: null,
      msToFirstFrame: null,
      openMs: relay.cumulativeOpenMs(),
      error: (err as Error).message,
    };
  } finally {
    if (resend) clearInterval(resend);
    relay.close();
  }
}

let tickTimer: ReturnType<typeof setInterval> | null = null;
let lastPingAt = 0;
let pinging = false;

async function tick(logger: FastifyBaseLogger): Promise<void> {
  if (pinging) return; // a cold ping can outlast several ticks
  const cfg = await loadConfig();
  if (!cfg.enabled) return;
  const hour = pacificHour(new Date());
  if (inOffWindow(hour, cfg.offStartHour, cfg.offEndHour)) return;
  if (Date.now() - lastPingAt < cfg.intervalMs) return;

  pinging = true;
  lastPingAt = Date.now();
  try {
    const r = await ping(logger);
    logger.info(
      {
        event: 'fal.warm_ping',
        foundWarm: r.foundWarm,
        msToFirstFrame: r.msToFirstFrame,
        openMs: r.openMs,
        pingError: r.error,
      },
      `fal warm ping: ${r.foundWarm === null ? `failed (${r.error})` : r.foundWarm ? 'warm' : `was cold, warmed in ${r.msToFirstFrame}ms`}`,
    );
    await query(
      `INSERT INTO fal_warmer_pings (found_warm, ms_to_first_frame, open_ms, error)
       VALUES ($1, $2, $3, $4)`,
      [r.foundWarm, r.msToFirstFrame, r.openMs, r.error],
    );
    await query(
      `DELETE FROM fal_warmer_pings WHERE ts < now() - make_interval(days => $1)`,
      [RETENTION_DAYS],
    );
    await query(
      `DELETE FROM fal_connections WHERE opened_at < now() - interval '30 days'`,
    );
  } catch (err) {
    logger.warn({ event: 'fal.warm_ping', err: (err as Error).message }, 'fal warm ping errored');
  } finally {
    pinging = false;
  }
}

export function start(logger: FastifyBaseLogger): void {
  if (config.IMAGE_PROVIDER !== 'fal' || !config.FAL_KEY) return;
  void inBackgroundScope('fal_warmer', () => tick(logger));
  tickTimer = setInterval(() => void inBackgroundScope('fal_warmer', () => tick(logger)), TICK_MS);
  tickTimer.unref?.();
  logger.info({ event: 'fal.warmer_started' }, 'fal keep-warm loop armed');
}

export function stop(): void {
  if (tickTimer) {
    clearInterval(tickTimer);
    tickTimer = null;
  }
}
