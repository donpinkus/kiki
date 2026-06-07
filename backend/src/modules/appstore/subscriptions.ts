/**
 * Subscription state writes derived from verified StoreKit transactions.
 *
 * One `applyTransaction` handles every subscription event (purchase, renewal,
 * expiry, refund, revoke, auto-renew toggle) because the correct state is fully
 * derivable from the transaction itself:
 *   - status  = (not revoked && expiresDate > now) ? 'active' : 'expired'
 *   - expiry  = expiresDate
 * This is simpler and more robust than a hand-maintained notificationType→action
 * table (which drifts as Apple adds types): the same formula yields `active` for
 * a renewal and `expired` for a refund (revocationDate set) or a lapse.
 *
 * Ordering/duplication: every transaction + notification carries `signedDate`
 * (ms). We apply only when the incoming `signedDate` is >= the last one we
 * stored (`subscription_last_signed_ms`), so a duplicate is idempotent and a
 * late-arriving stale notification can't regress a newer state.
 *
 * Self-healing: the fal-cap gate also requires `subscription_expires_at > now()`
 * (see falBudget/checkFalBudget), so even a missed EXPIRED notification denies
 * once the timestamp passes — the webhook is an optimization, not the sole
 * source of truth.
 */

import type { JWSTransactionDecodedPayload } from '@apple/app-store-server-library';

import { query } from '../../postgres/client.js';

export type SubscriptionStatus = 'none' | 'active' | 'expired';

export interface SubscriptionState {
  status: SubscriptionStatus;
  /** Subscription expiry, epoch ms, or null if never subscribed. */
  expiresAt: number | null;
}

interface StateRow {
  subscription_status: string;
  expires_ms: string | null;
}

/** Resolve the Kiki user that owns an Apple subscription, by its stable
 * `originalTransactionId`. Used by the (unauthenticated) webhook, which has no
 * JWT — the binding was established on the authenticated `/verify` call. */
export async function findUserByOriginalTransactionId(otid: string): Promise<string | null> {
  const res = await query<{ user_id: string }>(
    'SELECT user_id FROM users WHERE original_transaction_id = $1',
    [otid],
  );
  return res.rows[0]?.user_id ?? null;
}

function readState(row: StateRow | undefined): SubscriptionState {
  if (!row) return { status: 'none', expiresAt: null };
  return {
    status: (row.subscription_status as SubscriptionStatus) ?? 'none',
    expiresAt: row.expires_ms != null ? Number(row.expires_ms) : null,
  };
}

async function currentState(userId: string): Promise<SubscriptionState> {
  const res = await query<StateRow>(
    `SELECT subscription_status,
            (EXTRACT(EPOCH FROM subscription_expires_at) * 1000)::bigint AS expires_ms
       FROM users WHERE user_id = $1`,
    [userId],
  );
  return readState(res.rows[0]);
}

/**
 * Apply a verified transaction to a user's row and return the resulting state.
 * Idempotent + order-safe via the `signedDate` guard: a stale event is a no-op
 * (we return the unchanged current state). Binds `original_transaction_id` the
 * first time (COALESCE) so the webhook can later resolve this user.
 */
export async function applyTransaction(
  userId: string,
  tx: JWSTransactionDecodedPayload,
): Promise<SubscriptionState> {
  const expiresMs = tx.expiresDate ?? 0;
  const signedMs = tx.signedDate ?? 0;
  const revoked = tx.revocationDate != null;
  const otid = tx.originalTransactionId ?? null;
  const status: SubscriptionStatus = !revoked && expiresMs > Date.now() ? 'active' : 'expired';

  const res = await query<StateRow>(
    `UPDATE users SET
        subscription_status = $2,
        subscription_expires_at = to_timestamp($3 / 1000.0),
        original_transaction_id = COALESCE(original_transaction_id, $4),
        subscription_last_signed_ms = $5,
        updated_at = now()
      WHERE user_id = $1
        AND $5 >= COALESCE(subscription_last_signed_ms, 0)
      RETURNING subscription_status,
                (EXTRACT(EPOCH FROM subscription_expires_at) * 1000)::bigint AS expires_ms`,
    [userId, status, expiresMs, otid, signedMs],
  );

  // No row updated → the guard rejected a stale/duplicate event (or the user
  // row is gone). Return the unchanged current state.
  if (res.rowCount === 0) return currentState(userId);
  return readState(res.rows[0]);
}
