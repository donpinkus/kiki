/**
 * Auth for the two faces of Kiki Insights:
 *
 *  1. Ingest (public, but authenticated) — iOS presents its existing Bearer
 *     access token (verified here with the SHARED JWT_ACCESS_SECRET, verify-only,
 *     we never sign user tokens). The prod backend presents the service key on
 *     `x-insights-key` for its server-side events. No new secret on the client.
 *
 *  2. Dashboard (internal) — single admin password → a signed session cookie
 *     (HS256 over ADMIN_SESSION_SECRET). `requireAdmin` gates the admin API and
 *     blob serving.
 */

import { timingSafeEqual } from 'node:crypto';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { jwtVerify, SignJWT } from 'jose';
import { config } from './config.js';

const accessSecret = new TextEncoder().encode(config.JWT_ACCESS_SECRET);
const adminSecret = new TextEncoder().encode(config.ADMIN_SESSION_SECRET);

export const ADMIN_COOKIE = 'kiki_insights_admin';
const ADMIN_SESSION_TTL = '30d';
const CLOCK_TOLERANCE = 30;

// ─── Ingest auth ─────────────────────────────────────────────────────────────

export interface IngestPrincipal {
  /** When source==='ios', the authenticated user_id from the JWT `sub`.
   * When source==='backend', undefined — the per-event user_id is trusted from
   * the request body (the backend is itself authenticated by the service key). */
  readonly userId?: string;
  readonly source: 'ios' | 'backend';
}

function constantTimeEquals(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

/**
 * Resolve who is calling /ingest. Throws (caller maps to 401) if neither a valid
 * service key nor a valid Bearer access token is present.
 */
export async function authenticateIngest(request: FastifyRequest): Promise<IngestPrincipal> {
  const serviceKey = request.headers['x-insights-key'];
  if (typeof serviceKey === 'string' && serviceKey.length > 0) {
    if (!constantTimeEquals(serviceKey, config.INSIGHTS_INGEST_KEY)) {
      throw new Error('Invalid service key');
    }
    return { source: 'backend' };
  }

  const auth = request.headers.authorization;
  const token = auth?.startsWith('Bearer ') ? auth.slice(7) : undefined;
  if (!token) throw new Error('Missing credentials');

  const { payload } = await jwtVerify(token, accessSecret, {
    algorithms: ['HS256'],
    clockTolerance: CLOCK_TOLERANCE,
  });
  if (payload.typ !== 'access') throw new Error('Not an access token');
  if (typeof payload.sub !== 'string') throw new Error('Token missing sub');
  return { source: 'ios', userId: payload.sub };
}

// ─── Admin session ───────────────────────────────────────────────────────────

export function verifyAdminPassword(candidate: string): boolean {
  return constantTimeEquals(candidate, config.ADMIN_PASSWORD);
}

export async function signAdminSession(): Promise<string> {
  return new SignJWT({ role: 'admin' })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime(ADMIN_SESSION_TTL)
    .sign(adminSecret);
}

async function isValidAdminSession(token: string | undefined): Promise<boolean> {
  if (!token) return false;
  try {
    const { payload } = await jwtVerify(token, adminSecret, {
      algorithms: ['HS256'],
      clockTolerance: CLOCK_TOLERANCE,
    });
    return payload.role === 'admin';
  } catch {
    return false;
  }
}

/** Fastify preHandler — 401s unless a valid admin cookie is present. */
export async function requireAdmin(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  const token = request.cookies[ADMIN_COOKIE];
  if (!(await isValidAdminSession(token))) {
    await reply.code(401).send({ error: 'unauthorized' });
  }
}
