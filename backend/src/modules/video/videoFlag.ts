/**
 * Video-generation feature flag — the Kiki Insights → Ops kill switch.
 *
 * Stored in the `admin_config.video_generation` Postgres row (seeded from the
 * `LAMBDA_VIDEO_POOL_ENABLED` env iff absent — env is the seed, the row is
 * the runtime truth, same pattern as `admin_config.fal_warmer`). Insights
 * writes the row; this module polls it every 60s and exposes a SYNC cached
 * read so hot paths (pool enabled() callback, per-connection session gating)
 * never wait on Postgres.
 *
 * Flag off means: the video pool drains (instancePool's disabled tick
 * terminates instances within ~60s), no new VideoSessions are created, and
 * the iPad hides all animation UX (the availability signal advertises
 * enabled=false). Flag on restores all of it within one poll+tick cycle.
 *
 * Fail-safe: when Postgres is unreachable the cache keeps its last-known
 * value (a DB blip must not flap the fleet); before the FIRST successful
 * load the env seed is used.
 */

import type { FastifyBaseLogger } from 'fastify';
import { config } from '../../config/index.js';
import { query } from '../../postgres/client.js';
import { inBackgroundScope } from '../observability/scope.js';

const REFRESH_MS = 60_000;

let cached: boolean = config.LAMBDA_VIDEO_POOL_ENABLED;
let loadedOnce = false;
let timer: NodeJS.Timeout | null = null;

/** Sync read of the flag (cached; ≤60s stale). */
export function videoGenerationEnabled(): boolean {
  return cached;
}

/** Load from Postgres, seeding the row from env iff absent. */
export async function refreshVideoFlag(): Promise<boolean> {
  const res = await query<{ value: { enabled?: unknown } }>(
    `INSERT INTO admin_config (key, value)
     VALUES ('video_generation', $1)
     ON CONFLICT (key) DO UPDATE SET key = admin_config.key
     RETURNING value`,
    [JSON.stringify({ enabled: config.LAMBDA_VIDEO_POOL_ENABLED })],
  );
  const v = res.rows[0]?.value;
  cached = typeof v?.enabled === 'boolean' ? v.enabled : config.LAMBDA_VIDEO_POOL_ENABLED;
  loadedOnce = true;
  return cached;
}

export function startVideoFlag(logger: FastifyBaseLogger): void {
  const load = (): Promise<void> =>
    refreshVideoFlag()
      .then((enabled) => {
        if (!loadedOnce) logger.info({ enabled, event: 'video_flag_loaded' }, 'video flag loaded');
      })
      .catch((err: Error) => {
        logger.warn(
          { err: err.message, lastKnown: cached, event: 'video_flag_refresh_failed' },
          'video flag refresh failed — keeping last-known value',
        );
      });
  void inBackgroundScope('video_flag', load);
  timer = setInterval(() => void inBackgroundScope('video_flag', load), REFRESH_MS);
  timer.unref?.();
}

export function stopVideoFlag(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
