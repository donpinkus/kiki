import { beforeEach, describe, expect, it, vi } from 'vitest';

import type * as RunpodClientModule from './runpodClient.js';

/**
 * In-memory stub for the Redis client used by the broker. Only `hset` / `hgetall`
 * are exercised — the broker writes via `patchSession` (multi/hset/expire/exec)
 * and reads via `readSession` (hgetall).
 */

interface StoredSession {
  [field: string]: string;
}

const store = new Map<string, StoredSession>();

class PipelineStub {
  private readonly ops: Array<() => unknown> = [];

  hset(key: string, fields: Record<string, string>): this {
    this.ops.push(() => {
      const row = store.get(key) ?? {};
      Object.assign(row, fields);
      store.set(key, row);
      return 1;
    });
    return this;
  }

  expire(_key: string, _seconds: number): this {
    this.ops.push(() => 1);
    return this;
  }

  async exec(): Promise<Array<[Error | null, unknown]>> {
    return this.ops.map((op) => [null, op()] as [null, unknown]);
  }
}

vi.mock('../redis/client.js', () => ({
  getRedis: () => ({
    hgetall: async (key: string) => store.get(key) ?? {},
    multi: () => new PipelineStub(),
  }),
  ensureRedis: async () => {},
  setLogger: () => {},
}));

vi.mock('./runpodClient.js', async () => {
  const actual = await vi.importActual<typeof RunpodClientModule>('./runpodClient.js');
  return { ...actual, terminatePod: async () => {} };
});

import { subscribe, type StateEvent } from './orchestrator.js';

describe('broker', () => {
  beforeEach(() => {
    store.clear();
  });

  it('seeds a new subscriber with the current Redis state', async () => {
    store.set('session:user-1', {
      sessionId: 'user-1',
      state: 'fetching_image',
      stateEnteredAt: '1000',
      replacementCount: '0',
      createdAt: '0',
      lastActivityAt: '0',
    });

    const events: StateEvent[] = [];
    const unsubscribe = await subscribe('user-1', (e) => events.push(e));

    expect(events).toHaveLength(1);
    expect(events[0]?.state).toBe('fetching_image');
    expect(events[0]?.stateEnteredAt).toBe(1000);
    expect(events[0]?.replacementCount).toBe(0);

    unsubscribe();
  });

  it('does not seed when no session exists in Redis', async () => {
    const events: StateEvent[] = [];
    const unsubscribe = await subscribe('no-such-user', (e) => events.push(e));

    expect(events).toHaveLength(0);

    unsubscribe();
  });

  it('unsubscribe removes the handler', async () => {
    store.set('session:user-2', {
      sessionId: 'user-2',
      state: 'ready',
      stateEnteredAt: '0',
      replacementCount: '0',
      createdAt: '0',
      lastActivityAt: '0',
    });

    const events: StateEvent[] = [];
    const unsubscribe = await subscribe('user-2', (e) => events.push(e));
    expect(events).toHaveLength(1);  // initial seed

    unsubscribe();
    // After unsubscribe the handler set for user-2 should be cleared.
    // Subscribing again should re-seed with one event (Redis still has state=ready).
    events.length = 0;
    const unsubscribe2 = await subscribe('user-2', (e) => events.push(e));
    expect(events).toHaveLength(1);
    unsubscribe2();
  });
});
