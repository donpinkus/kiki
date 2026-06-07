// One-shot smoke test: mint an iOS-style access token, ingest events + a drawing,
// then read them back through the admin API. Exits non-zero on any failure.
import { SignJWT } from 'jose';

const BASE = 'http://localhost:8080';
const SECRET = process.env.JWT_ACCESS_SECRET;
const PASS = process.env.ADMIN_PASSWORD;
const SVC = process.env.INSIGHTS_INGEST_KEY;
// Must be a real UUID — the shared backend `users.user_id` is UUID. The bash
// harness seeds this exact row (+ monthly_usage) to simulate the backend.
const USER = '11111111-1111-1111-1111-111111111111';

const assert = (cond, msg) => { if (!cond) { console.error('FAIL:', msg); process.exit(1); } console.log('ok:', msg); };

const token = await new SignJWT({ typ: 'access' })
  .setProtectedHeader({ alg: 'HS256' })
  .setSubject(USER)
  .setIssuedAt()
  .setExpirationTime('1h')
  .sign(new TextEncoder().encode(SECRET));

// 1. iOS ingest (Bearer) — a couple events incl. a session-producing one.
let r = await fetch(`${BASE}/ingest`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
  body: JSON.stringify({ events: [
    { name: 'app.foregrounded', occurred_at: '2026-06-06T12:00:00Z', properties: { email: 'tester@example.com' } },
    { name: 'style.selected', occurred_at: Date.now(), properties: { style_id: 'pastel' }, drawing_id: 'draw-1' },
    { name: 'app.backgrounded', occurred_at: '2026-06-06T12:05:00Z', properties: { duration_ms: 300000 } },
  ] }),
});
let j = await r.json();
assert(r.ok && j.accepted === 3, `ingest accepted 3 events (got ${JSON.stringify(j)})`);

// 2. Backend ingest (service key) — must carry user_id.
r = await fetch(`${BASE}/ingest`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'x-insights-key': SVC },
  body: JSON.stringify({ events: [{ name: 'pod.provision.completed', user_id: USER, properties: { dc: 'US-NC-1' } }] }),
});
j = await r.json();
assert(r.ok && j.accepted === 1, 'backend service-key ingest accepted');

// 3. Bad auth is rejected.
r = await fetch(`${BASE}/ingest`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"events":[]}' });
assert(r.status === 401, 'unauthenticated ingest rejected with 401');

// 4. Drawing upload (multipart, Bearer).
const fd = new FormData();
fd.set('drawing_id', 'draw-1');
fd.set('prompt', 'a cozy cabin');
fd.set('style_id', 'pastel');
fd.set('updated_at', '2026-06-06T12:04:00Z');
fd.set('thumbnail', new Blob([new Uint8Array([255, 216, 255, 0])], { type: 'image/jpeg' }), 'thumb.jpg');
fd.set('generated', new Blob([new Uint8Array([255, 216, 255, 1])], { type: 'image/jpeg' }), 'gen.jpg');
r = await fetch(`${BASE}/ingest/drawing`, { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: fd });
j = await r.json();
assert(r.ok && j.ok, `drawing upload ok (got ${JSON.stringify(j)})`);

// 5. Admin login → cookie.
r = await fetch(`${BASE}/admin/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: PASS }) });
assert(r.ok, 'admin login ok');
const cookie = r.headers.get('set-cookie').split(';')[0];

r = await fetch(`${BASE}/admin/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: 'wrong' }) });
assert(r.status === 401, 'wrong admin password rejected');

// 6. Admin API requires the cookie.
r = await fetch(`${BASE}/admin/api/users`);
assert(r.status === 401, 'admin api rejects no-cookie');

// 7. Users list — joins backend users (identity/flags/spend) onto our rollups.
r = await fetch(`${BASE}/admin/api/users`, { headers: { cookie } });
j = await r.json();
const u = j.users.find((x) => x.user_id === USER);
assert(u && u.email === 'tester@example.com', 'user appears from backend users table with email');
assert(u.is_test_account === true && u.subscription_status === 'none', 'backend identity fields surfaced (test flag)');
assert(u.event_count === 4 && u.session_count === 1 && u.drawing_count === 1, `activity rollups correct (got ${JSON.stringify(u)})`);
assert(Math.abs(u.fal_spend_usd_month - 3.5) < 1e-6, `this-month fal spend joined (got ${u.fal_spend_usd_month})`);

// 8. User detail.
r = await fetch(`${BASE}/admin/api/users/${USER}`, { headers: { cookie } });
j = await r.json();
assert(j.user.is_test_account === true, 'detail profile from backend users table');
assert(j.usage.length >= 1 && Math.abs(j.usage[0].fal_spend_usd - 3.5) < 1e-6, 'monthly_usage history present');
assert(j.sessions.length === 1 && j.sessions[0].duration_ms === 300000, 'session rolled up with 300s duration');
assert(j.drawings.length === 1 && j.drawings[0].prompt === 'a cozy cabin', 'drawing present with prompt');
assert(j.drawings[0].thumbnail_url === '/blobs/drawings/draw-1/thumb.jpg', `thumbnail url wired (got ${j.drawings[0].thumbnail_url})`);

// 9. Blob serving (cookie-gated).
r = await fetch(`${BASE}${j.drawings[0].thumbnail_url}`, { headers: { cookie } });
assert(r.ok && r.headers.get('content-type') === 'image/jpeg', 'blob served as image/jpeg');
r = await fetch(`${BASE}${j.drawings[0].thumbnail_url}`);
assert(r.status === 401, 'blob rejects no-cookie');

console.log('\nALL SMOKE TESTS PASSED');
