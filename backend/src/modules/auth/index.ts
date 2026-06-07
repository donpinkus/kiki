import * as Sentry from '@sentry/node';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';

import { verifyAccess, type AccessClaims } from './jwt.js';

/**
 * Auth gate — verifies the Bearer access token on every HTTP route by default
 * (fail-closed). A route opts OUT by declaring `config: { public: true }` at its
 * own definition. That covers two cases: truly-public routes (health, Apple
 * sign-in/refresh) and routes that authenticate differently (the App Store
 * webhook via its JWS signature, the ops routes via `X-Ops-Key`, the /v1/stream
 * WebSocket via its own handshake).
 *
 * Declaring the exemption next to each route (rather than in a central path
 * list) keeps it from drifting: adding/removing a public route is a one-line
 * local change, and a route that forgets to opt out simply requires auth.
 *
 * `installAuth` runs the hook + decorators on the ROOT app instance (not via
 * `app.register`, which would encapsulate them to a child context that owns no
 * routes — the bug this replaces).
 */

export function extractBearer(authHeader: string | undefined): string | null {
  if (!authHeader) return null;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? null;
}

async function authHook(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  // Per-route opt-out, declared next to the handler.
  if ((request.routeOptions.config as { public?: boolean } | undefined)?.public) return;
  // The WebSocket upgrade authenticates inside the /v1/stream handler (it needs
  // to send an error frame over the socket before closing, not a plain HTTP
  // 401). Extra guard beyond `config` because @fastify/websocket + preHandler
  // interact awkwardly.
  if (request.url.startsWith('/v1/stream')) return;

  const token = extractBearer(request.headers.authorization);
  if (!token) {
    await reply.code(401).send({ error: 'missing_token' });
    return;
  }
  try {
    const claims = await verifyAccess(token);
    request.userId = claims.sub;
    request.authClaims = claims;
    // Per-request scope (from `fastifyIntegration` in index.ts) keeps this from
    // leaking across requests; logs/errors in this request inherit user.id.
    Sentry.setUser({ id: claims.sub });
  } catch {
    await reply.code(401).send({ error: 'invalid_token' });
  }
}

/**
 * Install the global auth gate. Call once on the root app, AFTER core plugins
 * (cors/websocket) and BEFORE any route registration — Fastify only applies a
 * preHandler to routes registered after the hook, and decorators must precede
 * route handlers that read them.
 */
export function installAuth(app: FastifyInstance): void {
  app.decorateRequest('userId', '');
  app.decorateRequest('authClaims', null);
  app.addHook('preHandler', authHook);
}

// Extend Fastify type definitions
declare module 'fastify' {
  interface FastifyRequest {
    userId: string;
    authClaims: AccessClaims | null;
  }
}
