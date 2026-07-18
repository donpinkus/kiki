/**
 * Mint a backend JWT access+refresh pair for the iOS Simulator dev bypass.
 *
 * Sign in with Apple can't complete in the simulator, so sim builds accept
 * pre-minted tokens via launch arguments (see ios/Kiki/App/DevAuthBypass.swift).
 * This script signs real tokens with the production secrets — run it with the
 * Railway env injected:
 *
 *   cd backend && railway run npx tsx scripts/mint-dev-token.ts --user <user_id>
 *
 * Without --user it looks up the first `is_test_account` user via
 * DATABASE_PUBLIC_URL / DATABASE_URL if reachable.
 *
 * The access token gets a long TTL (default 30d) so the sim session never
 * needs the refresh flow; a matching refresh token is minted anyway so the
 * normal rotation path also works if it fires.
 */

import { randomUUID } from 'node:crypto';
import { SignJWT } from 'jose';

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const ttlDays = Number(arg('ttl') ?? '30');

async function resolveUserId(): Promise<string> {
  const explicit = arg('user');
  if (explicit) return explicit;
  const dbUrl = process.env.DATABASE_PUBLIC_URL ?? process.env.DATABASE_URL;
  if (!dbUrl) {
    throw new Error('Pass --user <user_id> (no DATABASE_URL available to auto-pick a test account)');
  }
  const { Client } = await import('pg');
  const client = new Client({ connectionString: dbUrl });
  await client.connect();
  try {
    const r = await client.query(
      `SELECT user_id, email FROM users WHERE is_test_account ORDER BY created_at LIMIT 1`,
    );
    if (r.rowCount === 0) throw new Error('No is_test_account user found — pass --user <user_id>');
    process.stderr.write(`Minting for test account ${r.rows[0].user_id} (${r.rows[0].email ?? 'no email'})\n`);
    return r.rows[0].user_id as string;
  } finally {
    await client.end();
  }
}

async function main() {
  const accessSecret = process.env.JWT_ACCESS_SECRET;
  const refreshSecret = process.env.JWT_REFRESH_SECRET;
  if (!accessSecret || !refreshSecret) {
    throw new Error('JWT_ACCESS_SECRET / JWT_REFRESH_SECRET not in env — run via `railway run`');
  }
  const userId = await resolveUserId();
  const ttlSeconds = Math.round(ttlDays * 24 * 60 * 60);

  const accessToken = await new SignJWT({ typ: 'access' })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${ttlSeconds}s`)
    .setJti(randomUUID())
    .sign(new TextEncoder().encode(accessSecret));

  const refreshToken = await new SignJWT({ typ: 'refresh' })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${ttlSeconds}s`)
    .setJti(randomUUID())
    .sign(new TextEncoder().encode(refreshSecret));

  process.stdout.write(JSON.stringify({ userId, ttlDays, accessToken, refreshToken }, null, 2) + '\n');
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
