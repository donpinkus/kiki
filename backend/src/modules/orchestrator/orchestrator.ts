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
  createSpotPod,
  getPod,
  getSpotBid,
  listPodsByPrefix,
  terminatePod,
} from './runpodClient.js';

// ────────────────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────────────────

export type SessionStatus = 'provisioning' | 'ready' | 'terminated';

export interface Session {
  sessionId: string;
  podId: string | null; // null while provisioning
  podUrl: string | null; // wss URL, set once ready
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
const BID_HEADROOM = 0.02;

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
  onStatus(`Waiting for GPU (${activeProvisions - MAX_CONCURRENT_PROVISIONS + 1} ahead)...`);
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
}

async function provision(sessionId: string, onStatus: (msg: string) => void): Promise<ProvisionResult> {
  // 1. Discover current spot bid
  onStatus('Discovering spot bid...');
  const bidInfo = await getSpotBid(GPU_TYPE_ID);
  if (bidInfo.stockStatus === 'None' || bidInfo.stockStatus === 'Low') {
    throw new Error(`5090 spot stock is '${bidInfo.stockStatus}' — try again shortly`);
  }
  const bid = Math.round((bidInfo.minimumBidPrice + BID_HEADROOM) * 100) / 100;
  log.info({ sessionId, minBid: bidInfo.minimumBidPrice, bid }, 'Spot bid discovered');

  // 2. Create pod
  onStatus('Creating pod...');
  const podName = `${POD_PREFIX}${sessionId.slice(0, 16)}`;
  const authId = config.RUNPOD_REGISTRY_AUTH_ID || undefined;
  const { id: podId } = await createSpotPod({
    name: podName,
    imageName: IMAGE_NAME,
    gpuTypeId: GPU_TYPE_ID,
    bidPerGpu: bid,
    ...(authId ? { containerRegistryAuthId: authId } : {}),
  });
  log.info({ sessionId, podId, authenticated: !!authId }, 'Pod created');

  // 3. Wait for SSH
  onStatus('Waiting for pod to boot...');
  const sshInfo = await waitForSsh(podId);
  log.info({ sessionId, podId, ssh: `${sshInfo.ip}:${sshInfo.port}` }, 'Pod SSH ready');

  // 4. SCP server files + run setup
  onStatus('Installing server code...');
  await scpFiles(sshInfo);
  onStatus('Installing dependencies & downloading model (~3 min)...');
  await runSetup(sshInfo, (line) => {
    // Surface a few meaningful milestones from setup output.
    if (line.includes('Downloading') && line.includes('FLUX.2-klein')) onStatus('Downloading model...');
    else if (line.includes('Warming up')) onStatus('Warming up...');
  });

  // 5. Poll /health via RunPod proxy until ready
  onStatus('Checking server health...');
  const healthUrl = `https://${podId}-8766.proxy.runpod.net/health`;
  await waitForHealth(healthUrl);

  // 6. Build WebSocket URL and return
  const podUrl = `wss://${podId}-8766.proxy.runpod.net/ws`;
  log.info({ sessionId, podId, podUrl }, 'Pod ready');
  onStatus('Ready');
  return { podId, podUrl };
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

    if (opts.onStdoutLine && proc.stdout) {
      let buf = '';
      proc.stdout.on('data', (chunk: Buffer) => {
        buf += chunk.toString('utf8');
        let idx: number;
        while ((idx = buf.indexOf('\n')) !== -1) {
          opts.onStdoutLine!(buf.slice(0, idx));
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
