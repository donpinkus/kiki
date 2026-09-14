/**
 * E2E validation of the Animate-screen path through the DEPLOYED backend
 * (/v1/animate — replaces the retired stream-idle validate-video.mts):
 *   phase 1 — single-keyframe animate_request → expect video_started,
 *             streamed video_frame_data, and a video_complete_data MP4.
 *   phase 2 — TWO-keyframe request (start + end) → same, proving the new
 *             multi-keyframe conditioning path through backend + LTX server.
 *   phase 3 — fire, then cancel mid-generation → expect video_cancelled and
 *             NO stale video_complete_data afterwards.
 *   phases 6/7 (HOSTED=1 only — these cost real fal money, ~$0.30-0.60 each)
 *           — engine=wan3 and engine=h3max start+end-keyframe requests through
 *             the hosted path; records wall time + the cost meta the backend
 *             metered, and saves the MP4s next to the LTX ones for A/B.
 * Also records system_availability pushes and usage events.
 *
 * Run from backend/:
 *   JWT_ACCESS_SECRET=... USER_ID=... npx tsx scripts/lambda/validate-animate.mts
 * Optional: BACKEND=wss://... (defaults to production); HOSTED=1 to run the
 * fal engine phases; SKIP_LTX=1 to run only those (no video pool needed).
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { SignJWT } from 'jose';
import WebSocket from 'ws';

const secret = new TextEncoder().encode(process.env['JWT_ACCESS_SECRET']!);
const userId = process.env['USER_ID']!;
const BACKEND = process.env['BACKEND'] ?? 'wss://kiki-backend-production-eb81.up.railway.app';
const sketch = readFileSync('scripts/lambda/test-sketch.jpg');
const startB64 = sketch.toString('base64');
// End keyframe: reuse a prior generated frame when present, else the sketch.
let endB64 = startB64;
try {
  endB64 = readFileSync('scripts/lambda/out/frame-1.jpg').toString('base64');
} catch { /* fall back to the sketch */ }

const token = await new SignJWT({ typ: 'access' })
  .setProtectedHeader({ alg: 'HS256' })
  .setSubject(userId)
  .setIssuedAt()
  .setExpirationTime('3600s')
  .setJti(crypto.randomUUID())
  .sign(secret);

const animateId = `validate-${Math.random().toString(36).slice(2, 10)}`;
const ws = new WebSocket(`${BACKEND}/v1/animate?animateId=${animateId}`, {
  headers: { Authorization: `Bearer ${token}` },
  perMessageDeflate: false,
  maxPayload: 64 * 1024 * 1024,
});

const events: { t: number; type: string; extra?: string }[] = [];
const t0 = Date.now();
const note = (type: string, extra?: string): void => {
  events.push({ t: Date.now() - t0, type, extra });
  console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] ${type}${extra ? ` ${extra}` : ''}`);
};

let videoFrames = 0;
const completes: { requestId: string; bytes: number; mp4: Buffer; meta: Record<string, unknown> }[] = [];
const HOSTED = process.env['HOSTED'] === '1';
const SKIP_LTX = process.env['SKIP_LTX'] === '1';

ws.on('open', () => note('ws_open'));
ws.on('message', (data: Buffer, isBinary: boolean) => {
  if (isBinary) return;
  try {
    const m = JSON.parse(data.toString()) as Record<string, unknown>;
    switch (m['type']) {
      case 'system_availability': {
        const vid = (m['video'] ?? {}) as Record<string, unknown>;
        note('system_availability', `video=${String(vid['availability'])} stage=${String(vid['stage'] ?? '-')}`);
        break;
      }
      case 'status': note('status', String(m['status'])); break;
      case 'video_started': note('video_started', String(m['requestId'])); break;
      case 'video_frame_data': videoFrames += 1; break;
      case 'video_complete_data': {
        const meta = (m['meta'] ?? {}) as Record<string, unknown>;
        const mp4 = Buffer.from(String(m['data']), 'base64');
        completes.push({ requestId: String(meta['requestId']), bytes: mp4.length, mp4, meta });
        note(
          'video_complete_data',
          `req=${String(meta['requestId'])} bytes=${mp4.length} frames=${String(meta['frames'])}` +
            (meta['engine'] ? ` engine=${String(meta['engine'])} genMs=${String(meta['genMs'])} cost=$${String(meta['costUsd'])}` : ''),
        );
        break;
      }
      case 'video_cancelled': note('video_cancelled', `req=${String(m['requestId'])} err=${String(m['error'] ?? '')}`); break;
      case 'usage': note('usage', `$${Number(m['spendUsd']).toFixed(3)}`); break;
      case 'error': note('server_error', `${String(m['code'] ?? '')} ${String(m['message'] ?? '')}`); break;
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

await waitFor(() => events.some((e) => e.type === 'system_availability'), 15_000);

const request = (
  requestId: string,
  keyframes: object[],
  prompt: string,
  extra: Record<string, unknown> = {},
): void => {
  ws.send(JSON.stringify({ type: 'animate_request', requestId, prompt, numFrames: 49, keyframes, ...extra }));
};

if (SKIP_LTX) {
  note('skipping LTX phases (SKIP_LTX=1)');
}
// ── Phase 1: single keyframe ──
if (!SKIP_LTX) {
note('phase1_request (single keyframe, 49 frames)');
request('val-single', [{ data: startB64, position: 0 }], 'gentle motion, slow zoom in');
const got1 = await waitFor(() => completes.some((c) => c.requestId === 'val-single'), 180_000);
note('phase1_result', got1 ? `OK frames_streamed=${videoFrames}` : 'TIMEOUT');

// ── Phase 2: start + end keyframes ──
note('phase2_request (start + end keyframes)');
request('val-multi', [
  { data: startB64, position: 0 },
  { data: endB64, position: 1, strength: 1.0 },
], 'the sketch morphs smoothly into the finished scene');
const got2 = await waitFor(() => completes.some((c) => c.requestId === 'val-multi'), 180_000);
note('phase2_result', got2 ? 'OK (multi-keyframe delivered)' : 'TIMEOUT');

// ── Phase 3: cancel mid-generation ──
note('phase3_request_then_cancel');
request('val-cancel', [{ data: startB64, position: 0 }], 'test cancel');
await waitFor(() => events.some((e) => e.type === 'video_started' && e.extra === 'val-cancel'), 30_000);
await sleep(2_000); // mid-generation (~10s total)
ws.send(JSON.stringify({ type: 'animate_cancel', requestId: 'val-cancel' }));
const cancelled = await waitFor(
  () => events.some((e) => e.type === 'video_cancelled' && (e.extra ?? '').includes('val-cancel')),
  60_000,
);
await sleep(15_000); // long enough for a doomed render to finish server-side
const staleLeaked = completes.some((c) => c.requestId === 'val-cancel');
note('phase3_result', !cancelled ? 'no cancel ack' : staleLeaked ? 'STALE LEAKED (BUG)' : 'cancel OK, stale suppressed');

// ── Phase 4: sound prompt (composed server-side) ──
note('phase4_request (audioPrompt riding along)');
request('val-sound', [{ data: startB64, position: 0 }], 'gentle waves roll in', {
  audioPrompt: 'seagulls cry over soft surf',
});
const got4 = await waitFor(() => completes.some((c) => c.requestId === 'val-sound'), 180_000);
note('phase4_result', got4 ? 'OK (sound-prompted clip delivered)' : 'TIMEOUT');

// ── Phase 5: audio disabled → silent MP4 ──
note('phase5_request (enableAudio: false)');
request('val-silent', [{ data: startB64, position: 0 }], 'gentle waves roll in', {
  audioPrompt: 'should be ignored',
  enableAudio: false,
});
const got5 = await waitFor(() => completes.some((c) => c.requestId === 'val-silent'), 180_000);
note('phase5_result', got5 ? 'OK (silent clip delivered — verify audio=False in pod logs)' : 'TIMEOUT');
}

// ── Phases 6/7: hosted fal engines (opt-in, costs money) ──
if (HOSTED) {
  for (const engine of ['wan3', 'h3max'] as const) {
    const req = `val-${engine}`;
    note(`hosted_request (${engine}, start+end keyframes, 97 frames = 4s)`);
    const t = Date.now();
    request(req, [
      { data: startB64, position: 0 },
      { data: endB64, position: 1 },
    ], 'the sketch morphs smoothly into the finished scene, gentle camera drift', {
      engine,
      audioPrompt: 'soft ambient wind',
      numFrames: 97,
    });
    const got = await waitFor(
      () => completes.some((c) => c.requestId === req)
        || events.some((e) => e.type === 'video_cancelled' && (e.extra ?? '').includes(req)),
      10 * 60_000,
    );
    const done = completes.find((c) => c.requestId === req);
    note(
      `hosted_result (${engine})`,
      !got ? 'TIMEOUT' : done ? `OK wall=${((Date.now() - t) / 1000).toFixed(1)}s meta=${JSON.stringify(done.meta)}` : 'FAILED (video_cancelled)',
    );
  }
} else {
  note('skipping hosted engine phases (set HOSTED=1 to run wan3 + h3max; costs ~$1)');
}

// Persist outputs for eyeballing.
for (const c of completes) {
  const path = `scripts/lambda/out/animate-${c.requestId}.mp4`;
  writeFileSync(path, c.mp4);
  console.log(`wrote ${path} (${c.bytes} bytes)`);
}

console.log('\nSummary:', JSON.stringify({
  completes: completes.map((c) => ({ req: c.requestId, bytes: c.bytes })),
  videoFrames,
  started: events.filter((e) => e.type === 'video_started').length,
  cancelled: events.filter((e) => e.type === 'video_cancelled').length,
  availability: events.filter((e) => e.type === 'system_availability').map((e) => e.extra),
}, null, 2));
ws.close();
process.exit(0);
