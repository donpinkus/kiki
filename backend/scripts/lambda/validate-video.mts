/**
 * E2E validation of the video path through the DEPLOYED backend:
 *   phase 1 — draw (paced frames), stop, expect the 3s idle trigger to fire
 *             (video_started) and a video_complete_data to arrive.
 *   phase 2 — draw again, trigger another video, then send a frame MID-flight
 *             and verify the animation is cancelled/ignored (no stale
 *             video_complete_data after resuming).
 * Also records video_availability pushes.
 *
 * Run from backend/:
 *   JWT_ACCESS_SECRET=... USER_ID=... npx tsx scripts/lambda/validate-video.mts
 */
import { readFileSync } from 'node:fs';
import { SignJWT } from 'jose';
import WebSocket from 'ws';

const secret = new TextEncoder().encode(process.env['JWT_ACCESS_SECRET']!);
const userId = process.env['USER_ID']!;
const BACKEND = process.env['BACKEND'] ?? 'wss://kiki-backend-production-eb81.up.railway.app';
const sketch = readFileSync('scripts/lambda/test-sketch.jpg');

const token = await new SignJWT({ typ: 'access' })
  .setProtectedHeader({ alg: 'HS256' })
  .setSubject(userId)
  .setIssuedAt()
  .setExpirationTime('3600s')
  .setJti(crypto.randomUUID())
  .sign(secret);

const streamId = `validate-${Math.random().toString(36).slice(2, 10)}`;
const ws = new WebSocket(`${BACKEND}/v1/stream?streamId=${streamId}`, {
  headers: { Authorization: `Bearer ${token}` },
  perMessageDeflate: false,
});

const log: string[] = [];
const events: { t: number; type: string; extra?: string }[] = [];
const t0 = Date.now();
const note = (type: string, extra?: string): void => {
  events.push({ t: Date.now() - t0, type, extra });
  console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] ${type}${extra ? ` ${extra}` : ''}`);
};

let imageFrames = 0;
let videoCompletes = 0;
let lastVideoCompleteAt = 0;

ws.on('open', () => {
  note('ws_open');
  ws.send(JSON.stringify({
    type: 'config',
    prompt: 'a cheerful frog on a lily pad',
    animationPrompt: 'the frog blinks, gentle ripples on the water',
    steps: 4,
    seed: 42,
  }));
});
ws.on('message', (data: Buffer, isBinary: boolean) => {
  if (isBinary) return;
  try {
    const m = JSON.parse(data.toString()) as Record<string, unknown>;
    switch (m['type']) {
      case 'state': note('state', String(m['state'])); break;
      case 'video_availability': note('video_availability', String(m['availability'])); break;
      case 'video_started': note('video_started', String(m['requestId'])); break;
      case 'video_frame_data': break; // noisy
      case 'video_complete_data': {
        videoCompletes += 1;
        lastVideoCompleteAt = Date.now();
        const meta = (m['meta'] ?? {}) as Record<string, unknown>;
        note('video_complete_data', `req=${String(meta['requestId'])} bytes=${String(m['data']).length}`);
        break;
      }
      case 'video_cancelled': note('video_cancelled', `req=${String(m['requestId'])} err=${String(m['error'] ?? '')}`); break;
      case 'frame': imageFrames += 1; break;
      case 'usage': note('usage', `$${Number(m['spendUsd']).toFixed(3)}`); break;
      default: break;
    }
  } catch { /* ignore */ }
});
ws.on('close', (code) => note('ws_close', String(code)));
ws.on('error', (e) => note('ws_error', e.message));

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const waitFor = async (cond: () => boolean, ms: number): Promise<boolean> => {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > ms) return false;
    await sleep(250);
  }
  return true;
};

await waitFor(() => events.some((e) => e.type === 'state' && e.extra === 'ready'), 30_000);

// ── Phase 1: draw, stop, expect auto animation ──
note('phase1_draw');
for (let i = 0; i < 4; i++) { ws.send(sketch); await sleep(1500); }
note('phase1_stop_drawing');
const got1 = await waitFor(() => videoCompletes >= 1, 60_000);
note('phase1_result', got1 ? 'AUTO ANIMATION DELIVERED' : 'TIMEOUT — no animation');

// ── Phase 2: draw again, let a video fire, interrupt it mid-flight ──
await sleep(1000);
note('phase2_draw');
for (let i = 0; i < 3; i++) { ws.send(sketch); await sleep(1500); }
note('phase2_stop_drawing');
const started2 = await waitFor(
  () => events.filter((e) => e.type === 'video_started').length >= 2,
  30_000,
);
if (started2) {
  await sleep(2000); // mid-generation (~9.5s total)
  note('phase2_interrupt (drawing again mid-generation)');
  const completesBefore = videoCompletes;
  ws.send(sketch);
  await sleep(15_000); // long enough for the doomed render to finish server-side
  const staleDelivered = videoCompletes > completesBefore &&
    events.some((e) => e.type === 'video_complete_data' && e.t > events.find((x) => x.extra?.includes('interrupt'))!.t);
  note('phase2_result', staleDelivered ? 'STALE ANIMATION LEAKED (BUG)' : 'stale correctly suppressed');
  // The interrupt frame re-armed the idle window with no further drawing —
  // a FRESH animation for the new idle period is expected behavior.
} else {
  note('phase2_result', 'second video never started');
}
await sleep(20_000);
console.log('streamId:', streamId);
console.log('\nSummary:', JSON.stringify({
  imageFrames,
  videoCompletes,
  availability: events.filter((e) => e.type === 'video_availability').map((e) => e.extra),
  started: events.filter((e) => e.type === 'video_started').length,
  cancelled: events.filter((e) => e.type === 'video_cancelled').length,
}, null, 2));
ws.close();
process.exit(0);
