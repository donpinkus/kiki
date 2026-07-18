/**
 * Runtime-editable config rows (`admin_config` table) — the pattern behind
 * every Kiki Insights → Ops dial: env vars SEED the row iff absent, the row
 * is the runtime truth, Insights writes it, and the backend re-reads it
 * periodically so changes apply without a redeploy.
 *
 * Consumers: `fal_warmer` (modules/fal/falWarmer.ts) and `video_generation`
 * (modules/video/videoFlag.ts). Each keeps its own per-field validation —
 * a malformed Insights write must fall back per-field, never wedge a loop.
 */

import { query } from '../../postgres/client.js';

/** Seed the row from `seed` iff absent (the ON CONFLICT no-op update makes
 * RETURNING yield the EXISTING value when the row is already there), then
 * return the stored value. Callers validate fields before trusting them. */
export async function seedAndReadAdminConfig<T>(key: string, seed: T): Promise<Partial<T>> {
  const res = await query<{ value: Partial<T> }>(
    `INSERT INTO admin_config (key, value)
     VALUES ($1, $2)
     ON CONFLICT (key) DO UPDATE SET key = admin_config.key
     RETURNING value`,
    [key, JSON.stringify(seed)],
  );
  return res.rows[0]?.value ?? {};
}
