/**
 * Lambda Cloud cold-start benchmark: launch API call → first generated frame.
 *
 * Launches a serving instance whose cloud-init invokes boot.sh off the
 * pre-populated filesystem (see setup-lambda.ts), and times every phase:
 *
 *   t_launch_api   POST /instance-operations/launch round-trip
 *   t_active       instance status booting → active (VM provision; billing starts)
 *   t_http         first HTTP response from :8766/health (cloud-init + venv import + bind)
 *   t_ready        /health status=ok (weights → GPU + warmup inference)
 *   t_first_frame  WS connect + config + sketch → generated JPEG back
 *
 * Also reports the pod's own phase_timings_ms from /health (prefetch /
 * from_pretrained / warmup breakdown) and measures steady-state per-frame
 * latency over 5 frames. Output frames land in scripts/lambda/out/.
 *
 * Readiness is measured by probing /health directly as soon as the instance
 * has an IP (Lambda's `active` status lags real readiness — measured
 * 2026-07-15: /health was ok the instant the API flipped to active, so the
 * status poll was hiding any earlier readiness). t_active is recorded
 * independently for comparison.
 *
 * Usage (from backend/):
 *   tsx scripts/lambda/coldstart-bench.ts --region us-east-1 --type gpu_1x_h100_pcie
 *   ... --keep       leave the instance running for IMAGE_PROVIDER=lambda testing
 *   ... --image x.jpg  use a custom sketch (default: test-sketch.jpg)
 *   ... --prompt "..."  (default: a cute cat, watercolor)
 *   ... --os-image gpu-base-24-04   launch image family (default: Lambda's default,
 *                                   i.e. latest Lambda Stack)
 *
 * Terminate leftovers: tsx scripts/lambda/instances.ts --terminate-all
 */

import { randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { launchWithRetry, requireClient, sleep, type Instance } from './lambdaApi.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

function getArg(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 ? process.argv[idx + 1] : undefined;
}

const REGION = getArg('--region');
const TYPE = getArg('--type') ?? 'gpu_1x_h100_pcie';
const KEEP = process.argv.includes('--keep');
const PROMPT = getArg('--prompt') ?? 'a cute cat, watercolor';
const IMAGE_PATH = getArg('--image') ?? resolve(__dirname, 'test-sketch.jpg');
if (!REGION) {
  console.error('Usage: tsx scripts/lambda/coldstart-bench.ts --region <region> [--type gpu_1x_h100_pcie] [--keep]');
  process.exit(1);
}
const FS_NAME = getArg('--fs') ?? `kiki-image-${REGION}`;
const FS_ROOT = `/lambda/nfs/${FS_NAME}`;
const PORT = 8766;
// Default pinned, NOT provider default: the default image family differs per
// region (us-east-1 and us-south-2 default to 22.04), and the filesystem venv
// is built for 24.04/py3.12 — its bin/python3 symlink resolves against the
// HOST's /usr/bin/python3, so a 22.04 host silently runs py3.10 with zero
// venv packages (ModuleNotFoundError: uvicorn; hit 2026-07-16).
const OS_IMAGE = getArg('--os-image') ?? 'lambda-stack-24-04';

const client = requireClient();
const sketch = readFileSync(IMAGE_PATH);
const wsToken = randomBytes(16).toString('hex');

// cloud-init: write per-instance env, then launch boot.sh detached via
// systemd-run (runcmd blocks cloud-init's final stage otherwise — the server
// never exits). Restart=on-failure respawns the server if it crashes.
const USER_DATA = `#cloud-config
write_files:
  - path: /etc/kiki.env
    permissions: '0600'
    content: |
      KIKI_WS_TOKEN=${wsToken}
runcmd:
  - [systemd-run, --unit=kiki, --property=Restart=on-failure, bash, ${FS_ROOT}/kiki/boot.sh]
`;

interface Timings {
  [k: string]: number;
}
const t: Timings = {};
// Timing baseline. Reset before each launch attempt (see launchWithRetry's
// onAttempt) so capacity-retry waits never inflate the cold-start numbers —
// t0 always marks the start of the SUCCESSFUL launch call.
let t0 = Date.now();
const mark = (k: string): void => {
  t[k] = Date.now() - t0;
  console.log(`[bench] +${(t[k]! / 1000).toFixed(1)}s  ${k}`);
};

const RETRY_MINS = Number(getArg('--retry-mins') ?? '0');
console.log(`[bench] launching ${TYPE} in ${REGION} (fs=${FS_NAME}, os=${OS_IMAGE ?? 'default'})...`);
const [instanceId] = await launchWithRetry(
  client,
  {
    region_name: REGION,
    instance_type_name: TYPE,
    ssh_key_names: [(await client.listSshKeys())[0]!.name],
    file_system_names: [FS_NAME],
    name: `kiki-bench-${Date.now()}`,
    user_data: USER_DATA,
    ...(OS_IMAGE ? { image: { family: OS_IMAGE } } : {}),
  },
  RETRY_MINS,
  () => { t0 = Date.now(); },
);
mark('t_launch_api');
console.log(`[bench] instance ${instanceId}`);

let inst: Instance | undefined;
try {
  // ── Provision: status poll and /health probe run CONCURRENTLY. ──────────
  // The status poll (3s) records t_ip (first non-null IP) and t_active; the
  // health prober (1s, starts at t_ip) records t_http (first response) and
  // t_ready (status ok). Readiness gates on /health alone — `active` is
  // recorded for comparison but never waited on (it lags real readiness).
  let resolveIp!: (ip: string) => void;
  const ipPromise = new Promise<string>((r) => { resolveIp = r; });
  let ipSeen = false;
  let sawActive = false;
  // Fatal boot error (instance died / timeout) surfaced by the status poll;
  // checked by the health prober so neither task is left hanging and the
  // rejection is never unhandled (which would skip the finally-terminate).
  let bootError: Error | null = null;

  const statusPoll = (async (): Promise<void> => {
    for (;;) {
      // Tolerate transient API/network failures — a DNS blip mid-poll must
      // not abort the bench (the instance keeps booting regardless).
      try {
        inst = await client.getInstance(instanceId!);
      } catch (e) {
        console.log(`[bench] status poll transient error: ${(e as Error).message}`);
        await sleep(3000);
        continue;
      }
      if (inst.ip && !ipSeen) {
        ipSeen = true;
        mark('t_ip');
        console.log(`[bench] ip=${inst.ip} (status=${inst.status})`);
        resolveIp(inst.ip);
      }
      if (inst.status === 'active' && !sawActive) {
        sawActive = true;
        mark('t_active');
      }
      if (['terminated', 'unhealthy', 'preempted'].includes(inst.status)) {
        bootError = new Error(`instance entered ${inst.status} during boot`);
        return;
      }
      // Keep polling (for t_active) until both signals are in, but let the
      // health prober own overall completion.
      if (sawActive && t['t_ready'] !== undefined) return;
      if (Date.now() - t0 > 30 * 60 * 1000) {
        bootError = new Error('timed out waiting for active');
        return;
      }
      await sleep(3000);
    }
  })();

  let health: Record<string, unknown> | undefined;
  const healthProbe = (async (): Promise<void> => {
    // Race the IP against a fatal boot error so a died-before-IP instance
    // doesn't leave this task waiting forever. The watcher must terminate
    // once the IP is known — an unbounded loser of this race keeps a timer
    // pending forever and the process never exits (hung run, 2026-07-15).
    const ip = await Promise.race([
      ipPromise,
      (async (): Promise<string> => {
        while (!ipSeen) {
          if (bootError) throw bootError;
          await sleep(1000);
        }
        return ipPromise;
      })(),
    ]);
    const healthUrl = `http://${ip}:${PORT}/health`;
    let firstHttp = false;
    for (;;) {
      try {
        const res = await fetch(healthUrl, { signal: AbortSignal.timeout(3000) });
        if (!firstHttp) {
          firstHttp = true;
          mark('t_http');
        }
        health = (await res.json()) as Record<string, unknown>;
        if (health['status'] === 'ok') return;
      } catch {
        /* not up yet */
      }
      if (bootError) throw bootError;
      if (Date.now() - t0 > 40 * 60 * 1000) throw new Error('timed out waiting for /health ok');
      await sleep(1000);
    }
  })();

  await healthProbe;
  mark('t_ready');
  // Do NOT wait for status=active here — the WS frame test starts the moment
  // the server is ready, so t_first_frame reflects what a real session could
  // achieve. (Bench-A run 2026-07-15 waited and overstated first-frame by the
  // 62s active-lag.) statusPoll keeps running in the background to record
  // t_active for the comparison; it's awaited after the frame test.
  const ip = await ipPromise;
  console.log('[bench] pod-side phase_timings_ms:', JSON.stringify(health!['phase_timings_ms'] ?? {}));

  // ── first frame over WS ───────────────────────────────────────────────────
  const outDir = resolve(__dirname, 'out');
  mkdirSync(outDir, { recursive: true });
  const frameTimes: number[] = [];
  await new Promise<void>((res, rej) => {
    const ws = new WebSocket(`ws://${ip}:${PORT}/ws?token=${wsToken}`, { perMessageDeflate: false });
    const fail = (e: Error): void => { ws.close(); rej(e); };
    const timeout = setTimeout(() => fail(new Error('WS frame timeout (120s)')), 120_000);
    let sentAt = 0;
    let frames = 0;
    const TOTAL_FRAMES = 5;
    ws.on('open', () => {
      ws.send(JSON.stringify({ type: 'config', prompt: PROMPT, steps: 4, requestId: 'bench' }));
      sentAt = Date.now();
      ws.send(sketch);
    });
    ws.on('message', (data: Buffer, isBinary: boolean) => {
      if (!isBinary) return; // status / frame_meta JSON
      frames += 1;
      frameTimes.push(Date.now() - sentAt);
      writeFileSync(resolve(outDir, `frame-${frames}.jpg`), data);
      if (frames === 1) mark('t_first_frame');
      if (frames >= TOTAL_FRAMES) {
        clearTimeout(timeout);
        ws.close();
        res();
      } else {
        sentAt = Date.now();
        ws.send(sketch);
      }
    });
    ws.on('error', fail);
  });

  // Let the status poll observe `active` (up to 3 min more) so t_active is
  // recorded for the report; non-blocking for the measurements above.
  await Promise.race([statusPoll, sleep(180_000)]);

  // ── report ────────────────────────────────────────────────────────────────
  const pt = (health!['phase_timings_ms'] ?? {}) as Record<string, number>;
  const s = (k: string): string => (t[k] !== undefined ? `${(t[k]! / 1000).toFixed(1)}s` : 'n/a');
  console.log('\n══ Cold-start breakdown (all relative to launch call) ═');
  console.log(`launch API returned        ${s('t_launch_api')}`);
  console.log(`IP assigned                ${s('t_ip')}`);
  console.log(`first /health response     ${s('t_http')}   (VM boot + cloud-init + venv import + bind)`);
  console.log(`/health ok (model ready)   ${s('t_ready')}   (+ weights→GPU + warmup, overlaps boot)`);
  console.log(`status=active (API)        ${s('t_active')}   (reporting only — never waited on)`);
  console.log(`first frame                ${s('t_first_frame')}`);
  console.log(`──────────────────────────────────────────────────────`);
  console.log(`TOTAL launch → first frame ${s('t_first_frame')}`);
  console.log(`\npod-side: prefetch=${pt['prefetch_total_ms']}ms from_pretrained=${pt['from_pretrained_ms']}ms warmup=${pt['warmup_inference_ms']}ms`);
  console.log(`steady-state per-frame: ${frameTimes.map((m) => `${m}ms`).join(', ')} (first includes WS+config setup)`);
  console.log(`frames written to ${outDir}`);

  if (KEEP) {
    console.log(`\n[bench] --keep: instance ${instanceId} RUNNING & BILLING (~$${((inst?.instance_type.price_cents_per_hour ?? 0) / 100).toFixed(2)}/hr).`);
    console.log('[bench] To point the backend at it (locally or Railway):');
    console.log(`  IMAGE_PROVIDER=lambda`);
    console.log(`  LAMBDA_IMAGE_URL=ws://${ip}:${PORT}/ws?token=${wsToken}`);
    console.log(`[bench] Terminate later: tsx scripts/lambda/instances.ts --terminate ${instanceId}`);
  }
} finally {
  if (!KEEP && instanceId) {
    console.log(`[bench] terminating ${instanceId}...`);
    await client.terminate([instanceId]).catch((e) => console.error('terminate failed:', e));
  }
}
