/**
 * Per-user monthly fal image-generation spend budget (the free-tier cap).
 *
 * Each unsubscribed user gets `FREE_TIER_FAL_USD` of fal drawing spend per
 * calendar month (UTC). Test accounts (`users.is_test_account`) and active
 * subscribers (`users.subscription_status='active'`) are exempt. Spend is
 * accumulated PG-direct via an atomic increment (handles concurrent
 * sessions/devices) into `monthly_usage`; the month is computed in SQL per
 * call so a session spanning the month boundary self-heals and a new month
 * reads 0 (implicit reset).
 *
 * Replaces the old in-memory `entitlement` stub (which gated on GPU-seconds).
 */

import { config } from '../../config/index.js';
import { query } from '../../postgres/client.js';

/** fal realtime price — see documents/references/provider-config.md. */
export const RATE_USD_PER_SEC = 0.00194;

export interface FalBudgetStatus {
  allowed: boolean;
  exempt: boolean;
  spendUsd: number;
  capUsd: number;
}

/**
 * Add `usd` to the user's current-month spend and return the new running total.
 * Atomic upsert: concurrent sessions for the same user sum correctly and each
 * observes the shared post-increment total.
 */
export async function addMonthlySpendUsd(userId: string, usd: number): Promise<number> {
  const res = await query<{ fal_spend_usd: string }>(
    `INSERT INTO monthly_usage (user_id, month, fal_spend_usd)
     VALUES ($1, to_char(now() AT TIME ZONE 'utc', 'YYYY-MM'), $2)
     ON CONFLICT (user_id, month) DO UPDATE
       SET fal_spend_usd = monthly_usage.fal_spend_usd + EXCLUDED.fal_spend_usd,
           updated_at = now()
     RETURNING fal_spend_usd`,
    [userId, usd],
  );
  // NUMERIC comes back as a string from pg.
  return Number(res.rows[0]?.fal_spend_usd ?? 0);
}

/**
 * Gate check at session start. One round-trip: reads the user's exemption flags
 * and this month's spend. `allowed` is true for exempt users or when spend is
 * under the cap.
 */
export async function checkFalBudget(userId: string): Promise<FalBudgetStatus> {
  const capUsd = config.FREE_TIER_FAL_USD;
  const res = await query<{
    is_test_account: boolean;
    subscribed: boolean;
    spend: string;
  }>(
    // `subscribed` requires BOTH an active status AND an unexpired window. The
    // expiry check is the self-heal: if a renewal/expiry webhook is ever missed,
    // a lapsed subscription still loses its exemption once the timestamp passes.
    `SELECT u.is_test_account,
            (u.subscription_status = 'active' AND u.subscription_expires_at > now()) AS subscribed,
            COALESCE(m.fal_spend_usd, 0) AS spend
     FROM users u
     LEFT JOIN monthly_usage m
       ON m.user_id = u.user_id
      AND m.month = to_char(now() AT TIME ZONE 'utc', 'YYYY-MM')
     WHERE u.user_id = $1`,
    [userId],
  );
  const row = res.rows[0];
  // Unknown user (e.g. legacy/Redis-only id mid-cutover): treat as non-exempt
  // with zero spend — they'll get the full free tier, gated normally.
  const exempt = row ? row.is_test_account || row.subscribed : false;
  const spendUsd = row ? Number(row.spend) : 0;
  return { allowed: exempt || spendUsd < capUsd, exempt, spendUsd, capUsd };
}
