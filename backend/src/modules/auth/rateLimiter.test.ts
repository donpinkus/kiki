import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Redis stub that implements just enough of ioredis to back the rate limiter:
 *   - hset/hget for session rows (used to derive active-pod count)
 *   - zadd / zcount / zcard / zremrangebyscore / zrangebyscore / zrange
 *   - multi() pipeline with exec()
 *
 * Keep it dumb — each method reads/writes the in-memory `store`/`zstore` maps.
 */

interface StoredSession {
  [field: string]: string;
}

const hashStore = new Map<string, StoredSession>();
// Sorted set: map<key, array<{ score, member }>> kept sorted by score ascending.
const zStore = new Map<string, Array<{ score: number; member: string }>>();

function getSortedSet(key: string): Array<{ score: number; member: string }> {
  let arr = zStore.get(key);
  if (!arr) {
    arr = [];
    zStore.set(key, arr);
  }
  return arr;
}

function parseScoreBound(bound: number | string): number {
  if (typeof bound === 'number') return bound;
  if (bound === '+inf') return Number.POSITIVE_INFINITY;
  if (bound === '-inf') return Number.NEGATIVE_INFINITY;
  return Number(bound);
}

class PipelineStub {
  private readonly ops: Array<() => unknown> = [];

  hset(key: string, fields: Record<string, string>): this {
    this.ops.push(() => {
      const row = hashStore.get(key) ?? {};
      Object.assign(row, fields);
      hashStore.set(key, row);
      return 1;
    });
    return this;
  }

  expire(_key: string, _seconds: number): this {
    this.ops.push(() => 1);
    return this;
  }

  zadd(key: string, score: number, member: string): this {
    this.ops.push(() => {
      const arr = getSortedSet(key);
      arr.push({ score, member });
      arr.sort((a, b) => a.score - b.score);
      return 1;
    });
    return this;
  }

  zremrangebyscore(key: string, min: number | string, max: number | string): this {
    this.ops.push(() => {
      const minN = parseScoreBound(min);
      const maxN = parseScoreBound(max);
      const arr = getSortedSet(key);
      const before = arr.length;
      const filtered = arr.filter((e) => e.score < minN || e.score > maxN);
      zStore.set(key, filtered);
      return before - filtered.length;
    });
    return this;
  }

  zcount(key: string, min: number | string, max: number | string): this {
    this.ops.push(() => {
      const minN = parseScoreBound(min);
      const maxN = parseScoreBound(max);
      const arr = getSortedSet(key);
      return arr.filter((e) => e.score >= minN && e.score <= maxN).length;
    });
    return this;
  }

  zcard(key: string): this {
    this.ops.push(() => getSortedSet(key).length);
    return this;
  }

  zrangebyscore(
    key: string,
    min: number | string,
    max: number | string,
    ..._extras: unknown[]
  ): this {
    this.ops.push(() => {
      const minN = parseScoreBound(min);
      const maxN = parseScoreBound(max);
      return getSortedSet(key)
        .filter((e) => e.score >= minN && e.score <= maxN)
        .map((e) => e.member);
    });
    return this;
  }

  zrange(key: string, start: number, stop: number, withScores?: string): this {
    this.ops.push(() => {
      const arr = getSortedSet(key);
      const normalizedStop = stop < 0 ? arr.length + stop : stop;
      const slice = arr.slice(start, normalizedStop + 1);
      if (withScores === 'WITHSCORES') {
        return slice.flatMap((e) => [e.member, String(e.score)]);
      }
      return slice.map((e) => e.member);
    });
    return this;
  }

  async exec(): Promise<Array<[Error | null, unknown]>> {
    return this.ops.map((fn) => [null, fn()] as [null, unknown]);
  }
}

vi.mock('../redis/client.js', () => ({
  getRedis: () => ({
    hget: async (key: string, field: string) => hashStore.get(key)?.[field] ?? null,
    multi: () => new PipelineStub(),
  }),
  ensureRedis: async () => {},
  setLogger: () => {},
}));

import { checkProvisionQuota, recordProvision } from './rateLimiter.js';

const SESSION_PREFIX = 'session:';

function setSessionState(userId: string, state: string): void {
  hashStore.set(`${SESSION_PREFIX}${userId}`, { sessionId: userId, state });
}

describe('checkProvisionQuota', () => {
  beforeEach(() => {
    hashStore.clear();
    zStore.clear();
    vi.unstubAllEnvs();
  });

  it('allows when the user has no active session and no history', async () => {
    const result = await checkProvisionQuota('user-1');
    expect(result.allowed).toBe(true);
  });

  it('rejects with too_many_active_pods when a ready session exists', async () => {
    setSessionState('user-2', 'ready');
    const result = await checkProvisionQuota('user-2');
    expect(result.allowed).toBe(false);
    expect(result.reason).toBe('too_many_active_pods');
  });

  it('rejects with too_many_active_pods when an active provisioning session exists', async () => {
    setSessionState('user-3', 'fetching_image');
    const result = await checkProvisionQuota('user-3');
    expect(result.allowed).toBe(false);
    expect(result.reason).toBe('too_many_active_pods');
  });

  it('allows when the session row exists but state is terminated', async () => {
    setSessionState('user-4', 'terminated');
    const result = await checkProvisionQuota('user-4');
    expect(result.allowed).toBe(true);
  });

  it('rejects with hourly_rate_exceeded after MAX_PROVISIONS_PER_HOUR recent provisions', async () => {
    // Default limit is 20. Record 20 within the last hour.
    for (let i = 0; i < 20; i++) {
      await recordProvision('user-5');
    }
    const result = await checkProvisionQuota('user-5');
    expect(result.allowed).toBe(false);
    expect(result.reason).toBe('hourly_rate_exceeded');
    expect(result.retryAfterSec).toBeGreaterThan(0);
  });

  it('does not count provisions older than 1 hour against the hourly window', async () => {
    const now = Date.now();
    const key = 'ratelimit:provisions:user-6';
    // Insert 20 entries 2h ago.
    const twoHoursAgo = now - 2 * 60 * 60 * 1000;
    const arr = getSortedSet(key);
    for (let i = 0; i < 20; i++) {
      arr.push({ score: twoHoursAgo + i, member: `${twoHoursAgo + i}:x${i}` });
    }
    arr.sort((a, b) => a.score - b.score);

    const result = await checkProvisionQuota('user-6');
    expect(result.allowed).toBe(true);
  });

  it('prunes entries older than 24h on every check', async () => {
    const now = Date.now();
    const key = 'ratelimit:provisions:user-7';
    const arr = getSortedSet(key);
    const twoDaysAgo = now - 2 * 24 * 60 * 60 * 1000;
    arr.push({ score: twoDaysAgo, member: `${twoDaysAgo}:stale` });
    arr.sort((a, b) => a.score - b.score);

    await checkProvisionQuota('user-7');

    // The prune step inside checkProvisionQuota should have deleted the stale entry.
    expect(getSortedSet(key)).toHaveLength(0);
  });
});

describe('recordProvision', () => {
  beforeEach(() => {
    hashStore.clear();
    zStore.clear();
  });

  it('adds an entry to the user history sorted set', async () => {
    await recordProvision('user-8');
    expect(getSortedSet('ratelimit:provisions:user-8')).toHaveLength(1);
  });

  it('generates unique members even when called in the same millisecond', async () => {
    // Pin Date.now to the same value for two calls.
    const fixedNow = 1_800_000_000_000;
    vi.spyOn(Date, 'now').mockReturnValue(fixedNow);

    await recordProvision('user-9');
    await recordProvision('user-9');

    const arr = getSortedSet('ratelimit:provisions:user-9');
    expect(arr).toHaveLength(2);
    const [first, second] = arr;
    expect(first?.member).not.toBe(second?.member);

    vi.restoreAllMocks();
  });
});
