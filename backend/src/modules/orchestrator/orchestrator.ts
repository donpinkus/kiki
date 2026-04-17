/**
 * Per-session pod lifecycle orchestration.
 *
 * Responsibilities (all in this one file because they share state and are
 * tightly coupled — separating would just spread the reader's attention across
 * imports):
 *   - Registry: Map<sessionId, Session>
 *   - Provisioner: create pod → SSH setup → health poll
 *   - Reaper: terminate pods idle > 10 min
 *   - Reconcile: on boot, kill orphaned `kiki-session-*` pods from prior runs
 *   - Semaphore: cap concurrent provisions to prevent rate-limit + burst OOM
 */

import { spawn } from 'node:child_process';
import { chmodSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { FastifyBaseLogger } from 'fastify';

import { config } from '../../config/index.js';
import {
  createOnDemandPod,
  createSpotPod,
  getPod,
  getSpotBid,
  isCapacityError,
  listPodsByPrefix,
  terminatePod,
  type SpotBidInfo,
} from './runpodClient.js';
import { getPolicy } from './policy.js';

// ────────────────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────────────────

export type SessionStatus = 'provisioning' | 'ready' | 'terminated';

export type PodType = 'spot' | 'onDemand';

export interface Session {
  sessionId: string;
  podId: string | null; // null while provisioning
  podUrl: string | null; // wss URL, set once ready
  podType: PodType | null; // null while provisioning
  status: SessionStatus;
  createdAt: number;
  lastActivityAt: number;
  provisionPromise: Promise<{ podUrl: string }> | null;
}

// ────────────────────────────────────────────────────────────────────────────
// Module-scoped state
// ────────────────────────────────────────────────────────────────────────────

const registry = new Map<string, Session>();

const POD_PREFIX = 'kiki-session-';
const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
const IMAGE_NAME = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';
// Headroom above the current spot floor. Larger headroom = fewer outbids =
// fewer needless fallbacks to on-demand. 0.05 costs ~$0.03/hr more than the
// 0.02 default on a typical bid, cheaper than one on-demand fallback.
const BID_HEADROOM = 0.05;

const IDLE_TIMEOUT_MS = 10 * 60 * 1000;
const REAPER_INTERVAL_MS = 60 * 1000;
const MAX_CONCURRENT_PROVISIONS = Number(process.env['MAX_CONCURRENT_PROVISIONS'] ?? 5);

// Semaphore state
let activeProvisions = 0;
const semaphoreWaiters: Array<() => void> = [];

// Logger injected by start()
let log: FastifyBaseLogger = console as unknown as FastifyBaseLogger;

// SSH key path — written once on first provision
const SSH_KEY_PATH = '/tmp/kiki-runpod-key';
let sshKeyWritten = false;

// Runtime asset paths — flux-klein-server/ files bundled into backend at build
const __dirname = dirname(fileURLToPath(import.meta.url));
const RUNTIME_ASSETS_DIR = findRuntimeAssets(__dirname);

function findRuntimeAssets(startDir: string): string {
  // Walk up from this file's directory looking for a `runtime-assets/` folder.
  // In dev (tsx): backend/src/modules/orchestrator/ → finds backend/runtime-assets/
  // In prod Docker image: /app/dist/modules/orchestrator/ → finds /app/runtime-assets/
  let dir = startDir;
  for (let i = 0; i < 6; i++) {
    const candidate = join(dir, 'runtime-assets');
    if (existsSync(candidate)) return candidate;
    dir = dirname(dir);
  }
  throw new Error(`Could not locate runtime-assets directory starting from ${startDir}`);
}

// ────────────────────────────────────────────────────────────────────────────
// Public API
// ────────────────────────────────────────────────────────────────────────────

/**
 * Returns a healthy pod URL for the given session, provisioning one if needed.
 * If the same sessionId calls this concurrently while a provision is in flight,
 * both calls await the same promise — we don't create two pods.
 *
 * `onStatus` receives human-readable progress strings suitable for forwarding
 * to the client as `{type: "status", status: "provisioning", message: ...}`.
 */
export async function getOrProvisionPod(
  sessionId: string,
  onStatus: (msg: string) => void,
): Promise<{ podUrl: string }> {
  const existing = registry.get(sessionId);

  if (existing?.status === 'ready' && existing.podUrl) {
    log.info({ sessionId, podId: existing.podId }, 'Reusing existing session pod');
    onStatus('Ready');
    return { podUrl: existing.podUrl };
  }

  if (existing?.provisionPromise) {
    log.info({ sessionId }, 'Waiting for in-flight provision');
    onStatus('Joining existing provisioning...');
    return existing.provisionPromise;
  }

  // Fresh provision. Create session record, then attach the promise so any
  // concurrent callers for the same sessionId wait on us.
  const session: Session = {
    sessionId,
    podId: null,
    podUrl: null,
    podType: null,
    status: 'provisioning',
    createdAt: Date.now(),
    lastActivityAt: Date.now(),
    provisionPromise: null,
  };
  registry.set(sessionId, session);

  const promise = (async () => {
    try {
      await acquireSemaphore(onStatus);
      try {
        const result = await provision(sessionId, onStatus);
        session.podId = result.podId;
        session.podUrl = result.podUrl;
        session.podType = result.podType;
        session.status = 'ready';
        session.lastActivityAt = Date.now();
        session.provisionPromise = null;
        return { podUrl: result.podUrl };
      } finally {
        releaseSemaphore();
      }
    } catch (err) {
      log.error({ sessionId, err }, 'Provision failed');
      // If we got a pod ID before failing, clean it up so we don't leak.
      if (session.podId) {
        terminatePod(session.podId).catch((e) =>
          log.warn({ podId: session.podId, err: e }, 'Failed to clean up pod after provision failure'),
        );
      }
      registry.delete(sessionId);
      throw err;
    }
  })();

  session.provisionPromise = promise;
  return promise;
}

export function touch(sessionId: string): void {
  const s = registry.get(sessionId);
  if (s) s.lastActivityAt = Date.now();
}

export function sessionClosed(sessionId: string): void {
  const s = registry.get(sessionId);
  if (!s) return;
  // Don't terminate — user may reconnect. Just log. Reaper handles the timeout.
  log.info(
    { sessionId, podId: s.podId, idleAfterMs: IDLE_TIMEOUT_MS },
    'Client disconnected; pod stays alive pending reconnect',
  );
}

/**
 * Runs once at backend boot: terminate any orphan pods from a prior backend run,
 * then arm the idle reaper.
 */
export async function start(logger: FastifyBaseLogger): Promise<void> {
  log = logger;
  await reconcileOrphanPods();
  setInterval(runReaper, REAPER_INTERVAL_MS);
  log.info({ idleTimeoutMs: IDLE_TIMEOUT_MS, maxConcurrent: MAX_CONCURRENT_PROVISIONS }, 'Orchestrator started');
}

// ────────────────────────────────────────────────────────────────────────────
// Semaphore
// ────────────────────────────────────────────────────────────────────────────

async function acquireSemaphore(onStatus: (msg: string) => void): Promise<void> {
  if (activeProvisions < MAX_CONCURRENT_PROVISIONS) {
    activeProvisions++;
    return;
  }
  log.info({ active: activeProvisions, cap: MAX_CONCURRENT_PROVISIONS }, 'Provision queued');
  onStatus(`Waiting for GPU (${activeProvisions - MAX_CONCURRENT_PROVISIONS + 1} in queue)...`);
  await new Promise<void>((resolve) => semaphoreWaiters.push(resolve));
  activeProvisions++;
}

function releaseSemaphore(): void {
  activeProvisions--;
  const next = semaphoreWaiters.shift();
  if (next) next();
}

// ────────────────────────────────────────────────────────────────────────────
// Reaper + reconcile
// ────────────────────────────────────────────────────────────────────────────

function runReaper(): void {
  const now = Date.now();
  for (const session of registry.values()) {
    if (session.status !== 'ready' || !session.podId) continue;
    const idleMs = now - session.lastActivityAt;
    if (idleMs > IDLE_TIMEOUT_MS) {
      log.info({ sessionId: session.sessionId, podId: session.podId, idleMs }, 'Reaping idle pod');
      session.status = 'terminated';
      const podId = session.podId;
      terminatePod(podId)
        .then(() => registry.delete(session.sessionId))
        .catch((err) => log.error({ sessionId: session.sessionId, podId, err }, 'Reap failed'));
    }
  }
}

async function reconcileOrphanPods(): Promise<void> {
  try {
    const pods = await listPodsByPrefix(POD_PREFIX);
    if (pods.length === 0) {
      log.info('Reconcile: no orphan pods found');
      return;
    }
    log.warn({ count: pods.length }, 'Reconcile: terminating orphan pods from prior backend run');
    await Promise.all(
      pods.map((p) =>
        terminatePod(p.id).catch((err) =>
          log.error({ podId: p.id, name: p.name, err }, 'Failed to terminate orphan'),
        ),
      ),
    );
  } catch (err) {
    log.error({ err }, 'Reconcile failed (continuing anyway)');
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Provisioner
// ────────────────────────────────────────────────────────────────────────────

interface ProvisionResult {
  podId: string;
  podUrl: string;
  podType: PodType;
}

async function provision(sessionId: string, onStatus: (msg: string) => void): Promise<ProvisionResult> {
  // 1 + 2. Create a pod — spot first, on-demand fallback if capacity exhausted
  const { podId, podType } = await createPodWithFallback(sessionId, onStatus);

  // 3. Wait for the container to boot. In baked mode the image is slim (~2-3
  // GB) but the very first pull to a host in a DC can still take a few minutes.
  // Split the wait so the user sees "Pulling container image..." (runtime null)
  // vs "Loading AI model..." (container up, server initializing).
  onStatus('Pulling container image...');
  await waitForRuntime(podId, onStatus);

  if (config.FLUX_PROVISION_MODE !== 'baked') {
    const sshInfo = await waitForSsh(podId);
    log.info({ sessionId, podId, ssh: `${sshInfo.ip}:${sshInfo.port}` }, 'Pod SSH ready');

    onStatus('Installing server...');
    await scpFiles(sshInfo);
    onStatus('Downloading AI model (~2 min)...');
    await runSetup(sshInfo, (line) => {
      if (line.includes('Downloading') && line.includes('FLUX.2-klein')) onStatus('Downloading AI model...');
      else if (line.includes('Warming up')) onStatus('Warming up...');
    });
  }

  // 4. Poll /health via RunPod proxy until the FLUX server reports ready
  onStatus('Loading AI model & warming up...');
  const healthUrl = `https://${podId}-8766.proxy.runpod.net/health`;
  await waitForHealth(healthUrl);

  // 5. Build WebSocket URL and return
  const podUrl = `wss://${podId}-8766.proxy.runpod.net/ws`;
  log.info({ sessionId, podId, podUrl, podType, mode: config.FLUX_PROVISION_MODE }, 'Pod ready');
  onStatus('Ready');
  return { podId, podUrl, podType };
}

/**
 * A candidate placement: which DC to pin the pod to, and optionally which
 * pre-populated network volume to attach. `null` for both means "let RunPod
 * pick any DC, no volume" — legacy ssh-mode behavior.
 */
interface PlacementTarget {
  dataCenterId: string | null;
  networkVolumeId: string | null;
  bidInfo: SpotBidInfo | null;
}

/**
 * In baked mode with a configured NETWORK_VOLUMES_BY_DC, iterate through each
 * volume DC and query spot stock. Returns the first DC with Medium/High stock
 * (with its bid info), or the best-stock DC even if Low (so the caller can
 * still try spot before falling back to on-demand). Returns `null` only if
 * every DC returns a hard capacity miss.
 *
 * In non-baked mode or with no volumes configured, returns a single unpinned
 * target (DC = null) and lets RunPod pick.
 */
async function selectPlacement(sessionId: string): Promise<PlacementTarget | null> {
  const volumes = config.NETWORK_VOLUMES_BY_DC;
  const volumeDcs = Object.keys(volumes);
  const useVolumes = config.FLUX_PROVISION_MODE === 'baked' && volumeDcs.length > 0;

  if (!useVolumes) {
    try {
      const bidInfo = await getSpotBid(GPU_TYPE_ID);
      return { dataCenterId: null, networkVolumeId: null, bidInfo };
    } catch (err) {
      if (isCapacityError(err)) return { dataCenterId: null, networkVolumeId: null, bidInfo: null };
      throw err;
    }
  }

  // Volume-aware path: probe each DC, rank by stock, pick the best.
  const rank: Record<string, number> = { High: 3, Medium: 2, Low: 1, None: 0 };
  const probed: Array<{ dc: string; volumeId: string; bid: SpotBidInfo | null }> = [];
  await Promise.all(
    volumeDcs.map(async (dc) => {
      const volumeId = volumes[dc]!;
      try {
        const bid = await getSpotBid(GPU_TYPE_ID, { dataCenterId: dc });
        probed.push({ dc, volumeId, bid });
      } catch (err) {
        if (isCapacityError(err)) {
          probed.push({ dc, volumeId, bid: null });
        } else {
          throw err;
        }
      }
    }),
  );

  // Sort: DCs with stock first (by rank), then null-stock DCs (for on-demand only).
  probed.sort((a, b) => {
    const ar = a.bid ? (rank[a.bid.stockStatus] ?? 0) : -1;
    const br = b.bid ? (rank[b.bid.stockStatus] ?? 0) : -1;
    return br - ar;
  });

  log.info(
    {
      sessionId,
      event: 'provision.placement.ranked',
      dcs: probed.map((p) => ({ dc: p.dc, stock: p.bid?.stockStatus ?? 'none' })),
    },
    'DC placement ranked',
  );

  const top = probed[0];
  if (!top) return null;
  return { dataCenterId: top.dc, networkVolumeId: top.volumeId, bidInfo: top.bid };
}

/**
 * Tries spot first. Falls through to on-demand on capacity exhaustion if
 * `ONDEMAND_FALLBACK_ENABLED` is set and the policy allows it. Emits structured
 * events at each decision point so Workstream 4 can attribute cost by pod type.
 *
 * In baked mode with network volumes, pins both spot and on-demand attempts
 * to the selected volume's DC so the pre-populated weights are reachable.
 */
async function createPodWithFallback(
  sessionId: string,
  onStatus: (msg: string) => void,
): Promise<{ podId: string; podType: PodType }> {
  const podName = `${POD_PREFIX}${sessionId.slice(0, 16)}`;

  // Image + registry auth depend on provision mode.
  // ssh mode: stock runpod/pytorch base (Docker Hub, RUNPOD_REGISTRY_AUTH_ID).
  // baked mode: GHCR image with deps baked in (RUNPOD_GHCR_AUTH_ID). Weights
  // come from the attached network volume at /workspace/huggingface.
  const imageName = config.FLUX_PROVISION_MODE === 'baked'
    ? (config.FLUX_IMAGE || (() => { throw new Error('FLUX_IMAGE env var required when FLUX_PROVISION_MODE=baked'); })())
    : IMAGE_NAME;
  const authId = config.FLUX_PROVISION_MODE === 'baked'
    ? (config.RUNPOD_GHCR_AUTH_ID || undefined)
    : (config.RUNPOD_REGISTRY_AUTH_ID || undefined);

  // ─── Pick DC (+ volume if baked) ─────────────────────────────────────
  onStatus('Finding available GPU...');
  const target = await selectPlacement(sessionId);
  if (!target) {
    throw new Error('No RunPod DC has 5090 capacity right now (all volume-DCs exhausted)');
  }
  const bidInfo = target.bidInfo;
  const dcField = target.dataCenterId ? { dataCenterId: target.dataCenterId } : {};
  const volField = target.networkVolumeId ? { networkVolumeId: target.networkVolumeId } : {};

  // ─── Try spot ─────────────────────────────────────────────────────────
  let spotCapacityExhausted = false;
  let fallbackReason: string | null = null;

  if (!bidInfo) {
    spotCapacityExhausted = true;
    fallbackReason = 'spot_bid_unavailable';
    log.info(
      { sessionId, event: 'provision.spot.capacityMiss', reason: fallbackReason, dc: target.dataCenterId },
      'No spot pricing — will try on-demand',
    );
  } else if (bidInfo.stockStatus === 'None' || bidInfo.stockStatus === 'Low') {
    spotCapacityExhausted = true;
    fallbackReason = `stock_${bidInfo.stockStatus.toLowerCase()}`;
    log.info(
      { sessionId, event: 'provision.spot.capacityMiss', stockStatus: bidInfo.stockStatus, dc: target.dataCenterId },
      'Spot stock low — will try on-demand',
    );
  }

  if (!spotCapacityExhausted && bidInfo) {
    const bid = Math.round((bidInfo.minimumBidPrice + BID_HEADROOM) * 100) / 100;
    log.info(
      {
        sessionId,
        event: 'provision.spot.attempt',
        minBid: bidInfo.minimumBidPrice,
        stockStatus: bidInfo.stockStatus,
        bid,
        dc: target.dataCenterId,
        volumeId: target.networkVolumeId,
      },
      'Spot bid discovered',
    );
    onStatus('Provisioning GPU...');
    try {
      const { id: podId, costPerHr } = await createSpotPod({
        name: podName,
        imageName,
        gpuTypeId: GPU_TYPE_ID,
        bidPerGpu: bid,
        ...(authId ? { containerRegistryAuthId: authId } : {}),
        ...dcField,
        ...volField,
      });
      log.info(
        { sessionId, event: 'provision.spot.success', podId, costPerHr, podType: 'spot', dc: target.dataCenterId },
        'Pod created (spot)',
      );
      return { podId, podType: 'spot' };
    } catch (err) {
      if (isCapacityError(err)) {
        spotCapacityExhausted = true;
        fallbackReason = 'spot_create_capacity_error';
        log.info(
          { sessionId, event: 'provision.spot.capacityMiss', err: (err as Error).message, dc: target.dataCenterId },
          'Spot createPod hit capacity error — will try on-demand',
        );
      } else {
        throw err;
      }
    }
  }

  // ─── Fall through to on-demand ───────────────────────────────────────
  if (!config.ONDEMAND_FALLBACK_ENABLED) {
    throw new Error(
      `5090 spot capacity exhausted (${fallbackReason ?? 'unknown'}); on-demand fallback disabled`,
    );
  }

  // Policy gate — v1 allows everyone. Post-WS8, free-tier users may stay spot-only.
  const allowed = await getPolicy().allowsOnDemand({ userId: sessionId, source: 'jwt' });
  if (!allowed) {
    throw new Error(
      `5090 spot capacity exhausted (${fallbackReason ?? 'unknown'}); on-demand not allowed by policy`,
    );
  }

  log.info(
    { sessionId, event: 'provision.fallback.triggered', reason: fallbackReason, dc: target.dataCenterId },
    'Switching to on-demand pod',
  );
  // Silent to the user — status says "Creating pod..." same as spot path.
  onStatus('Creating pod...');
  try {
    const { id: podId, costPerHr } = await createOnDemandPod({
      name: podName,
      imageName,
      gpuTypeId: GPU_TYPE_ID,
      cloudType: 'SECURE',
      ...(authId ? { containerRegistryAuthId: authId } : {}),
      ...dcField,
      ...volField,
    });
    log.info(
      { sessionId, event: 'provision.onDemand.success', podId, costPerHr, podType: 'onDemand', dc: target.dataCenterId },
      'Pod created (on-demand)',
    );
    return { podId, podType: 'onDemand' };
  } catch (err) {
    log.error(
      { sessionId, event: 'provision.onDemand.failed', err: (err as Error).message, dc: target.dataCenterId },
      'On-demand fallback also failed',
    );
    throw err;
  }
}

interface SshInfo {
  ip: string;
  port: number;
  podId: string;
}

async function waitForSsh(podId: string, timeoutMs = 5 * 60 * 1000): Promise<SshInfo> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pod = await getPod(podId);
    if (pod?.runtime?.ports) {
      const ssh = pod.runtime.ports.find((p) => p.privatePort === 22);
      if (ssh && ssh.ip) {
        return { ip: ssh.ip, port: ssh.publicPort, podId };
      }
    }
    await sleep(5000);
  }
  throw new Error(`Pod ${podId} never got SSH info within ${timeoutMs}ms`);
}

function ensureSshKey(): void {
  if (sshKeyWritten) return;
  const key = config.RUNPOD_SSH_PRIVATE_KEY;
  writeFileSync(SSH_KEY_PATH, key.endsWith('\n') ? key : key + '\n');
  chmodSync(SSH_KEY_PATH, 0o600);
  sshKeyWritten = true;
}

async function scpFiles(ssh: SshInfo): Promise<void> {
  ensureSshKey();
  const { ip, port } = ssh;
  const scpOpts = ['-i', SSH_KEY_PATH, '-o', 'StrictHostKeyChecking=no', '-P', String(port)];
  const sshOpts = ['-i', SSH_KEY_PATH, '-o', 'StrictHostKeyChecking=no', '-p', String(port)];

  // Wait for sshd to be responsive
  await retryCommand('ssh', [...sshOpts, `root@${ip}`, 'echo ok'], 12, 5000);

  // Prepare target dir
  await runCommand('ssh', [...sshOpts, `root@${ip}`, 'rm -rf /tmp/flux-klein-server && mkdir -p /tmp/flux-klein-server']);

  // SCP the setup script
  await runCommand('scp', [
    ...scpOpts,
    join(RUNTIME_ASSETS_DIR, 'setup-flux-klein.sh'),
    `root@${ip}:/tmp/setup-flux-klein.sh`,
  ]);

  // SCP the server files
  const files = ['server.py', 'pipeline.py', 'config.py', 'requirements.txt'];
  for (const f of files) {
    await runCommand('scp', [
      ...scpOpts,
      join(RUNTIME_ASSETS_DIR, 'flux-klein-server', f),
      `root@${ip}:/tmp/flux-klein-server/${f}`,
    ]);
  }
}

async function runSetup(ssh: SshInfo, onLine: (line: string) => void): Promise<void> {
  ensureSshKey();
  const { ip, port } = ssh;
  const sshOpts = ['-i', SSH_KEY_PATH, '-o', 'StrictHostKeyChecking=no', '-p', String(port)];
  await runCommand(
    'ssh',
    [...sshOpts, `root@${ip}`, 'chmod +x /tmp/setup-flux-klein.sh && /tmp/setup-flux-klein.sh'],
    { onStdoutLine: onLine, timeoutMs: 15 * 60 * 1000 },
  );
}

/**
 * Polls the RunPod API until the pod's `runtime` field is non-null, meaning
 * the container image has been pulled and the container process is running.
 * Emits a status update when the transition happens so the user sees
 * "Pulling container image..." → "Starting server..." in real time.
 */
async function waitForRuntime(
  podId: string,
  onStatus: (msg: string) => void,
  timeoutMs = 10 * 60 * 1000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pod = await getPod(podId);
    if (pod?.runtime) {
      log.info({ podId, uptimeInSeconds: pod.runtime.uptimeInSeconds }, 'Container runtime up');
      onStatus('Starting server...');
      return;
    }
    await sleep(5000);
  }
  throw new Error(`Pod ${podId} container never started within ${Math.round(timeoutMs / 1000)}s`);
}

async function waitForHealth(healthUrl: string, timeoutMs = 10 * 60 * 1000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(healthUrl, { signal: AbortSignal.timeout(10_000) });
      if (res.ok) {
        const body = (await res.json()) as { status?: string };
        if (body.status === 'ok') return;
      }
    } catch {
      // Ignore — health check hasn't come up yet
    }
    await sleep(10_000);
  }
  throw new Error(`Server at ${healthUrl} never became healthy within ${timeoutMs}ms`);
}

// ────────────────────────────────────────────────────────────────────────────
// Child process helpers
// ────────────────────────────────────────────────────────────────────────────

interface RunCommandOpts {
  onStdoutLine?: (line: string) => void;
  timeoutMs?: number;
}

function runCommand(cmd: string, args: string[], opts: RunCommandOpts = {}): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 2 * 60 * 1000;
  return new Promise((resolve, reject) => {
    const proc = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`${cmd} timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    const onStdoutLine = opts.onStdoutLine;
    if (onStdoutLine && proc.stdout) {
      let buf = '';
      proc.stdout.on('data', (chunk: Buffer) => {
        buf += chunk.toString('utf8');
        let idx: number;
        while ((idx = buf.indexOf('\n')) !== -1) {
          onStdoutLine(buf.slice(0, idx));
          buf = buf.slice(idx + 1);
        }
      });
    }

    let stderr = '';
    proc.stderr?.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8');
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    proc.on('exit', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`${cmd} exited ${code}: ${stderr.slice(-500)}`));
    });
  });
}

async function retryCommand(cmd: string, args: string[], attempts: number, delayMs: number): Promise<void> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      await runCommand(cmd, args, { timeoutMs: 15_000 });
      return;
    } catch (err) {
      lastErr = err;
      await sleep(delayMs);
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
