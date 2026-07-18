/**
 * GPU-type benchmark for the image server: launch each candidate type,
 * boot the real serving stack off the region's populated filesystem, measure
 * per-frame generation latency through the real WS path, and terminate.
 *
 * Output: one summary row per type — boot-to-ready, gen p50/p95, VRAM
 * headroom, $/hr and $/frame — the data behind LAMBDA_INSTANCE_TYPES
 * fallback ordering (pool sweeps TYPE-MAJOR across regions).
 *
 * Usage (from backend/):
 *   tsx scripts/lambda/bench-gpu-types.ts --region us-east-1 \
 *     --types gpu_1x_a100_sxm4,gpu_1x_a6000 [--frames 30] [--capacity-mins 5]
 *
 * The region's kiki-image-<region> filesystem MUST be populated
 * (setup-lambda.ts). Types with no capacity within --capacity-mins are
 * recorded as `no_capacity` and skipped — rerun later for those.
 */

// Bench-only: instances present the self-signed fleet cert; trust it for
// both fetch (health) and ws (frames).
process.env['NODE_TLS_REJECT_UNAUTHORIZED'] = '0';

import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { launchWithRetry, requireClient, sleep } from './lambdaApi.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

function getArg(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 ? process.argv[idx + 1] : undefined;
}

const REGION = getArg('--region');
const TYPES = (getArg('--types') ?? '').split(',').map((s) => s.trim()).filter(Boolean);
const FRAMES = Number(getArg('--frames') ?? 30);
const CAPACITY_MINS = Number(getArg('--capacity-mins') ?? 5);
const PORT = 8766;
if (!REGION || TYPES.length === 0) {
  console.error('Usage: tsx scripts/lambda/bench-gpu-types.ts --region <r> --types t1,t2 [--frames 30] [--capacity-mins 5]');
  process.exit(1);
}

const client = requireClient();
const FS_NAME = `kiki-image-${REGION}`;
const sketch = readFileSync(resolve(__dirname, 'test-sketch.jpg'));

interface Row {
  type: string;
  priceHr: number | null;
  outcome: string; // ok | no_capacity | boot_timeout | load_error | bench_error
  bootToReadyS?: number;
  warmupS?: number;
  genP50?: number;
  genP95?: number;
  vramFreeGb?: number;
  usdPerFrame?: number;
  note?: string;
}
const rows: Row[] = [];

async function priceOf(type: string): Promise<number | null> {
  try {
    const res = await fetch('https://cloud.lambda.ai/api/v1/instance-types', {
      headers: { Authorization: `Bearer ${process.env['LAMBDA_API_KEY']}` },
    });
    const j = (await res.json()) as { data: Record<string, { instance_type: { price_cents_per_hour: number } }> };
    return (j.data[type]?.instance_type.price_cents_per_hour ?? 0) / 100 || null;
  } catch {
    return null;
  }
}

/** Serial-mode latency bench over the pod WS protocol: send a sketch, wait
 * for its frame, repeat. Returns per-frame latencies (ms). */
function benchFrames(url: string, count: number): Promise<number[]> {
  return new Promise((resolveP, reject) => {
    const ws = new WebSocket(url, { perMessageDeflate: false, rejectUnauthorized: false });
    const latencies: number[] = [];
    let sentAt = 0;
    const overall = setTimeout(() => { ws.close(); reject(new Error('bench timed out')); }, 120_000 + count * 5_000);
    const sendNext = (): void => {
      sentAt = Date.now();
      ws.send(sketch);
    };
    ws.on('open', () => {
      ws.send(JSON.stringify({ type: 'config', prompt: 'a cheerful frog on a lily pad, watercolor', steps: 4, seed: 7 }));
      sendNext();
    });
    ws.on('message', (_data: Buffer, isBinary: boolean) => {
      if (!isBinary) return; // frame_meta preamble
      latencies.push(Date.now() - sentAt);
      if (latencies.length >= count) {
        clearTimeout(overall);
        ws.close();
        resolveP(latencies);
      } else {
        sendNext();
      }
    });
    ws.on('error', (e) => { clearTimeout(overall); reject(e); });
  });
}

const pct = (xs: number[], p: number): number => {
  const sorted = [...xs].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] ?? 0;
};

for (const type of TYPES) {
  const priceHr = await priceOf(type);
  console.log(`\n===== ${type} (${priceHr != null ? `$${priceHr}/hr` : 'price?'}) =====`);
  const wsToken = randomBytes(16).toString('hex');
  const name = `kiki-bench-${Date.now()}`;
  const userData = `#cloud-config
write_files:
  - path: /etc/kiki.env
    permissions: '0600'
    content: |
      KIKI_WS_TOKEN=${wsToken}
runcmd:
  - [systemd-run, --unit=kiki, --property=Restart=on-failure, bash, /lambda/nfs/${FS_NAME}/kiki/boot.sh]
`;
  let instanceId: string | null = null;
  try {
    const t0 = Date.now();
    let ids: string[];
    try {
      ids = await launchWithRetry(
        client,
        {
          region_name: REGION,
          instance_type_name: type,
          ssh_key_names: [(await client.listSshKeys())[0]!.name],
          file_system_names: [FS_NAME],
          name,
          image: { family: 'lambda-stack-24-04' },
          user_data: userData,
        },
        CAPACITY_MINS,
      );
    } catch (e) {
      console.log(`  no capacity within ${CAPACITY_MINS} min (${(e as Error).message})`);
      rows.push({ type, priceHr, outcome: 'no_capacity' });
      continue;
    }
    instanceId = ids[0] ?? null;
    if (!instanceId) throw new Error('no instance id');
    console.log(`  launched ${instanceId}; waiting for IP + boot…`);

    // IP, then /health (TLS-agnostic: try https then http).
    let ip: string | null = null;
    while (!ip) {
      const inst = await client.getInstance(instanceId);
      if (['terminated', 'unhealthy', 'preempted'].includes(inst.status)) throw new Error(`instance ${inst.status}`);
      ip = inst.ip ?? null;
      if (!ip) await sleep(10_000);
    }
    console.log(`  ip ${ip}; polling /health (up to 30 min — non-Hopper compiles can be slow)…`);
    const bootDeadline = Date.now() + 30 * 60_000;
    let health: Record<string, unknown> | null = null;
    let scheme = 'https';
    while (Date.now() < bootDeadline) {
      for (const s of ['https', 'http']) {
        try {
          const res = await fetch(`${s}://${ip}:${PORT}/health`, {
            signal: AbortSignal.timeout(4000),
          }).catch(() => null);
          if (res?.ok) {
            health = (await res.json()) as Record<string, unknown>;
            scheme = s;
            break;
          }
        } catch { /* keep polling */ }
      }
      if (health) break;
      await sleep(15_000);
    }
    if (!health) {
      rows.push({ type, priceHr, outcome: 'boot_timeout', note: 'no /health within 30 min (VRAM OOM at load? ssh + journalctl -u kiki)' });
      continue;
    }
    const bootToReadyS = Math.round((Date.now() - t0) / 1000);
    const timings = (health['phase_timings_ms'] ?? {}) as Record<string, number>;
    const vramFreeGb = typeof health['vram_free_gb'] === 'number' ? (health['vram_free_gb'] as number) : undefined;
    console.log(`  READY in ${bootToReadyS}s (warmup ${(timings['warmup_inference_ms'] ?? 0) / 1000}s, vram free ${vramFreeGb ?? '?'} GB) — benching ${FRAMES} frames…`);

    const wsUrl = `${scheme === 'https' ? 'wss' : 'ws'}://${ip}:${PORT}/ws?token=${wsToken}`;
    const latencies = await benchFrames(wsUrl, FRAMES);
    const p50 = pct(latencies, 0.5);
    const p95 = pct(latencies, 0.95);
    const usdPerFrame = priceHr != null ? (p50 / 1000) * (priceHr / 3600) : undefined;
    console.log(`  gen p50 ${p50}ms p95 ${p95}ms — $${usdPerFrame?.toFixed(5) ?? '?'} / frame`);
    rows.push({
      type,
      priceHr,
      outcome: 'ok',
      bootToReadyS,
      warmupS: Math.round((timings['warmup_inference_ms'] ?? 0) / 1000),
      genP50: p50,
      genP95: p95,
      vramFreeGb,
      usdPerFrame,
    });
  } catch (err) {
    console.log(`  ERROR: ${(err as Error).message}`);
    rows.push({ type, priceHr, outcome: 'bench_error', note: (err as Error).message });
  } finally {
    if (instanceId) {
      console.log(`  terminating ${instanceId}…`);
      await client.terminate([instanceId]).catch(() => {});
    }
  }
}

console.log('\n================= SUMMARY =================');
console.log('type                          $/hr   outcome      boot_s  warm_s  p50_ms  p95_ms  vram_free  $/frame');
for (const r of rows) {
  console.log(
    `${r.type.padEnd(30)}${(r.priceHr != null ? r.priceHr.toFixed(2) : '?').padEnd(7)}${r.outcome.padEnd(13)}` +
    `${String(r.bootToReadyS ?? '').padEnd(8)}${String(r.warmupS ?? '').padEnd(8)}${String(r.genP50 ?? '').padEnd(8)}` +
    `${String(r.genP95 ?? '').padEnd(8)}${String(r.vramFreeGb ?? '').padEnd(11)}${r.usdPerFrame?.toFixed(5) ?? ''}` +
    `${r.note ? `  // ${r.note}` : ''}`,
  );
}
