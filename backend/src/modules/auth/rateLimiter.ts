/**
 * Per-user rate limiting for pod provisions.
 *
 * Simple in-memory token bucket. Two dimensions:
 *   - Max active pods per user (cap: 1)
 *   - Provisions per hour and per 24h (sliding window)
 *
 * When Workstream 5 (Redis) lands, this moves to Redis `INCR` + `EXPIRE` so
 * limits are consistent across backend replicas. For now (single Railway
 * instance) in-memory is correct.
 */

interface ProvisionHistory {
  timestamps: number[]; // ms epoch
  activePodCount: number;
}

const MAX_ACTIVE_PODS_PER_USER = Number(process.env['RATE_LIMIT_MAX_ACTIVE_PODS'] ?? 1);
const MAX_PROVISIONS_PER_HOUR = Number(process.env['RATE_LIMIT_MAX_PER_HOUR'] ?? 20);
const MAX_PROVISIONS_PER_24H = Number(process.env['RATE_LIMIT_MAX_PER_DAY'] ?? 100);

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

const userHistory = new Map<string, ProvisionHistory>();

function getOrCreate(userId: string): ProvisionHistory {
  let h = userHistory.get(userId);
  if (!h) {
    h = { timestamps: [], activePodCount: 0 };
    userHistory.set(userId, h);
  }
  return h;
}

function prune(h: ProvisionHistory, now: number): void {
  const cutoff = now - DAY_MS;
  h.timestamps = h.timestamps.filter((t) => t > cutoff);
}

export interface QuotaCheck {
  allowed: boolean;
  reason?: 'too_many_active_pods' | 'hourly_rate_exceeded' | 'daily_rate_exceeded';
  retryAfterSec?: number;
}

export function checkProvisionQuota(userId: string): QuotaCheck {
  const now = Date.now();
  const h = getOrCreate(userId);
  prune(h, now);

  if (h.activePodCount >= MAX_ACTIVE_PODS_PER_USER) {
    return { allowed: false, reason: 'too_many_active_pods' };
  }

  const hourCount = h.timestamps.filter((t) => t > now - HOUR_MS).length;
  if (hourCount >= MAX_PROVISIONS_PER_HOUR) {
    const oldestInHour = h.timestamps.find((t) => t > now - HOUR_MS) ?? now;
    return {
      allowed: false,
      reason: 'hourly_rate_exceeded',
      retryAfterSec: Math.ceil((oldestInHour + HOUR_MS - now) / 1000),
    };
  }

  const dayCount = h.timestamps.length;
  if (dayCount >= MAX_PROVISIONS_PER_24H) {
    const oldestInDay = h.timestamps[0] ?? now;
    return {
      allowed: false,
      reason: 'daily_rate_exceeded',
      retryAfterSec: Math.ceil((oldestInDay + DAY_MS - now) / 1000),
    };
  }

  return { allowed: true };
}

export function registerProvision(userId: string): void {
  const h = getOrCreate(userId);
  h.timestamps.push(Date.now());
  h.activePodCount += 1;
}

export function releaseActivePod(userId: string): void {
  const h = userHistory.get(userId);
  if (!h) return;
  h.activePodCount = Math.max(0, h.activePodCount - 1);
}

export function getActivePodCount(userId: string): number {
  return userHistory.get(userId)?.activePodCount ?? 0;
}
