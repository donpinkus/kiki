/**
 * Multi-user GPU-sharing load test against a kiki image server instance.
 *
 * Opens N concurrent WebSocket clients, each with its OWN config (prompt,
 * seed, unique config requestId), and drives frames in one of two modes:
 *   serial       — send next sketch only after the previous frame arrives
 *                  (clean per-frame latency under contention)
 *   paced:<sec>  — send a sketch every <sec> seconds regardless of responses
 *                  (measures achieved fps under a client-side rate cap)
 *
 * Reports per client: sent, received, achieved fps, latency p50/p95 (serial),
 * plus fairness (max/min fps across clients) and config-isolation violations
 * (a client receiving frame_meta with another client's config requestId
 * would mean per-connection config state bleeds — must be zero).
 *
 * Usage (from backend/):
 *   tsx scripts/lambda/loadtest.ts --url 'ws://<ip>:8766/ws?token=<t>' \
 *     --clients 3 --mode serial --duration 60
 *   tsx scripts/lambda/loadtest.ts --url ... --clients 4 --mode paced:1 --duration 60
 */

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';

const __dirname = dirname(fileURLToPath(import.meta.url));

function getArg(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 ? process.argv[idx + 1] : undefined;
}

const URL_ARG = getArg('--url');
const CLIENTS = Number(getArg('--clients') ?? '2');
const MODE = getArg('--mode') ?? 'serial'; // serial | paced:<seconds>
const DURATION_S = Number(getArg('--duration') ?? '60');
if (!URL_ARG) {
  console.error("Usage: tsx scripts/lambda/loadtest.ts --url 'ws://<ip>:8766/ws?token=..' [--clients N] [--mode serial|paced:1] [--duration 60]");
  process.exit(1);
}
const PACED_INTERVAL_MS = MODE.startsWith('paced:') ? Number(MODE.split(':')[1]) * 1000 : 0;

const sketch = readFileSync(resolve(__dirname, 'test-sketch.jpg'));
const PROMPTS = [
  'a cute cat, watercolor',
  'a red sports car, oil painting',
  'a mountain landscape, pencil sketch',
  'a pirate ship at sea, digital art',
  'a bowl of fruit, impressionist',
  'a robot dancing, comic style',
  'a cozy cabin in snow, gouache',
  'a dragon flying, ink wash',
];

interface ClientStats {
  id: number;
  sent: number;
  received: number;
  latencies: number[]; // serial mode only
  isolationViolations: number;
  errors: string[];
  firstFrameAt?: number;
  lastFrameAt?: number;
}

async function runClient(id: number, endAt: number): Promise<ClientStats> {
  const stats: ClientStats = { id, sent: 0, received: 0, latencies: [], isolationViolations: 0, errors: [] };
  const myConfigId = `lt-c${id}`;
  const ws = new WebSocket(URL_ARG!, { perMessageDeflate: false });

  await new Promise<void>((res, rej) => {
    ws.on('open', () => res());
    ws.on('error', (e) => rej(e));
  });

  ws.send(
    JSON.stringify({
      type: 'config',
      prompt: PROMPTS[id % PROMPTS.length],
      steps: 4,
      seed: 1000 + id,
      requestId: myConfigId,
    }),
  );

  let lastSentAt = 0;
  const sendFrame = (): void => {
    if (Date.now() >= endAt || ws.readyState !== WebSocket.OPEN) return;
    lastSentAt = Date.now();
    stats.sent += 1;
    ws.send(sketch);
  };

  let pacer: NodeJS.Timeout | null = null;
  const done = new Promise<void>((res) => {
    ws.on('message', (data: Buffer, isBinary: boolean) => {
      if (!isBinary) {
        try {
          const msg = JSON.parse(data.toString()) as { type?: string; requestId?: string | null };
          if (msg.type === 'frame_meta' && msg.requestId && msg.requestId !== myConfigId) {
            stats.isolationViolations += 1;
          }
        } catch {
          /* status messages etc. */
        }
        return;
      }
      stats.received += 1;
      const now = Date.now();
      stats.firstFrameAt ??= now;
      stats.lastFrameAt = now;
      if (PACED_INTERVAL_MS === 0) {
        stats.latencies.push(now - lastSentAt);
        if (now < endAt) sendFrame();
        else ws.close();
      }
    });
    ws.on('error', (e) => {
      stats.errors.push(e.message);
      res();
    });
    ws.on('close', () => res());
  });

  // Wait for ready status is implicit — server buffers until pipeline ready.
  if (PACED_INTERVAL_MS > 0) {
    sendFrame();
    pacer = setInterval(() => {
      if (Date.now() >= endAt) {
        if (pacer) clearInterval(pacer);
        ws.close();
        return;
      }
      sendFrame();
    }, PACED_INTERVAL_MS);
  } else {
    sendFrame(); // serial: send-on-receive from here
  }

  // Hard stop safety
  setTimeout(() => {
    if (pacer) clearInterval(pacer);
    if (ws.readyState === WebSocket.OPEN) ws.close();
  }, endAt - Date.now() + 15_000);

  await done;
  return stats;
}

function pct(arr: number[], p: number): number {
  if (arr.length === 0) return 0;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]!;
}

console.log(`[loadtest] ${CLIENTS} clients, mode=${MODE}, duration=${DURATION_S}s → ${URL_ARG!.split('?')[0]}`);
const endAt = Date.now() + DURATION_S * 1000;
const results = await Promise.all(
  Array.from({ length: CLIENTS }, (_, i) => runClient(i, endAt)),
);

let totalReceived = 0;
const fpsList: number[] = [];
for (const r of results) {
  const activeMs = r.lastFrameAt && r.firstFrameAt ? r.lastFrameAt - r.firstFrameAt : 0;
  const fps = activeMs > 500 && r.received > 1 ? (r.received - 1) / (activeMs / 1000) : 0;
  fpsList.push(fps);
  totalReceived += r.received;
  const lat = r.latencies.length
    ? `  latency p50=${pct(r.latencies, 50)}ms p95=${pct(r.latencies, 95)}ms`
    : '';
  console.log(
    `client ${r.id}: sent=${r.sent} recv=${r.received} fps=${fps.toFixed(2)}${lat}` +
      (r.isolationViolations ? `  ISOLATION VIOLATIONS=${r.isolationViolations}` : '') +
      (r.errors.length ? `  errors=${r.errors.join(';')}` : ''),
  );
}
const fpsMin = Math.min(...fpsList);
const fpsMax = Math.max(...fpsList);
console.log(
  `TOTAL: recv=${totalReceived} aggregate_fps=${(fpsList.reduce((a, b) => a + b, 0)).toFixed(2)} ` +
    `fairness(min/max)=${fpsMax > 0 ? (fpsMin / fpsMax).toFixed(2) : 'n/a'} ` +
    `isolation_violations=${results.reduce((a, r) => a + r.isolationViolations, 0)}`,
);