/**
 * Diagnostic: spin up N on-demand RTX 5090 pods per DC in parallel, poll each
 * to timestamp when it transitions through RunPod's observable stages, then
 * terminate everything. Use this to isolate "slow/stalled container pull"
 * behavior from the rest of the app stack.
 *
 * Observable stages (via GraphQL `pod` query):
 *   t0  pod.created        mutation returned an id
 *   t1  scheduled          machine.dataCenterId populated (RunPod picked a host)
 *   t2  runtime.live       runtime != null (container has actually started,
 *                          i.e. image pull completed and entrypoint is running)
 *   t3  ports.exposed      runtime.ports includes a public port for 8766 (HTTP)
 *
 * Pods are hard-terminated after 10 min regardless of state so a stalled pull
 * can't run up cost. SIGINT also triggers best-effort termination.
 *
 * Usage (from backend/):
 *   set -a && source ../.env.local && set +a
 *   npx tsx scripts/probe-dc-pulls.ts
 */

import {
  createOnDemandPod,
  getPod,
  terminatePod,
  type PodRuntime,
} from '../src/modules/orchestrator/runpodClient.js';

// ─── config ───────────────────────────────────────────────────────────────
const DCS: Record<string, string> = {
  'EUR-NO-1': '49n6i3twuw',
  'EU-RO-1': 'xbiu29htvu',
  'EU-CZ-1': 'hhmat30tzx',
  'US-IL-1': '59plfch67d',
  'US-NC-1': '5vz7ubospw',
};
const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
const IMAGE = process.env['FLUX_IMAGE'] ?? 'ghcr.io/donpinkus/kiki-flux-klein:latest';
// GHCR credential (must match FLUX_IMAGE registry host). The Docker Hub
// credential under RUNPOD_REGISTRY_AUTH_ID won't authenticate to ghcr.io and
// causes `denied: denied` pull failures — verified the hard way on 2026-04-22.
const REGISTRY_AUTH_ID = process.env['RUNPOD_GHCR_AUTH_ID'] ?? 'cmnzksgzw007hl107jmt4n8kf';
const PODS_PER_DC = 3;
const MAX_POD_MS = 10 * 60 * 1000;
const POLL_MS = 5000;
const API_KEY = process.env['RUNPOD_API_KEY'];

if (!API_KEY) {
  console.error('RUNPOD_API_KEY env var is required');
  process.exit(1);
}

// ─── state ────────────────────────────────────────────────────────────────
interface ProbeState {
  label: string;        // e.g. "EU-CZ-1#2"
  dc: string;
  podId: string | null;
  createdAt: number;
  ts: Partial<{
    created: number;
    scheduled: number;
    runtimeLive: number;
    portsExposed: number;
    terminated: number;
    createFailed: number;
  }>;
  lastRuntime: PodRuntime | null;
  done: boolean;
  error?: string;
}

const probes: ProbeState[] = [];
const startAt = Date.now();

function elapsed(from: number): string {
  return `${((Date.now() - from) / 1000).toFixed(1)}s`;
}

function ts(): string {
  return new Date().toISOString().slice(11, 23); // HH:mm:ss.SSS
}

function log(label: string, msg: string): void {
  console.log(`[${ts()}] [${label.padEnd(12)}] ${msg}`);
}

// ─── per-pod lifecycle ────────────────────────────────────────────────────
async function createAndProbe(dc: string, n: number): Promise<ProbeState> {
  const label = `${dc}#${n}`;
  const runStamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const name = `pullprobe-${dc.toLowerCase()}-${runStamp}-${n}`;
  const state: ProbeState = {
    label,
    dc,
    podId: null,
    createdAt: Date.now(),
    ts: {},
    lastRuntime: null,
    done: false,
  };
  probes.push(state);

  try {
    log(label, `creating on-demand pod name=${name} dc=${dc} image=${IMAGE}`);
    const res = await createOnDemandPod({
      name,
      imageName: IMAGE,
      gpuTypeId: GPU_TYPE_ID,
      cloudType: 'SECURE',
      containerRegistryAuthId: REGISTRY_AUTH_ID,
      dataCenterId: dc,
      networkVolumeId: DCS[dc]!,
    });
    state.podId = res.id;
    state.ts.created = Date.now();
    log(label, `pod.created id=${res.id} cost=$${res.costPerHr}/hr`);
  } catch (err) {
    state.ts.createFailed = Date.now();
    state.error = err instanceof Error ? err.message : String(err);
    state.done = true;
    log(label, `pod.create FAILED: ${state.error}`);
    return state;
  }

  // poll until runtime live, ports exposed, or hard cap hit
  while (!state.done) {
    const age = Date.now() - state.createdAt;
    if (age > MAX_POD_MS) {
      log(label, `hard cap ${MAX_POD_MS / 1000}s reached — terminating`);
      break;
    }

    try {
      const pod = await getPod(state.podId!);
      state.lastRuntime = pod;
      if (!pod) {
        log(label, `getPod returned null (pod disappeared?)`);
        break;
      }

      if (!state.ts.scheduled && pod.machine?.dataCenterId) {
        state.ts.scheduled = Date.now();
        log(label, `scheduled at dc=${pod.machine.dataCenterId} (+${elapsed(state.createdAt)})`);
      }

      if (!state.ts.runtimeLive && pod.runtime) {
        state.ts.runtimeLive = Date.now();
        log(label, `runtime.live uptime=${pod.runtime.uptimeInSeconds}s (+${elapsed(state.createdAt)})`);
      }

      if (!state.ts.portsExposed && pod.runtime) {
        const http = pod.runtime.ports.find((p) => p.privatePort === 8766 && p.publicPort);
        if (http) {
          state.ts.portsExposed = Date.now();
          log(
            label,
            `ports.exposed http=${http.ip}:${http.publicPort} (+${elapsed(state.createdAt)}) — READY`,
          );
          break;
        }
      }
    } catch (err) {
      log(label, `poll error: ${err instanceof Error ? err.message : String(err)}`);
    }

    await sleep(POLL_MS);
  }

  // terminate
  if (state.podId) {
    try {
      await terminatePod(state.podId);
      state.ts.terminated = Date.now();
      log(label, `terminated (+${elapsed(state.createdAt)})`);
    } catch (err) {
      log(label, `terminate FAILED: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  state.done = true;
  return state;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// ─── SIGINT safety: terminate every created pod before exiting ────────────
let cleaningUp = false;
async function cleanup(signal: string): Promise<void> {
  if (cleaningUp) return;
  cleaningUp = true;
  console.log(`\n[${ts()}] ${signal} received — terminating any live pods...`);
  await Promise.allSettled(
    probes
      .filter((p) => p.podId && !p.ts.terminated)
      .map(async (p) => {
        try {
          await terminatePod(p.podId!);
          log(p.label, `cleanup terminate OK`);
        } catch (err) {
          log(p.label, `cleanup terminate FAILED: ${err instanceof Error ? err.message : String(err)}`);
        }
      }),
  );
  process.exit(1);
}
process.on('SIGINT', () => void cleanup('SIGINT'));
process.on('SIGTERM', () => void cleanup('SIGTERM'));

// ─── run ──────────────────────────────────────────────────────────────────
async function main(): Promise<void> {
  console.log(
    `pull-probe starting: ${Object.keys(DCS).length} DCs × ${PODS_PER_DC} pods = ${
      Object.keys(DCS).length * PODS_PER_DC
    } pods`,
  );
  console.log(`image=${IMAGE}  max=${MAX_POD_MS / 1000}s  poll=${POLL_MS / 1000}s`);
  console.log(`started=${new Date().toISOString()}\n`);

  const jobs: Promise<ProbeState>[] = [];
  for (const dc of Object.keys(DCS)) {
    for (let n = 1; n <= PODS_PER_DC; n++) {
      jobs.push(createAndProbe(dc, n));
    }
  }
  const results = await Promise.allSettled(jobs);

  // ─── summary ─────────────────────────────────────────────────────────────
  console.log(`\n────────── SUMMARY (wall +${elapsed(startAt)}) ──────────`);
  const rows: string[][] = [
    ['DC#n', 'created→sched', 'sched→runtime', 'runtime→ports', 'TOTAL', 'outcome'],
  ];
  for (const r of results) {
    if (r.status !== 'fulfilled') {
      rows.push(['(unhandled)', '-', '-', '-', '-', r.reason?.message ?? String(r.reason)]);
      continue;
    }
    const s = r.value;
    const base = s.ts.created ?? s.createdAt;
    const toSched = s.ts.scheduled ? `${((s.ts.scheduled - base) / 1000).toFixed(1)}s` : '-';
    const toRuntime =
      s.ts.runtimeLive && s.ts.scheduled
        ? `${((s.ts.runtimeLive - s.ts.scheduled) / 1000).toFixed(1)}s`
        : '-';
    const toPorts =
      s.ts.portsExposed && s.ts.runtimeLive
        ? `${((s.ts.portsExposed - s.ts.runtimeLive) / 1000).toFixed(1)}s`
        : '-';
    const total = s.ts.portsExposed
      ? `${((s.ts.portsExposed - base) / 1000).toFixed(1)}s`
      : s.ts.runtimeLive
        ? `${((s.ts.runtimeLive - base) / 1000).toFixed(1)}s (no ports)`
        : 'never-ready';
    const outcome = s.error
      ? `ERROR: ${s.error.slice(0, 80)}`
      : s.ts.portsExposed
        ? 'READY'
        : s.ts.runtimeLive
          ? 'RUNTIME-ONLY'
          : s.ts.scheduled
            ? 'STUCK-PULL'
            : s.ts.created
              ? 'STUCK-SCHEDULING'
              : 'CREATE-FAILED';
    rows.push([s.label, toSched, toRuntime, toPorts, total, outcome]);
  }

  // ASCII table
  const widths = rows[0]!.map((_, i) => Math.max(...rows.map((r) => r[i]!.length)));
  for (const r of rows) {
    console.log(r.map((c, i) => c.padEnd(widths[i]!)).join('  '));
  }

  console.log(`\ndone=${new Date().toISOString()}`);
}

main().catch((err) => {
  console.error('fatal:', err);
  void cleanup('error');
});
