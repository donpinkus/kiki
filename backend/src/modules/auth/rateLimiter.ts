/**
 * Per-user provision-frequency rate limiting. Sliding-window hourly + daily
 * caps stored as a Redis sorted set keyed by userId. ZADD on each new
 * provision, ZCOUNT to check windows, ZREMRANGEBYSCORE to prune.
 *
 * Concurrent-pod protection (one user, one pod) is the orchestrator's job —
 * `inFlightProvisions` joins same-process callers, `getReusableFromRow`
 * reuses the existing pod for any caller whose Redis row is healthy. We
 * used to layer a binary "active session exists" check on top of that here,
 * but it produced false positives on reconnect-storm races between
 * `hasReadySession` and the active-count read, with no protection the
 * orchestrator path didn't already provide.
 */

import { getRedis } from '../redis/client.js';

const MAX_PROVISIONS_PER_HOUR = Number(process.env['RATE_LIMIT_MAX_PER_HOUR'] ?? 20);
const MAX_PROVISIONS_PER_24H = Number(process.env['RATE_LIMIT_MAX_PER_DAY'] ?? 100);

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const HISTORY_TTL_SECONDS = Math.ceil(DAY_MS / 1000) + 300;

const HISTORY_PREFIX = 'ratelimit:provisions:';

function historyKey(userId: string): string {
  return `${HISTORY_PREFIX}${userId}`;
}

export interface QuotaCheck {
  allowed: boolean;
  reason?: 'hourly_rate_exceeded' | 'daily_rate_exceeded';
  retryAfterSec?: number;
}

export async function checkProvisionQuota(userId: string): Promise<QuotaCheck> {
  const now = Date.now();
  const redis = getRedis();
  const key = historyKey(userId);

  // Prune anything older than the 24h window, then read counts for both
  // windows in a single pipeline to minimize round-trips.
  const dayCutoff = now - DAY_MS;
  const hourCutoff = now - HOUR_MS;

  const pipeline = redis.multi();
  pipeline.zremrangebyscore(key, 0, dayCutoff);
  pipeline.zcount(key, hourCutoff, '+inf');
  pipeline.zcard(key);
  pipeline.zrangebyscore(key, hourCutoff, '+inf', 'LIMIT', 0, 1);
  pipeline.zrange(key, 0, 0, 'WITHSCORES');
  const results = await pipeline.exec();

  if (!results) return { allowed: true };

  const hourCount = Number(results[1]?.[1] ?? 0);
  const dayCount = Number(results[2]?.[1] ?? 0);
  const oldestInHourArr = (results[3]?.[1] as string[] | undefined) ?? [];
  const oldestInDayArr = (results[4]?.[1] as string[] | undefined) ?? [];

  if (hourCount >= MAX_PROVISIONS_PER_HOUR) {
    const oldestTs = parseTimestamp(oldestInHourArr[0]) ?? now;
    return {
      allowed: false,
      reason: 'hourly_rate_exceeded',
      retryAfterSec: Math.max(1, Math.ceil((oldestTs + HOUR_MS - now) / 1000)),
    };
  }

  if (dayCount >= MAX_PROVISIONS_PER_24H) {
    const oldestTs = Number(oldestInDayArr[1] ?? now);
    return {
      allowed: false,
      reason: 'daily_rate_exceeded',
      retryAfterSec: Math.max(1, Math.ceil((oldestTs + DAY_MS - now) / 1000)),
    };
  }

  return { allowed: true };
}

/**
 * Record that we just kicked off a fresh provision. Adds a timestamp to the
 * user's sliding-window history so subsequent hourly/daily checks see it.
 */
export async function recordProvision(userId: string): Promise<void> {
  const now = Date.now();
  const key = historyKey(userId);
  // Member must be unique even if two provisions happen in the same ms.
  const member = `${now}:${Math.random().toString(36).slice(2, 10)}`;
  await getRedis().multi()
    .zadd(key, now, member)
    .expire(key, HISTORY_TTL_SECONDS)
    .exec();
}

function parseTimestamp(member: string | undefined): number | null {
  if (!member) return null;
  const ts = Number(member.split(':')[0]);
  return Number.isFinite(ts) ? ts : null;
}
