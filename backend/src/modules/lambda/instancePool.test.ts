/**
 * Unit tests for the shared pool machinery (instancePool.ts) — the first
 * direct coverage of the orchestration that runs both the image and video
 * fleets. A fake LambdaClient + fake /health probe stand in for the cloud;
 * timing dials are shrunk ~1000x so scaling behavior plays out in ms.
 */
import type { FastifyBaseLogger } from 'fastify';
import { describe, expect, it } from 'vitest';

import type { LambdaClient, LambdaInstance } from './client.js';
import { LambdaApiError } from './client.js';
import { createInstancePool, type InstancePool, type InstancePoolSpec } from './instancePool.js';

const testLog = {
  info: () => {},
  warn: () => {},
  error: () => {},
  debug: () => {},
  trace: () => {},
  fatal: () => {},
  child: () => testLog,
} as unknown as FastifyBaseLogger;

interface FakeCloud {
  client: LambdaClient;
  /** Names launched via the API, in order. */
  launched: string[];
  /** Instance ids terminated via the API, in order. */
  terminated: string[];
  /** Instances the API reports (adoption reads this at start()). */
  seed: (inst: Partial<LambdaInstance> & { id: string; name: string }) => void;
  /** Every launch attempt as `type@region`, in order (sweep-order assertions). */
  attempts: string[];
  /** Mark a (type@region) cell as having no capacity. */
  setDry: (cell: string, dry: boolean) => void;
  /** Health probe behavior per instance ip; default healthy. */
  setHealth: (ip: string, healthy: boolean) => void;
  probe: (ip: string, timeoutMs: number) => Promise<{ status?: string }>;
}

function makeFakeCloud(): FakeCloud {
  const instances = new Map<string, LambdaInstance>();
  const launched: string[] = [];
  const terminated: string[] = [];
  const unhealthy = new Set<string>();
  let nextIp = 1;

  // (type@region) cells that reject with insufficient-capacity; the sweep
  // should move on and win the first open cell.
  const dryCells = new Set<string>();
  const attempts: string[] = [];

  const client = {
    listSshKeys: async () => [{ id: 'k1', name: 'test-key', public_key: 'ssh-ed25519 AAA test' }],
    launch: async (req: { name?: string; region_name: string; instance_type_name?: string }) => {
      const cell = `${req.instance_type_name ?? '?'}@${req.region_name}`;
      attempts.push(cell);
      if (dryCells.has(cell)) {
        throw new LambdaApiError(400, 'instance-operations/launch/insufficient-capacity', 'no capacity');
      }
      const id = `inst-${launched.length + 1}`;
      const name = req.name ?? id;
      launched.push(name);
      instances.set(id, {
        id,
        name,
        ip: `10.0.0.${nextIp++}`,
        status: 'active',
        region: { name: req.region_name, description: '' },
      } as LambdaInstance);
      return [id];
    },
    getInstance: async (id: string) => {
      const inst = instances.get(id);
      if (!inst) throw new Error('not found');
      return inst;
    },
    listInstances: async () => [...instances.values()],
    terminate: async (ids: string[]) => {
      for (const id of ids) {
        terminated.push(id);
        instances.delete(id);
      }
      return [];
    },
  } as unknown as LambdaClient;

  return {
    client,
    launched,
    terminated,
    attempts,
    setDry: (cell: string, dry: boolean) => { if (dry) dryCells.add(cell); else dryCells.delete(cell); },
    seed: (inst) => {
      instances.set(inst.id, {
        status: 'active',
        region: { name: 'test-region', description: '' },
        ...inst,
      } as LambdaInstance);
    },
    setHealth: (ip, healthy) => {
      if (healthy) unhealthy.delete(ip);
      else unhealthy.add(ip);
    },
    probe: async (ip: string) => {
      if (unhealthy.has(ip)) throw new Error('probe failed');
      return { status: 'ok' };
    },
  };
}

function makePool(
  cloud: FakeCloud,
  overrides: Partial<InstancePoolSpec> = {},
): InstancePool {
  return createInstancePool({
    kind: 'test',
    namePrefix: 'kiki-test-',
    fsName: (r) => `kiki-test-${r}`,
    label: 'test GPU',
    enabled: () => true,
    regions: () => ['test-region'],
    instanceTypes: () => ['gpu_1x_test'],
    poolMin: () => 0,
    poolMax: () => 3,
    targetStreams: () => 2,
    bootEstimateMs: 1000,
    createClient: () => cloud.client,
    probeHealth: cloud.probe,
    tickMs: 50,
    idleTerminateMs: 150,
    bootTimeoutMs: 5000,
    pollMs: 20,
    launchRetryMins: 0,
    launchSpacingMs: 0,
    interestWindowMs: 250,
    ...overrides,
  });
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

async function until(cond: () => boolean, timeoutMs = 10_000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error('until() timed out');
    await sleep(10);
  }
}

describe('instancePool', { timeout: 30_000 }, () => {
  it('interest launches one instance; readiness comes from OUR health probe; acquire returns a tokenized url', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud);
    try {
      pool.start(testLog);
      expect(pool.hasReady()).toBe(false);
      pool.touch(); // user interest → next tick launches
      await until(() => cloud.launched.length === 1);
      expect(cloud.launched[0]).toMatch(/^kiki-test-\d+$/);
      await until(() => pool.hasReady());

      const slot = pool.acquireStream();
      expect(slot).not.toBeNull();
      expect(slot?.name).toBe(cloud.launched[0]);
      expect(slot?.url).toMatch(/^ws:\/\/10\.0\.0\.1:8766\/ws\?token=[0-9a-f]{32}$/);
      // Interest alone never launches a second instance.
      await sleep(200);
      expect(cloud.launched).toHaveLength(1);
    } finally {
      pool.stop();
    }
  });

  it('scales up under stream pressure (ceil(streams/target)), one launch per tick', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud); // targetStreams = 2
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      pool.acquireStream();
      pool.acquireStream(); // 2 streams / target 2 → need 1, no growth
      await sleep(200);
      expect(cloud.launched).toHaveLength(1);

      pool.acquireStream(); // 3 streams → need 2
      await until(() => cloud.launched.length === 2);
    } finally {
      pool.stop();
    }
  });

  it('scales down after the idle window once interest expires (one per tick, floor respected)', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud);
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      const slot = pool.acquireStream();
      if (slot) pool.releaseStream(slot.name);
      // Interest window (250ms) + idle window (150ms) both expire → reaped.
      await until(() => cloud.terminated.length === 1);
      expect(pool.hasReady()).toBe(false);
    } finally {
      pool.stop();
    }
  });

  it('kills an instance after 3 failed health probes and replaces it while interest holds', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, { interestWindowMs: 60_000 }); // stay interested
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      cloud.setHealth('10.0.0.1', false);
      // 3 strikes (3 ticks) → terminate; interest → scaler relaunches.
      await until(() => cloud.terminated.length === 1);
      await until(() => cloud.launched.length === 2);
      cloud.setHealth('10.0.0.2', true);
      await until(() => pool.hasReady());
    } finally {
      pool.stop();
    }
  });

  it('reportFailure marks an instance suspect (skipped for assignment) until a probe clears it', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, { interestWindowMs: 60_000 });
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      const name = cloud.launched[0] ?? '';
      pool.reportFailure(name);
      expect(pool.hasReady()).toBe(false);
      expect(pool.acquireStream()).toBeNull();
      // Instance is actually fine — the next tick's probe clears the strike.
      await until(() => pool.hasReady());
      expect(pool.acquireStream()?.name).toBe(name);
    } finally {
      pool.stop();
    }
  });

  it('sweeps TYPE-MAJOR across regions: worse type only after every region refused the better one', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, {
      regions: () => ['region-a', 'region-b'],
      instanceTypes: () => ['gpu_best', 'gpu_worse'],
      launchRetryMins: 1,
    });
    // Best type dry EVERYWHERE, worse type dry in region-a → the sweep should
    // try best@a, best@b, worse@a, then win worse@b.
    cloud.setDry('gpu_best@region-a', true);
    cloud.setDry('gpu_best@region-b', true);
    cloud.setDry('gpu_worse@region-a', true);
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      expect(cloud.attempts.slice(0, 4)).toEqual([
        'gpu_best@region-a',
        'gpu_best@region-b',
        'gpu_worse@region-a',
        'gpu_worse@region-b',
      ]);
      expect(cloud.launched).toHaveLength(1);
    } finally {
      pool.stop();
    }
  });

  it('region failover: capacity in the second region wins without type fallback', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, {
      regions: () => ['region-a', 'region-b'],
      instanceTypes: () => ['gpu_best'],
      launchRetryMins: 1,
    });
    cloud.setDry('gpu_best@region-a', true);
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      expect(cloud.attempts).toEqual(['gpu_best@region-a', 'gpu_best@region-b']);
      const state = pool.getState();
      expect(state.instances[0]?.name).toBeTruthy();
    } finally {
      pool.stop();
    }
  });

  it('exposes WHY: interest attribution + per-instance hold verdicts in getState', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, { interestWindowMs: 60_000 });
    try {
      pool.start(testLog);
      pool.ensure('app_open client=simulator:test');
      await until(() => pool.hasReady());
      // Verdicts refresh on the tick; wait for one.
      await until(() => pool.getState().instances[0]?.holdReason !== 'pending first tick');
      const state = pool.getState();
      expect(state.interest.lastSource).toBe('app_open client=simulator:test');
      expect(state.interest.ageMs).not.toBeNull();
      expect(state.instances[0]?.holdReason).toContain('within need');
      expect(state.instances[0]?.holdReason).toContain('app_open client=simulator:test');
      // Acquire flips the verdict to active-streams on the next tick.
      pool.acquireStream('stream client=device:test');
      await until(() => pool.getState().instances[0]?.holdReason?.includes('active') ?? false);
      expect(state.interest.recent.length).toBeGreaterThan(0);
    } finally {
      pool.stop();
    }
  });

  it('adopts existing prefix-matching instances at start (redeploy survival), ignoring other names', async () => {
    const cloud = makeFakeCloud();
    cloud.seed({ id: 'inst-adopt', name: 'kiki-test-1700000000001', ip: '10.0.0.9' });
    cloud.seed({ id: 'inst-other', name: 'kiki-othersetup-5', ip: '10.0.0.8' });
    const pool = makePool(cloud, { interestWindowMs: 60_000 });
    try {
      pool.start(testLog);
      await until(() => pool.hasReady());
      const slot = pool.acquireStream();
      expect(slot?.name).toBe('kiki-test-1700000000001');
      expect(cloud.launched).toHaveLength(0); // adopted, not launched
    } finally {
      pool.stop();
    }
  });
});
