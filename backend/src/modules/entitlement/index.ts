/**
 * Free-hour + subscription entitlement gate.
 *
 * v1 scope (this module): tracks per-user cumulative GPU-seconds consumed,
 * enforces the 1-hour free tier. The paid subscription side (Apple IAP +
 * receipt validation) is stubbed — `subscriptionActive` always returns false
 * — and will be wired in Workstream 8.
 *
 * Storage: in-memory Map. Moves to Redis with Workstream 5 so deploys don't
 * reset everyone's free-hour budget.
 */

import { config } from '../../config/index.js';

interface UserLedger {
  freeSecondsUsed: number;
  subscriptionActive: boolean;
  subscriptionExpiresAt?: number;
}

const ledger = new Map<string, UserLedger>();

function getOrCreate(userId: string): UserLedger {
  let u = ledger.get(userId);
  if (!u) {
    u = { freeSecondsUsed: 0, subscriptionActive: false };
    ledger.set(userId, u);
  }
  return u;
}

export interface EntitlementStatus {
  allowed: boolean;
  reason?: 'free_exhausted' | 'subscription_expired';
  freeSecondsRemaining: number;
  subscriptionActive: boolean;
}

export function checkEntitlement(userId: string): EntitlementStatus {
  const u = getOrCreate(userId);
  const freeSecondsRemaining = Math.max(0, config.FREE_TIER_SECONDS - u.freeSecondsUsed);

  if (u.subscriptionActive) {
    if (u.subscriptionExpiresAt && u.subscriptionExpiresAt < Date.now()) {
      // Expired — WS8's webhook should have flipped this already, but belt & suspenders
      u.subscriptionActive = false;
    } else {
      return { allowed: true, freeSecondsRemaining, subscriptionActive: true };
    }
  }

  if (freeSecondsRemaining > 0) {
    return { allowed: true, freeSecondsRemaining, subscriptionActive: false };
  }

  return {
    allowed: false,
    reason: u.subscriptionExpiresAt ? 'subscription_expired' : 'free_exhausted',
    freeSecondsRemaining: 0,
    subscriptionActive: false,
  };
}

/**
 * Called when a user's pod terminates (reaper, replacement, or session end).
 * Deducts the consumed uptime from the free-hour budget. Callers in Workstream 8
 * can distinguish "free tier consumed" vs "billed to subscription" for
 * reporting, but accounting is the same either way.
 */
export function recordUsage(userId: string, gpuSeconds: number): void {
  const u = getOrCreate(userId);
  if (!u.subscriptionActive) {
    u.freeSecondsUsed = Math.min(
      config.FREE_TIER_SECONDS,
      u.freeSecondsUsed + Math.max(0, gpuSeconds),
    );
  }
  // If subscription active, we don't decrement anything here — subscription
  // users have unlimited usage. Cost tracking happens in Workstream 4 via
  // RunPod billing data.
}

// ─────────────────────────────────────────────────────────────────────────
// Workstream 8 will fill these in. For v1 we expose the surface so other
// code can call them without awaiting WS8.
// ─────────────────────────────────────────────────────────────────────────

export function setSubscriptionActive(
  userId: string,
  active: boolean,
  expiresAt?: number,
): void {
  const u = getOrCreate(userId);
  u.subscriptionActive = active;
  u.subscriptionExpiresAt = expiresAt;
}

export function getLedgerSnapshot(userId: string): UserLedger | undefined {
  return ledger.get(userId);
}
