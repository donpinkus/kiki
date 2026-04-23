/**
 * Per-user rate limiting for pod provisions. Redis-backed so state survives
 * backend restarts and is consistent across replicas.
 *
 * Two dimensions:
 *   1. Active pods — derived from the orchestrator's session row. We don't
 *      keep a separate counter because that counter inevitably drifts from
 *      reality (early-return paths, idle-reaper terminations, crashes). The
 *      session row is the single source of truth.
 *   2. Provision frequency — sliding windows per hour and per day, stored as
 *      a Redis sorted set keyed by userId. ZADD on each new provision,
 *      ZCOUNT to check windows, ZREMRANGEBYSCORE to prune.
 *
 * Active-pod enforcement is checked in the orchestrator's `hasReadySession`
 * path (reconnect fast-path) + here for the provisioning case.
 */

import { getRedis } from '../redis/client.js';

const MAX_ACTIVE_PODS_PER_USER = Number(process.env['RATE_LIMIT_MAX_ACTIVE_PODS'] ?? 1);
const MAX_PROVISIONS_PER_HOUR = Number(process.env['RATE_LIMIT_MAX_PER_HOUR'] ?? 20);
const MAX_PROVISIONS_PER_24H = Number(process.env['RATE_LIMIT_MAX_PER_DAY'] ?? 100);

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const HISTORY_TTL_SECONDS = Math.ceil(DAY_MS / 1000) + 300;

const SESSION_PREFIX = 'session:';
const HISTORY_PREFIX = 'ratelimit:provisions:';

// Active states — non-terminal session states. A user with a session in any
// of these is considered to already have an active pod (skip rate limiting on
// reconnect). Mirrors the `State` enum in orchestrator.ts; duplicated here to
// avoid pulling the orchestrator's module graph into the auth layer.
const ACTIVE_STATES = new Set([
  'queued', 'finding_gpu', 'creating_pod', 'fetching_image', 'warming_model', 'ready',
]);

function historyKey(userId: string): string {
  return `${HISTORY_PREFIX}${userId}`;
}

function sessionKey(userId: string): string {
  return `${SESSION_PREFIX}${userId}`;
}

export interface QuotaCheck {
  allowed: boolean;
  reason?: 'too_many_active_pods' | 'hourly_rate_exceeded' | 'daily_rate_exceeded';
  retryAfterSec?: number;
}

async function getActiveSessionCount(userId: string): Promise<number> {
  const state = await getRedis().hget(sessionKey(userId), 'state');
  if (!state) return 0;
  return ACTIVE_STATES.has(state) ? 1 : 0;
}

export async function checkProvisionQuota(userId: string): Promise<QuotaCheck> {
  const now = Date.now();

  const activeCount = await getActiveSessionCount(userId);
  if (activeCount >= MAX_ACTIVE_PODS_PER_USER) {
    return { allowed: false, reason: 'too_many_active_pods' };
  }

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
 * Does NOT track "active pod count" — that's derived from the session row.
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
