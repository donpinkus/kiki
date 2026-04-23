import { beforeEach, describe, expect, it, vi } from 'vitest';

import type * as RunpodClientModule from './runpodClient.js';

// Mock external dependencies before importing the orchestrator.
// ─ Redis: hand-rolled in-memory stub that tracks hgetall/del calls.
// ─ RunPod client: spy on terminatePod.

const redisStore = new Map<string, Record<string, string>>();
const delMock = vi.fn(async (key: string) => {
  redisStore.delete(key);
  return 1;
});

vi.mock('../redis/client.js', () => ({
  getRedis: () => ({
    hgetall: async (key: string) => redisStore.get(key) ?? {},
    del: delMock,
  }),
  ensureRedis: async () => {},
  setLogger: () => {},
}));

const terminatePodMock = vi.fn(async () => {});
vi.mock('./runpodClient.js', async () => {
  const actual = await vi.importActual<typeof RunpodClientModule>('./runpodClient.js');
  return {
    ...actual,
    terminatePod: (...args: Parameters<typeof terminatePodMock>) => terminatePodMock(...args),
  };
});

// Orchestrator also imports cost monitor + metrics — those are pure, leave unmocked.

import { abortSession } from './orchestrator.js';

describe('abortSession', () => {
  beforeEach(() => {
    redisStore.clear();
    delMock.mockClear();
    terminatePodMock.mockClear();
    terminatePodMock.mockImplementation(async () => {});
  });

  it('terminates the pod AND deletes the Redis session', async () => {
    redisStore.set('session:user-1', {
      sessionId: 'user-1',
      podId: 'pod-abc',
      podUrl: 'wss://example',
      state: 'ready',
      stateEnteredAt: '0',
      createdAt: '0',
      lastActivityAt: '0',
      replacementCount: '0',
    });

    await abortSession('user-1');

    expect(terminatePodMock).toHaveBeenCalledWith('pod-abc');
    expect(delMock).toHaveBeenCalledWith('session:user-1');
  });

  it('still deletes the session when terminatePod throws', async () => {
    terminatePodMock.mockRejectedValueOnce(new Error('RunPod API down'));

    redisStore.set('session:user-2', {
      sessionId: 'user-2',
      podId: 'pod-xyz',
      podUrl: '',
      state: 'ready',
      stateEnteredAt: '0',
      createdAt: '0',
      lastActivityAt: '0',
      replacementCount: '0',
    });

    await expect(abortSession('user-2')).resolves.toBeUndefined();
    expect(delMock).toHaveBeenCalledWith('session:user-2');
  });

  it('only deletes the session when there is no podId', async () => {
    redisStore.set('session:user-3', {
      sessionId: 'user-3',
      state: 'finding_gpu',
      stateEnteredAt: '0',
      podId: '',
      createdAt: '0',
      lastActivityAt: '0',
      replacementCount: '0',
    });

    await abortSession('user-3');

    expect(terminatePodMock).not.toHaveBeenCalled();
    expect(delMock).toHaveBeenCalledWith('session:user-3');
  });
});
