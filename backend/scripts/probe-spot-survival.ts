/**
 * Diagnostic: spin up N spot RTX 5090 pods per DC that has stock, then watch
 * how long each survives before RunPod preempts it. 10-minute hard cap.
 *
 * Unlike probe-dc-pulls.ts, this test deliberately avoids network volumes and
 * uses a tiny CUDA base image. Purpose is not to measure pull time — it's to
 * measure SPOT SURVIVAL: how often / how fast RunPod preempts our bids in
 * each DC at a given moment.
 *
 * Preemption signal (from RunPod GraphQL pod query):
 *   - desiredStatus transitions RUNNING → EXITED (or TERMINATED)
 *   - OR runtime transitions non-null → null (container gone)
 *
 * Usage (from backend/):
 *   set -a && source ../.env.local && set +a
 *   npx tsx scripts/probe-spot-survival.ts
 */

import { config } from '../src/config/index.js';
import { createSpotPod, getPod, getSpotBid, terminatePod } from '../src/modules/orchestrator/runpodClient.js';

// ─── config ───────────────────────────────────────────────────────────────
const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
// Tiny CUDA base image on Docker Hub — no ML framework, just CUDA runtime.
// ~180MB, so pull is quick even cold. Docker Hub auth avoids anon rate limits.
const IMAGE = process.env['SURVIVAL_PROBE_IMAGE'] ?? 'nvidia/cuda:12.4.1-base-ubuntu22.04';
const DOCKERHUB_AUTH_ID = config.RUNPOD_REGISTRY_AUTH_ID || undefined;
const PODS_PER_DC = 5;
const MAX_WALL_MS = 10 * 60 * 1000;
const POLL_MS = 10_000;

if (!config.RUNPOD_API_KEY) {
  console.error('RUNPOD_API_KEY env var is required');
  process.exit(1);
}

// ─── state ────────────────────────────────────────────────────────────────
interface PodState {
  label: string;               // e.g. "US-TX-3#3"
  dc: string;
  podId: string | null;
  createdAt: number;
  runtimeAt: number | null;    // first time runtime != null
  preemptedAt: number | null;  // first observed transition to non-RUNNING or runtime→null
  lastDesiredStatus: string | null;
  lastRuntimeNonNull: boolean;
  createError?: string;
  terminatedAt: number | null;
}

const states: PodState[] = [];
const startAt = Date.now();

function ts(): string {
  return new Date().toISOString().slice(11, 23);
}

function log(label: string, msg: string): void {
  console.log(`[${ts()}] [${label.padEnd(14)}] ${msg}`);
}

function secs(fromMs: number): string {
  return `${((Date.now() - fromMs) / 1000).toFixed(1)}s`;
}

// ─── DC discovery ─────────────────────────────────────────────────────────
/**
 * List every RunPod DC we might want to scan. Using a known hard-coded list
 * because the dataCenters GraphQL endpoint isn't always populated for all IDs.
 * Scan is fan-out so extra DCs are cheap.
 */
const CANDIDATE_DCS = [
  'US-TX-3', 'US-TX-4', 'US-GA-1', 'US-GA-2', 'US-OR-1', 'US-NC-1',
  'US-IL-1', 'US-KS-1', 'US-IA-1', 'US-NV-1', 'US-DE-1', 'US-CA-2',
  'CA-MTL-1', 'CA-MTL-2', 'CA-MTL-3', 'CA-MTL-4',
  'EUR-NO-1', 'EUR-IS-1', 'EUR-IS-2', 'EUR-IS-3',
  'EU-RO-1', 'EU-CZ-1', 'EU-SE-1', 'EU-NL-1', 'EU-FR-1',
  'OC-AU-1',
];

interface DcStock {
  dc: string;
  stockStatus: string;
  bidPerGpu: number;
}

async function scanDcStock(): Promise<DcStock[]> {
  console.log(`scanning ${CANDIDATE_DCS.length} DCs for 5090 spot stock...`);
  const results = await Promise.allSettled(
    CANDIDATE_DCS.map(async (dc) => {
      try {
        const info = await getSpotBid(GPU_TYPE_ID, { dataCenterId: dc });
        return { dc, stockStatus: info.stockStatus, bidPerGpu: info.minimumBidPrice };
      } catch {
        return null;
      }
    }),
  );
  const stocked: DcStock[] = [];
  for (const r of results) {
    if (r.status === 'fulfilled' && r.value && r.value.stockStatus !== 'None') {
      stocked.push(r.value);
    }
  }
  stocked.sort((a, b) => a.dc.localeCompare(b.dc));
  return stocked;
}

// ─── per-pod lifecycle ────────────────────────────────────────────────────
async function createSpotPodInDc(dc: string, n: number, bidPerGpu: number): Promise<PodState> {
  const label = `${dc}#${n}`;
  const name = `spotprobe-${dc.toLowerCase()}-${new Date()
    .toISOString()
    .replace(/[:.]/g, '-')
    .slice(0, 19)}-${n}`;
  const state: PodState = {
    label,
    dc,
    podId: null,
    createdAt: Date.now(),
    runtimeAt: null,
    preemptedAt: null,
    lastDesiredStatus: null,
    lastRuntimeNonNull: false,
    terminatedAt: null,
  };
  states.push(state);
  try {
    log(label, `creating spot pod bid=$${bidPerGpu}/gpu image=${IMAGE}`);
    const res = await createSpotPod({
      name,
      imageName: IMAGE,
      gpuTypeId: GPU_TYPE_ID,
      bidPerGpu,
      ports: '22/tcp',
      containerDiskInGb: 10,
      minMemoryInGb: 8,
      minVcpuCount: 2,
      containerRegistryAuthId: DOCKERHUB_AUTH_ID,
      dataCenterId: dc,
      // no networkVolumeId on purpose — this test isolates from volume health
    });
    state.podId = res.id;
    log(label, `pod.created id=${res.id} cost=$${res.costPerHr}/hr`);
  } catch (err) {
    state.createError = err instanceof Error ? err.message : String(err);
    log(label, `pod.create FAILED: ${state.createError}`);
  }
  return state;
}

// ─── polling loop ─────────────────────────────────────────────────────────
async function pollOnce(state: PodState): Promise<void> {
  if (!state.podId || state.preemptedAt || state.terminatedAt) return;
  try {
    const pod = await getPod(state.podId);
    if (!pod) {
      log(state.label, `getPod returned null — treating as gone`);
      state.preemptedAt = Date.now();
      return;
    }
    const runtimeLive = pod.runtime != null;
    if (!state.runtimeAt && runtimeLive) {
      state.runtimeAt = Date.now();
      log(state.label, `runtime.live uptime=${pod.runtime!.uptimeInSeconds}s (+${secs(state.createdAt)})`);
    }
    if (state.lastDesiredStatus && pod.desiredStatus !== state.lastDesiredStatus) {
      log(state.label, `desiredStatus ${state.lastDesiredStatus} → ${pod.desiredStatus} (+${secs(state.createdAt)})`);
    }
    if (state.lastRuntimeNonNull && !runtimeLive) {
      log(state.label, `runtime went null (+${secs(state.createdAt)})`);
    }
    if (pod.desiredStatus !== 'RUNNING' || (state.lastRuntimeNonNull && !runtimeLive)) {
      state.preemptedAt = Date.now();
      log(state.label, `PREEMPTED desiredStatus=${pod.desiredStatus} runtime=${runtimeLive} (+${secs(state.createdAt)})`);
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
    ['DC#n', 'reachedRuntime', 'preempted', 'survival', 'outcome'],
  ];
  for (const s of states) {
    const reached = s.runtimeAt ? `+${((s.runtimeAt - s.createdAt) / 1000).toFixed(1)}s` : '-';
    const preempt = s.preemptedAt ? `+${((s.preemptedAt - s.createdAt) / 1000).toFixed(1)}s` : '-';
    const survival = s.preemptedAt
      ? `${((s.preemptedAt - s.createdAt) / 1000).toFixed(1)}s`
      : s.terminatedAt
        ? `${((s.terminatedAt - s.createdAt) / 1000).toFixed(1)}s (terminated by us)`
        : s.createError
          ? '-'
          : 'still-alive';
    const outcome = s.createError
      ? `CREATE-FAIL ${s.createError.slice(0, 60)}`
      : s.preemptedAt
        ? 'PREEMPTED'
        : 'SURVIVED';
    rows.push([s.label, reached, preempt, survival, outcome]);
  }
  const widths = rows[0]!.map((_, i) => Math.max(...rows.map((r) => r[i]!.length)));
  for (const r of rows) {
    console.log(r.map((c, i) => c.padEnd(widths[i]!)).join('  '));
  }

  // Per-DC aggregate
  console.log('\nPer-DC survival stats:');
  const byDc = new Map<string, PodState[]>();
  for (const s of states) {
    if (!byDc.has(s.dc)) byDc.set(s.dc, []);
    byDc.get(s.dc)!.push(s);
  }
  for (const [dc, xs] of [...byDc.entries()].sort()) {
    const created = xs.filter((x) => !x.createError).length;
    const runtime = xs.filter((x) => x.runtimeAt).length;
    const preempted = xs.filter((x) => x.preemptedAt).length;
    const alive = xs.filter((x) => x.podId && !x.preemptedAt && !x.createError).length;
    console.log(
      `  ${dc.padEnd(10)} created=${created}/${xs.length}  reached-runtime=${runtime}  preempted=${preempted}  alive-at-end=${alive}`,
    );
  }
}

// ─── main ─────────────────────────────────────────────────────────────────
async function main(): Promise<void> {
  const stocked = await scanDcStock();
  console.log(`\nDCs with 5090 spot stock (${stocked.length}):`);
  for (const s of stocked) {
    console.log(`  ${s.dc.padEnd(10)}  status=${s.stockStatus}  min-bid=$${s.bidPerGpu}/gpu`);
  }
  if (stocked.length === 0) {
    console.error('No DCs report 5090 spot stock. Exiting without creating pods.');
    return;
  }

  console.log(
    `\ncreating ${PODS_PER_DC} spot pods × ${stocked.length} DCs = ${
      PODS_PER_DC * stocked.length
    } pods (wall cap ${MAX_WALL_MS / 1000}s)`,
  );
  console.log(`image=${IMAGE}\n`);

  const creates: Promise<PodState>[] = [];
  for (const dc of stocked) {
    for (let n = 1; n <= PODS_PER_DC; n++) {
      creates.push(createSpotPodInDc(dc.dc, n, dc.bidPerGpu));
    }
  }
  await Promise.allSettled(creates);

  // Poll loop until wall cap
  console.log('\n─── polling (10s interval) ───');
  while (Date.now() - startAt < MAX_WALL_MS) {
    await Promise.allSettled(states.map((s) => pollOnce(s)));
    const stillTracked = states.filter((s) => s.podId && !s.preemptedAt);
    if (stillTracked.length === 0 && states.some((s) => s.podId)) {
      console.log('all pods preempted or gone — ending early');
      break;
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }

  await cleanup(Date.now() - startAt >= MAX_WALL_MS ? 'wall cap reached' : 'all pods ended');
  printSummary();
}

main().catch((err) => {
  console.error('fatal:', err);
  void cleanup('error').then(() => printSummary()).then(() => process.exit(1));
});
