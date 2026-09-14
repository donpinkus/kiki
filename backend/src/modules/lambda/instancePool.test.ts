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
  /** cloud-init user_data of every launch, in order. */
  userDatas: string[];
  /** Mark a (type@region) cell as having no capacity. */
  setDry: (cell: string, dry: boolean) => void;
  /** Regions the API reports NO `kiki-test-<region>` filesystem for
   * (default: every region has one). */
  setNoFilesystem: (region: string, missing: boolean) => void;
  /** Health probe behavior per instance ip; default healthy. */
  setHealth: (ip: string, healthy: boolean) => void;
  /** Make an ip answer /health with status:'error' + load_error (server up,
   * model load failed). */
  setLoadError: (ip: string, traceback: string | null) => void;
  probe: (ip: string, timeoutMs: number) => Promise<{ status?: string }>;
}

function makeFakeCloud(): FakeCloud {
  const instances = new Map<string, LambdaInstance>();
  const launched: string[] = [];
  const terminated: string[] = [];
  const unhealthy = new Set<string>();
  const loadErrors = new Map<string, string>();
  let nextIp = 1;

  // (type@region) cells that reject with insufficient-capacity; the sweep
  // should move on and win the first open cell.
  const dryCells = new Set<string>();
  const attempts: string[] = [];
  const userDatas: string[] = [];
  // Every region the tests use has a filesystem unless marked missing; the
  // fake lists only the names the pool spec would ask for.
  const KNOWN_REGIONS = ['test-region', 'region-a', 'region-b'];
  const noFilesystem = new Set<string>();

  const client = {
    listSshKeys: async () => [{ id: 'k1', name: 'test-key', public_key: 'ssh-ed25519 AAA test' }],
    listFilesystems: async () =>
      KNOWN_REGIONS.filter((r) => !noFilesystem.has(r)).map((r) => ({
        id: `fs-${r}`,
        name: `kiki-test-${r}`,
        mount_point: `/lambda/nfs/kiki-test-${r}`,
        created: '',
        region: { name: r, description: '' },
        is_in_use: false,
      })),
    launch: async (req: { name?: string; region_name: string; instance_type_name?: string; user_data?: string }) => {
      const cell = `${req.instance_type_name ?? '?'}@${req.region_name}`;
      attempts.push(cell);
      if (req.user_data) userDatas.push(req.user_data);
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
    userDatas,
    setDry: (cell: string, dry: boolean) => { if (dry) dryCells.add(cell); else dryCells.delete(cell); },
    setNoFilesystem: (region, missing) => { if (missing) noFilesystem.add(region); else noFilesystem.delete(region); },
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
    setLoadError: (ip, traceback) => { if (traceback) loadErrors.set(ip, traceback); else loadErrors.delete(ip); },
    probe: async (ip: string) => {
      if (unhealthy.has(ip)) throw new Error('probe failed');
      const tb = loadErrors.get(ip);
      if (tb) return { status: 'error', load_error: tb };
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
    // No capacity snapshot / boot stats unless a test injects them: static
    // type-major order, flat hedge threshold.
    capacitySnapshot: () => null,
    cellBootStats: async () => new Map(),
    serverDir: 'image',
    requirementsFile: 'requirements.txt',
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

  it('skips a configured region that has no pool filesystem (never launches there)', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, {
      regions: () => ['region-a', 'region-b'],
      instanceTypes: () => ['gpu_best'],
      launchRetryMins: 1,
    });
    // region-a would win on capacity, but its filesystem was never populated
    // (a shared region list where only some regions have been set up).
    cloud.setNoFilesystem('region-a', true);
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      expect(cloud.attempts).toEqual(['gpu_best@region-b']);
      expect(pool.getState().instances[0]?.region).toBe('region-b');
    } finally {
      pool.stop();
    }
  });

  it('skips a region whose filesystem is attached to a setup instance (still being populated)', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, {
      regions: () => ['region-a', 'region-b'],
      instanceTypes: () => ['gpu_best'],
      launchRetryMins: 1,
    });
    // setup-lambda-*.ts creates the filesystem empty and keeps its own
    // instance attached for the 20-40 min populate; a pool launch into it
    // during that window boots a server that can never load weights.
    cloud.seed({
      id: 'setup-1',
      name: 'kiki-vidsetup-1',
      region: { name: 'region-a', description: '' },
      file_system_names: ['kiki-test-region-a'],
    } as Partial<LambdaInstance> & { id: string; name: string });
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      expect(cloud.attempts).toEqual(['gpu_best@region-b']);
    } finally {
      pool.stop();
    }
  });

  it('terminates + replaces an instance whose server reports a terminal load error (no boot-timeout wait)', async () => {
    const cloud = makeFakeCloud();
    // Long boot timeout: if the pool waited it out, this test would hang.
    const pool = makePool(cloud, { bootTimeoutMs: 60_000, launchRetryMins: 1 });
    // The first VM's server comes up but its model load died (the fake hands
    // out 10.0.0.1 first).
    cloud.setLoadError('10.0.0.1', 'Traceback (most recent call last):\n  ...\nRuntimeError: Error 802: system not yet initialized');
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => cloud.terminated.includes('inst-1'), 5000);
      await until(() => pool.hasReady(), 5000);
      expect(cloud.launched).toHaveLength(2);
      expect(pool.getState().instances.map((i) => i.ip)).toEqual(['10.0.0.2']);
    } finally {
      pool.stop();
    }
  });

  it('capacity-aware: tries the cell advertising capacity first, before the static order', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, {
      regions: () => ['region-a', 'region-b'],
      instanceTypes: () => ['gpu_best', 'gpu_worse'],
      launchRetryMins: 1,
      // The 2-min capacity poll says only gpu_best@region-b is open.
      capacitySnapshot: () => ({ atMs: Date.now(), cells: new Set(['gpu_best@region-b']) }),
    });
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      expect(cloud.attempts).toEqual(['gpu_best@region-b']);
    } finally {
      pool.stop();
    }
  });

  it('capacity-aware: within a type, advertised cells go fastest measured boot first; type preference still wins', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, {
      regions: () => ['region-a', 'region-b'],
      instanceTypes: () => ['gpu_best', 'gpu_worse'],
      launchRetryMins: 1,
      capacitySnapshot: () => ({
        atMs: Date.now(),
        cells: new Set(['gpu_best@region-a', 'gpu_best@region-b', 'gpu_worse@region-b']),
      }),
      // region-a boots slowly for gpu_best; region-b is quick.
      cellBootStats: async () => new Map([['gpu_best@region-a', 900_000], ['gpu_best@region-b', 150_000]]),
    });
    cloud.setDry('gpu_best@region-b', true);
    cloud.setDry('gpu_best@region-a', true);
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      // Fast H100 region first, slow H100 region second, only then the worse type.
      expect(cloud.attempts).toEqual(['gpu_best@region-b', 'gpu_best@region-a', 'gpu_worse@region-b']);
    } finally {
      pool.stop();
    }
  });

  it('circuit breaker: a cell that produced a dead-on-arrival VM sorts last on the replacement sweep', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, {
      regions: () => ['region-a', 'region-b'],
      instanceTypes: () => ['gpu_best'],
      bootTimeoutMs: 60_000,
      launchRetryMins: 1,
    });
    // First VM (10.0.0.1, from region-a) comes up with a broken model load.
    cloud.setLoadError('10.0.0.1', 'RuntimeError: Error 802: system not yet initialized');
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady(), 5000);
      expect(cloud.attempts).toEqual(['gpu_best@region-a', 'gpu_best@region-b']);
      expect(pool.getState().instances[0]?.region).toBe('region-b');
    } finally {
      pool.stop();
    }
  });

  it('no hunt cliff: keeps sweeping past the retry window while demand persists, wins when capacity appears', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, { launchRetryMins: 0, launchSpacingMs: 5 });
    cloud.setDry('gpu_1x_test@test-region', true);
    try {
      pool.start(testLog);
      pool.ensure();
      // Several full passes past the (zero-minute) window, still hunting…
      await until(() => cloud.attempts.length >= 4);
      expect(pool.getState().status).toBe('launching');
      // …then capacity appears and the same hunt wins it.
      cloud.setDry('gpu_1x_test@test-region', false);
      await until(() => pool.hasReady());
      expect(cloud.launched).toHaveLength(1);
    } finally {
      pool.stop();
    }
  });

  it('launches with a self-updating bootstrap: fleet manifest check, atomic app swap, then the pool boot.sh', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, { serverDir: 'video', requirementsFile: 'requirements-video.txt' });
    try {
      pool.start(testLog);
      pool.ensure();
      await until(() => pool.hasReady());
      const ud = cloud.userDatas[0] ?? '';
      expect(ud).toContain('/etc/kiki.env');
      expect(ud).toContain('/usr/local/bin/kiki-bootstrap');
      expect(ud).toContain('/v1/fleet/manifest');
      expect(ud).toContain('/v1/fleet/bundle');
      expect(ud).toContain('FS=/lambda/nfs/kiki-test-test-region');
      expect(ud).toContain('POOL=video');
      expect(ud).toContain('requirements-video.txt');
      expect(ud).toContain('exec bash $APP/$POOL/boot.sh');
      expect(ud).toContain('systemd-run, --unit=kiki, --property=Restart=on-failure, bash, /usr/local/bin/kiki-bootstrap');
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

  it('hedges a dragging boot: one racing launch, first-healthy wins, still-booting loser terminated', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, { interestWindowMs: 60_000, hedgeAfterMs: 200, bootTimeoutMs: 60_000 });
    try {
      // The first instance's server never comes up (slow provisioning stand-in).
      cloud.setHealth('10.0.0.1', false);
      pool.start(testLog);
      pool.ensure();
      await until(() => cloud.launched.length === 1);
      // Past hedgeAfterMs with nothing ready → exactly one hedge launches.
      await until(() => cloud.launched.length === 2);
      const [stuck, hedge] = cloud.launched;
      // Hedge (10.0.0.2, healthy) wins; the stuck original is terminated.
      await until(() => pool.hasReady());
      expect(pool.acquireStream()?.name).toBe(hedge);
      await until(() => cloud.terminated.length === 1);
      expect(pool.getState().instances.map((i) => i.name)).toEqual([hedge]);
      expect(stuck).not.toBe(hedge);
    } finally {
      pool.stop();
    }
  });

  it('never stacks hedges: one pair at a time, no third launch while the pair is unresolved', async () => {
    const cloud = makeFakeCloud();
    const pool = makePool(cloud, { interestWindowMs: 60_000, hedgeAfterMs: 200, bootTimeoutMs: 60_000 });
    try {
      // Both the original AND the hedge stay unhealthy → the pair never resolves.
      cloud.setHealth('10.0.0.1', false);
      cloud.setHealth('10.0.0.2', false);
      pool.start(testLog);
      pool.ensure();
      await until(() => cloud.launched.length === 2);
      // Many ticks later: still just the pair.
      await sleep(500);
      expect(cloud.launched).toHaveLength(2);
      // Hedge recovers → wins → loser reaped, pool serves.
      cloud.setHealth('10.0.0.2', true);
      await until(() => pool.hasReady());
      await until(() => cloud.terminated.length === 1);
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
