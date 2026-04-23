/**
 * Diagnostic: get 5 on-demand RTX 5090 pods (any DC with availability), watch
 * them survive for 10 minutes. On-demand pods are NOT preempted, so this is
 * mainly a create-reliability + runtime-stability test — counter to
 * probe-spot-survival.ts which measures preemption.
 *
 * Strategy:
 *   1. Scan candidate DCs for 5090 stock (reuses getSpotBid — stockStatus is
 *      the same signal regardless of billing model).
 *   2. In parallel, attempt ONE on-demand create per stocked DC.
 *   3. Take the FIRST 5 successful creates. Immediately terminate any extras
 *      so we don't leave them running.
 *   4. Poll survivors for 10 min. Log any state transitions.
 *   5. Terminate all at end (or on SIGINT).
 *
 * Usage (from backend/):
 *   set -a && source ../.env.local && set +a
 *   npx tsx scripts/probe-ondemand-survival.ts
 */

import { config } from '../src/config/index.js';
import {
  createOnDemandPod,
  getPod,
  getSpotBid,
  terminatePod,
} from '../src/modules/orchestrator/runpodClient.js';

// ─── config ───────────────────────────────────────────────────────────────
const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
const IMAGE = process.env['SURVIVAL_PROBE_IMAGE'] ?? 'nvidia/cuda:12.4.1-base-ubuntu22.04';
const DOCKERHUB_AUTH_ID = config.RUNPOD_REGISTRY_AUTH_ID || undefined;
const PODS_PER_DC = 5;
const MAX_WALL_MS = 10 * 60 * 1000;
const POLL_MS = 15_000;

if (!config.RUNPOD_API_KEY) {
  console.error('RUNPOD_API_KEY env var is required');
  process.exit(1);
}

const CANDIDATE_DCS = [
  'US-TX-3', 'US-TX-4', 'US-GA-1', 'US-GA-2', 'US-OR-1', 'US-NC-1',
  'US-IL-1', 'US-KS-1', 'US-IA-1', 'US-NV-1', 'US-DE-1', 'US-CA-2',
  'CA-MTL-1', 'CA-MTL-2', 'CA-MTL-3', 'CA-MTL-4',
  'EUR-NO-1', 'EUR-IS-1', 'EUR-IS-2', 'EUR-IS-3',
  'EU-RO-1', 'EU-CZ-1', 'EU-SE-1', 'EU-NL-1', 'EU-FR-1',
  'OC-AU-1',
];

// ─── state ────────────────────────────────────────────────────────────────
interface PodState {
  label: string;
  dc: string;
  podId: string | null;
  createdAt: number;
  runtimeAt: number | null;
  stoppedAt: number | null;     // runtime went null or desiredStatus changed (should never happen for on-demand)
  lastDesiredStatus: string | null;
  lastRuntimeNonNull: boolean;
  createError?: string;
  terminatedAt: number | null;
  costPerHr?: number;
}
const states: PodState[] = [];
const startAt = Date.now();

const ts = (): string => new Date().toISOString().slice(11, 23);
const log = (label: string, msg: string): void =>
  console.log(`[${ts()}] [${label.padEnd(14)}] ${msg}`);
const secs = (fromMs: number): string => `${((Date.now() - fromMs) / 1000).toFixed(1)}s`;

// ─── DC scan ──────────────────────────────────────────────────────────────
interface DcStock {
  dc: string;
  stockStatus: string;
}

async function scanDcStock(): Promise<DcStock[]> {
  console.log(`scanning ${CANDIDATE_DCS.length} DCs for 5090 stock...`);
  const out = await Promise.allSettled(
    CANDIDATE_DCS.map(async (dc) => {
      try {
        const info = await getSpotBid(GPU_TYPE_ID, { dataCenterId: dc });
        return { dc, stockStatus: info.stockStatus };
      } catch {
        return null;
      }
    }),
  );
  const stocked: DcStock[] = [];
  for (const r of out) {
    if (r.status === 'fulfilled' && r.value && r.value.stockStatus !== 'None') {
      stocked.push(r.value);
    }
  }
  // High-stocked DCs first
  const order: Record<string, number> = { High: 0, Medium: 1, Low: 2 };
  stocked.sort((a, b) => (order[a.stockStatus] ?? 9) - (order[b.stockStatus] ?? 9));
  return stocked;
}

// ─── creates ──────────────────────────────────────────────────────────────
async function tryCreateInDc(dc: string, n: number): Promise<PodState> {
  const label = `${dc}#${n}`;
  const name = `ondemandprobe-${dc.toLowerCase()}-${new Date()
    .toISOString()
    .replace(/[:.]/g, '-')
    .slice(0, 19)}-${n}`;
  const state: PodState = {
    label,
    dc,
    podId: null,
    createdAt: Date.now(),
    runtimeAt: null,
    stoppedAt: null,
    lastDesiredStatus: null,
    lastRuntimeNonNull: false,
    terminatedAt: null,
  };
  states.push(state);
  try {
    log(label, `creating on-demand pod image=${IMAGE}`);
    const res = await createOnDemandPod({
      name,
      imageName: IMAGE,
      gpuTypeId: GPU_TYPE_ID,
      cloudType: 'SECURE',
      ports: '22/tcp',
      containerDiskInGb: 10,
      minMemoryInGb: 8,
      minVcpuCount: 2,
      containerRegistryAuthId: DOCKERHUB_AUTH_ID,
      dataCenterId: dc,
    });
    state.podId = res.id;
    state.costPerHr = res.costPerHr;
    log(label, `pod.created id=${res.id} cost=$${res.costPerHr}/hr`);
  } catch (err) {
    state.createError = err instanceof Error ? err.message : String(err);
    log(label, `pod.create FAILED: ${state.createError}`);
  }
  return state;
}

// ─── polling ──────────────────────────────────────────────────────────────
async function pollOnce(state: PodState): Promise<void> {
  if (!state.podId || state.stoppedAt || state.terminatedAt) return;
  try {
    const pod = await getPod(state.podId);
    if (!pod) {
      log(state.label, `getPod returned null — treating as gone (+${secs(state.createdAt)})`);
      state.stoppedAt = Date.now();
      return;
    }
    const runtimeLive = pod.runtime != null;
    if (!state.runtimeAt && runtimeLive) {
      state.runtimeAt = Date.now();
      log(
        state.label,
        `runtime.live uptime=${pod.runtime!.uptimeInSeconds}s (+${secs(state.createdAt)})`,
      );
    }
    if (state.lastDesiredStatus && pod.desiredStatus !== state.lastDesiredStatus) {
      log(
        state.label,
        `desiredStatus ${state.lastDesiredStatus} → ${pod.desiredStatus} (+${secs(state.createdAt)})`,
      );
    }
    if (state.lastRuntimeNonNull && !runtimeLive) {
      log(state.label, `runtime went null (+${secs(state.createdAt)})`);
    }
    if (pod.desiredStatus !== 'RUNNING' || (state.lastRuntimeNonNull && !runtimeLive)) {
      state.stoppedAt = Date.now();
      log(
        state.label,
        `STOPPED desiredStatus=${pod.desiredStatus} runtime=${runtimeLive} (+${secs(state.createdAt)})`,
      );
    }
    state.lastDesiredStatus = pod.desiredStatus;
    state.lastRuntimeNonNull = runtimeLive;
  } catch (err) {
    log(state.label, `poll error: ${err instanceof Error ? err.message : String(err)}`);
  }
}

// ─── cleanup ──────────────────────────────────────────────────────────────
let cleaningUp = false;
async function cleanup(reason: string): Promise<void> {
  if (cleaningUp) return;
  cleaningUp = true;
  console.log(`\n[${ts()}] ${reason} — terminating all created pods...`);
  await Promise.allSettled(
    states
      .filter((s) => s.podId && !s.terminatedAt)
      .map(async (s) => {
        try {
          await terminatePod(s.podId!);
          s.terminatedAt = Date.now();
          log(s.label, `terminated`);
        } catch (err) {
          log(s.label, `terminate FAILED: ${err instanceof Error ? err.message : String(err)}`);
        }
      }),
  );
}
process.on('SIGINT', () => {
  void cleanup('SIGINT').then(() => printSummary()).then(() => process.exit(0));
});
process.on('SIGTERM', () => {
  void cleanup('SIGTERM').then(() => printSummary()).then(() => process.exit(0));
});

// ─── summary ──────────────────────────────────────────────────────────────
function printSummary(): void {
  console.log(`\n────────── SUMMARY (wall +${secs(startAt)}) ──────────`);
  const rows: string[][] = [
    ['DC', 'reachedRuntime', 'stopped', 'alive-for', 'outcome'],
  ];
  for (const s of states) {
    const reached = s.runtimeAt ? `+${((s.runtimeAt - s.createdAt) / 1000).toFixed(1)}s` : '-';
    const stopped = s.stoppedAt ? `+${((s.stoppedAt - s.createdAt) / 1000).toFixed(1)}s` : '-';
    const alive = s.stoppedAt
      ? `${((s.stoppedAt - s.createdAt) / 1000).toFixed(1)}s`
      : s.terminatedAt
        ? `${((s.terminatedAt - s.createdAt) / 1000).toFixed(1)}s (terminated by us)`
        : s.createError
          ? '-'
          : 'still-alive';
    const outcome = s.createError
      ? `CREATE-FAIL ${s.createError.slice(0, 70)}`
      : s.stoppedAt
        ? 'UNEXPECTEDLY-STOPPED'
        : 'SURVIVED';
    rows.push([s.label, reached, stopped, alive, outcome]);
  }
  const widths = rows[0]!.map((_, i) => Math.max(...rows.map((r) => r[i]!.length)));
  for (const r of rows) {
    console.log(r.map((c, i) => c.padEnd(widths[i]!)).join('  '));
  }
}

// ─── main ─────────────────────────────────────────────────────────────────
async function main(): Promise<void> {
  const stocked = await scanDcStock();
  console.log(`\nDCs with 5090 stock (${stocked.length}):`);
  for (const s of stocked) {
    console.log(`  ${s.dc.padEnd(10)}  status=${s.stockStatus}`);
  }
  if (stocked.length === 0) {
    console.error('No DCs report 5090 stock — nothing to do.');
    return;
  }

  // Fan out PODS_PER_DC creates into every stocked DC in parallel.
  const totalTargets = stocked.length * PODS_PER_DC;
  console.log(
    `\nattempting ${PODS_PER_DC} on-demand creates × ${stocked.length} DCs = ${totalTargets} pods...`,
  );
  const creates: Promise<PodState>[] = [];
  for (const dc of stocked) {
    for (let n = 1; n <= PODS_PER_DC; n++) {
      creates.push(tryCreateInDc(dc.dc, n));
    }
  }
  await Promise.allSettled(creates);

  const successes = states.filter((s) => s.podId && !s.createError);
  console.log(
    `\ncreates: ${successes.length}/${totalTargets} succeeded, ${states.length - successes.length} failed`,
  );
  if (successes.length === 0) {
    console.error('No on-demand creates succeeded — ending.');
    printSummary();
    return;
  }

  // Poll survivors for 10 min
  console.log('\n─── polling survivors (15s interval) ───');
  while (Date.now() - startAt < MAX_WALL_MS) {
    const tracked = states.filter((s) => s.podId && !s.stoppedAt && !s.terminatedAt);
    if (tracked.length === 0) {
      console.log('no tracked pods remain — ending early');
      break;
    }
    await Promise.allSettled(tracked.map((s) => pollOnce(s)));
    await new Promise((r) => setTimeout(r, POLL_MS));
  }

  await cleanup(Date.now() - startAt >= MAX_WALL_MS ? 'wall cap reached' : 'all pods ended');
  printSummary();
}

main().catch((err) => {
  console.error('fatal:', err);
  void cleanup('error').then(() => printSummary()).then(() => process.exit(1));
});
