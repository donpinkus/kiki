/**
 * Lambda ADVERTISED-capacity monitor — a free, read-only heartbeat that polls
 * `GET /instance-types` every ~2 min and records which (instance_type, region)
 * cells reported capacity. Feeds Kiki Insights → Capacity: a week-scale
 * picture of how often the GPUs we care about are gettable, so drought
 * patterns (time-of-day, region, type) are visible instead of anecdotal.
 *
 * COST: zero GPU spend — `/instance-types` launches nothing. Just one small
 * API call per tick and two tiny Postgres tables (14-day retention).
 *
 * NOT a reservation. Lambda's capacity flag has no depth (1 vs 100 both read
 * "available") and can be stale by seconds — a cell can show capacity yet
 * fail an actual launch. Ground truth for "did a user actually get a GPU"
 * stays `lambda_pool_events` (Fleet tab). This is the wide, cheap survey that
 * complements it.
 *
 * Every tick writes a row to `lambda_capacity_ticks` (so a type that had zero
 * capacity ALL week is a known-sampled 0%, not missing data) and one
 * `lambda_capacity_samples` row per available (type, region). 2-min cadence
 * matches the minute-scale flapping we've measured; finer buys nothing.
 */

import type { FastifyBaseLogger } from 'fastify';
import { config } from '../../config/index.js';
import { query } from '../../postgres/client.js';
import { inBackgroundScope } from '../observability/scope.js';
import { LambdaClient } from './client.js';

const TICK_MS = 2 * 60_000;
const RETENTION_DAYS = 14;

/** Types worth tracking: our image + video fallback lists, deduped. Tracking
 * only what we'd actually launch keeps the survey focused (and the table
 * small) while still covering every cell the pool sweep can pick. */
function trackedTypes(): string[] {
  return [
    ...new Set([
      ...config.LAMBDA_INSTANCE_TYPES,
      ...config.LAMBDA_VIDEO_INSTANCE_TYPES,
    ]),
  ];
}

let timer: NodeJS.Timeout | null = null;

async function tick(logger: FastifyBaseLogger): Promise<void> {
  if (!config.LAMBDA_API_KEY) return;
  const wanted = new Set(trackedTypes());
  let types: Awaited<ReturnType<LambdaClient['listInstanceTypes']>>;
  try {
    types = await new LambdaClient(config.LAMBDA_API_KEY).listInstanceTypes();
  } catch (err) {
    // A failed poll is a gap, not a zero — skip the tick entirely so the UI
    // never reads an API blip as a capacity drought.
    logger.warn({ err: (err as Error).message, event: 'lambda_capacity_poll_failed' }, 'capacity poll failed — skipping tick');
    return;
  }

  // Single shared timestamp so all rows of this tick align (the join key).
  const tickAt = new Date();
  const rows: Array<[string, string]> = [];
  for (const [typeName, entry] of Object.entries(types)) {
    if (!wanted.has(typeName)) continue;
    for (const region of entry.regions_with_capacity_available ?? []) {
      rows.push([typeName, region.name]);
    }
  }

  try {
    await query(
      `INSERT INTO lambda_capacity_ticks (tick_at, types_seen) VALUES ($1, $2)
       ON CONFLICT (tick_at) DO NOTHING`,
      [tickAt, wanted.size],
    );
    // Batch the sample rows in one multi-values insert (≤ a few dozen).
    if (rows.length > 0) {
      const values: string[] = [];
      const params: unknown[] = [tickAt];
      rows.forEach(([t, r], i) => {
        values.push(`($1, $${i * 2 + 2}, $${i * 2 + 3})`);
        params.push(t, r);
      });
      await query(
        `INSERT INTO lambda_capacity_samples (tick_at, instance_type, region)
         VALUES ${values.join(', ')} ON CONFLICT DO NOTHING`,
        params,
      );
    }
    // Retention prune (cheap on the ts indexes; runs each tick, idempotent).
    await query(`DELETE FROM lambda_capacity_samples WHERE tick_at < now() - interval '${RETENTION_DAYS} days'`);
    await query(`DELETE FROM lambda_capacity_ticks WHERE tick_at < now() - interval '${RETENTION_DAYS} days'`);
  } catch (err) {
    logger.warn({ err: (err as Error).message, event: 'lambda_capacity_write_failed' }, 'capacity write failed');
  }
}

export function start(logger: FastifyBaseLogger): void {
  if (!config.LAMBDA_API_KEY) {
    logger.info('lambda capacity monitor: no LAMBDA_API_KEY — inert');
    return;
  }
  // First tick shortly after boot, then every TICK_MS.
  void inBackgroundScope('lambda_capacity', () => tick(logger));
  timer = setInterval(() => void inBackgroundScope('lambda_capacity', () => tick(logger)), TICK_MS);
  timer.unref?.();
  logger.info({ types: trackedTypes(), event: 'lambda_capacity_monitor_started' }, 'lambda capacity monitor armed');
}

export function stop(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
