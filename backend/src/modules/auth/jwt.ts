/**
 * JWT signing + verification for Kiki's user access tokens.
 *
 * HS256 (symmetric) with two separate secrets for access vs refresh tokens —
 * rotating one doesn't invalidate the other. Access tokens are short-lived
 * (1h); refresh tokens are long-lived (30d) and rotate on use. Revocation is
 * by `jti`, persisted in Postgres (`revoked_refresh_tokens`) so it survives
 * deploys — only `verifyRefresh` (the ~hourly refresh endpoint) touches the DB;
 * the hot `verifyAccess` path stays pure-crypto.
 */

import { randomUUID } from 'node:crypto';
import { jwtVerify, SignJWT } from 'jose';

import { config } from '../../config/index.js';
import { query } from '../../postgres/client.js';

const ACCESS_TTL_SECONDS = 60 * 60;          // 1 hour
const REFRESH_TTL_SECONDS = 30 * 24 * 60 * 60; // 30 days
const CLOCK_TOLERANCE_SECONDS = 30;

export interface AccessClaims {
  sub: string;
  typ: 'access';
  iat: number;
  exp: number;
  jti: string;
}

export interface RefreshClaims {
  sub: string;
  typ: 'refresh';
  iat: number;
  exp: number;
  jti: string;
}

const accessSecret = new TextEncoder().encode(config.JWT_ACCESS_SECRET);
const refreshSecret = new TextEncoder().encode(config.JWT_REFRESH_SECRET);

export async function signAccess(userId: string): Promise<string> {
  return new SignJWT({ typ: 'access' })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TTL_SECONDS}s`)
    .setJti(randomUUID())
    .sign(accessSecret);
}

export async function signRefresh(userId: string): Promise<string> {
  return new SignJWT({ typ: 'refresh' })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${REFRESH_TTL_SECONDS}s`)
    .setJti(randomUUID())
    .sign(refreshSecret);
}

export async function verifyAccess(token: string): Promise<AccessClaims> {
  const { payload } = await jwtVerify(token, accessSecret, {
    algorithms: ['HS256'],
    clockTolerance: CLOCK_TOLERANCE_SECONDS,
  });
  if (payload.typ !== 'access') {
    throw new Error(`Expected access token, got typ=${String(payload.typ)}`);
  }
  return payload as unknown as AccessClaims;
}

export async function verifyRefresh(token: string): Promise<RefreshClaims> {
  const { payload } = await jwtVerify(token, refreshSecret, {
    algorithms: ['HS256'],
    clockTolerance: CLOCK_TOLERANCE_SECONDS,
  });
  if (payload.typ !== 'refresh') {
    throw new Error(`Expected refresh token, got typ=${String(payload.typ)}`);
  }
  if (typeof payload.jti === 'string') {
    const r = await query('SELECT 1 FROM revoked_refresh_tokens WHERE jti = $1', [payload.jti]);
    if ((r.rowCount ?? 0) > 0) {
      throw new Error('Refresh token has been revoked');
    }
  }
  return payload as unknown as RefreshClaims;
}

/** Revoke a refresh token by jti (durable). Pass the verified claims so we can
 * store the user and expiry. Idempotent. */
export async function revokeRefresh(claims: RefreshClaims): Promise<void> {
  await query(
    `INSERT INTO revoked_refresh_tokens (jti, user_id, expires_at)
     VALUES ($1, $2, to_timestamp($3))
     ON CONFLICT (jti) DO NOTHING`,
    [claims.jti, claims.sub, claims.exp],
  );
  // Opportunistic, non-blocking prune of long-expired rows (they're rejected by
  // jose anyway, so dropping them can't un-revoke anything usable).
  void query('DELETE FROM revoked_refresh_tokens WHERE expires_at < now()', []).catch(() => {});
}

export { ACCESS_TTL_SECONDS, REFRESH_TTL_SECONDS };
