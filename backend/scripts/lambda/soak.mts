/**
 * Soak test through the DEPLOYED backend: N concurrent WS clients on
 * /v1/stream, paced frames, per-client frame counts + status messages.
 * Used to validate the H100 pool (failover, autoscale, downgrade-to-fal) —
 * see documents/plans/lambda-image-provider.md "Production soak" entry.
 *
 * Run from backend/ (JWT secret from `railway variables`, user must be a
 * test account for the --provider override; 'none' exercises the auto path):
 *   JWT_ACCESS_SECRET=... USER_ID=... npx tsx scripts/lambda/soak.mts \
 *     --clients 6 --duration 600 --pace 1500 --provider none|lambda|fal
 */
import { readFileSync } from 'node:fs';
import { SignJWT } from 'jose';
import WebSocket from 'ws';

const secret = new TextEncoder().encode(process.env['JWT_ACCESS_SECRET']!);
const userId = process.env['USER_ID']!;
const BACKEND = process.env['BACKEND'] ?? 'wss://kiki-backend-production-eb81.up.railway.app';

function getArg(f: string, d: string): string {
  const i = process.argv.indexOf(f);
  return i !== -1 ? process.argv[i + 1]! : d;
}
const CLIENTS = Number(getArg('--clients', '6'));
const DURATION_MS = Number(getArg('--duration', '600')) * 1000;
const PACE_MS = Number(getArg('--pace', '1500'));
const PROVIDER = getArg('--provider', 'lambda'); // 'none' = no override (auto path)

const sketch = readFileSync('scripts/lambda/test-sketch.jpg');
const PROMPTS = ['a cute cat, watercolor', 'a red sports car', 'a mountain landscape', 'a pirate ship', 'a bowl of fruit', 'a dragon, ink'];

interface Stat {
  sent: number; received: number; statuses: string[]; errors: string[];
  closed?: string; lastFrameAt?: number;
}
const stats: Stat[] = [];

async function mkToken(): Promise<string> {
  return new SignJWT({ typ: 'access' })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime('7200s')
    .setJti(crypto.randomUUID())
    .sign(secret);
}

async function runClient(id: number): Promise<void> {
  const st: Stat = { sent: 0, received: 0, statuses: [], errors: [] };
  stats[id] = st;
  const token = await mkToken();
  const ws = new WebSocket(`${BACKEND}/v1/stream${PROVIDER === 'none' ? '' : `?imageProvider=${PROVIDER}`}`, {
    headers: { Authorization: `Bearer ${token}`, 'X-Kiki-Client': 'devscript:soak' },
    perMessageDeflate: false,
  });
  const done = new Promise<void>((res) => ws.on('close', (code, reason) => {
    st.closed = `${code} ${reason}`;
    res();
  }));
  ws.on('error', (e) => st.errors.push(e.message));
  ws.on('open', () => {
    ws.send(JSON.stringify({ type: 'config', prompt: PROMPTS[id % PROMPTS.length], steps: 4, seed: 100 + id, requestId: `soak-${id}` }));
    const timer = setInterval(() => {
      if (ws.readyState !== WebSocket.OPEN) { clearInterval(timer); return; }
      ws.send(sketch);
      st.sent += 1;
    }, PACE_MS);
    setTimeout(() => { clearInterval(timer); ws.close(); }, DURATION_MS);
  });
  ws.on('message', (data: Buffer, isBinary: boolean) => {
    if (isBinary) { st.received += 1; st.lastFrameAt = Date.now(); return; }
    try {
      const m = JSON.parse(data.toString());
      if (m.type === 'frame') { st.received += 1; st.lastFrameAt = Date.now(); return; }
      const line = `${m.type}:${m.state ?? m.message ?? ''}`;
      if (st.statuses[st.statuses.length - 1] !== line) st.statuses.push(line);
    } catch { /* ignore */ }
  });
  await done;
}

const t0 = Date.now();
const progress = setInterval(() => {
  const s = stats.map((x, i) => `c${i}:${x?.sent ?? 0}/${x?.received ?? 0}`).join(' ');
  console.log(`[${Math.round((Date.now() - t0) / 1000)}s] sent/recv ${s}`);
}, 30_000);

await Promise.all(Array.from({ length: CLIENTS }, (_, i) => runClient(i)));
clearInterval(progress);

console.log('\n=== RESULTS ===');
stats.forEach((s, i) => {
  console.log(`client ${i}: sent=${s.sent} received=${s.received} closed="${s.closed}" errors=${JSON.stringify(s.errors)}`);
  console.log(`  statuses: ${s.statuses.join(' | ')}`);
});
