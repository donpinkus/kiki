/**
 * Post-deploy smoke test: mint an access JWT for Donald's (test) account with
 * the prod JWT_ACCESS_SECRET and exercise the Lambda dev-pool endpoints
 * exactly as the iPad will. Run from backend/ with:
 *   JWT_ACCESS_SECRET=... USER_ID=... BACKEND=https://... npx tsx <this file> [--poll]
 */
import { SignJWT } from 'jose';

const secret = new TextEncoder().encode(process.env['JWT_ACCESS_SECRET']!);
const userId = process.env['USER_ID']!;
const backend = process.env['BACKEND'] ?? 'https://kiki-backend-production.up.railway.app';
const poll = process.argv.includes('--poll');

const token = await new SignJWT({ typ: 'access' })
  .setProtectedHeader({ alg: 'HS256' })
  .setSubject(userId)
  .setIssuedAt()
  .setExpirationTime('600s')
  .setJti(crypto.randomUUID())
  .sign(secret);

const headers = { Authorization: `Bearer ${token}` };

const ensureRes = await fetch(`${backend}/v1/dev/lambda/ensure`, { method: 'POST', headers });
console.log('ensure:', ensureRes.status, JSON.stringify(await ensureRes.json()));

if (poll) {
  for (let i = 0; i < 100; i++) {
    await new Promise((r) => setTimeout(r, 15_000));
    const res = await fetch(`${backend}/v1/dev/lambda/status`, { headers });
    const body = (await res.json()) as { status?: string; message?: string };
    console.log(`status[${i}]:`, res.status, JSON.stringify(body));
    if (body.status === 'ready' || body.status === 'error' || body.status === 'disabled') break;
  }
}