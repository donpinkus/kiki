/**
 * JWT signing + verification for Kiki's user access tokens.
 *
 * HS256 (symmetric) with two separate secrets for access vs refresh tokens —
 * rotating one doesn't invalidate the other. Access tokens are short-lived
 * (1h); refresh tokens are long-lived (30d) and rotate on use. Revocation is
 * by `jti` via an in-memory set for v1 (graduates to Redis in Workstream 5).
 */

import { randomUUID } from 'node:crypto';
import { jwtVerify, SignJWT } from 'jose';

import { config } from '../../config/index.js';

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

// In-memory revocation set for refresh-token rotation. Graduates to Redis
// with Workstream 5. Bounded growth by refresh-token expiry (30d); ~N_users
// entries in the steady state, which is negligible at 100 concurrent.
const revokedRefreshJtis = new Set<string>();

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
  if (payload.jti && revokedRefreshJtis.has(payload.jti)) {
    throw new Error('Refresh token has been revoked');
  }
  return payload as unknown as RefreshClaims;
}

export function revokeRefresh(jti: string): void {
  revokedRefreshJtis.add(jti);
}

export { ACCESS_TTL_SECONDS, REFRESH_TTL_SECONDS };
