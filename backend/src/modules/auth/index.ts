import * as Sentry from '@sentry/node';
import type { FastifyPluginAsync } from 'fastify';

import { verifyAccess, type AccessClaims } from './jwt.js';

/**
 * Auth plugin — verifies Bearer tokens on HTTP routes. WebSocket handshake
 * is authed explicitly inside the /v1/stream handler because @fastify/websocket
 * + preHandler hooks interact awkwardly.
 */

const PUBLIC_PATHS = new Set<string>([
  '/health',
  '/v1/auth/apple',
  '/v1/auth/refresh',
]);

function isPublic(url: string): boolean {
  // Strip query string before matching
  const path = url.split('?')[0] ?? url;
  return PUBLIC_PATHS.has(path);
}

export function extractBearer(authHeader: string | undefined): string | null {
  if (!authHeader) return null;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? null;
}

export const authPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.decorateRequest('userId', '');
  fastify.decorateRequest('authClaims', null);

  fastify.addHook('preHandler', async (request, reply) => {
    if (isPublic(request.url)) return;

    // WebSocket upgrades also go through this hook. The /v1/stream route
    // handles its own auth because we need to send an error message over
    // the socket before closing, not just return a 401. Skip here.
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
      // Per-request scope (from `fastifyIntegration` in index.ts) keeps this
      // from leaking across requests. All errors/spans/logs emitted while
      // handling this request inherit user.id automatically.
      Sentry.setUser({ id: claims.sub });
    } catch {
      await reply.code(401).send({ error: 'invalid_token' });
      return;
    }
  });
};

// Extend Fastify type definitions
declare module 'fastify' {
  interface FastifyRequest {
    userId: string;
    authClaims: AccessClaims | null;
  }
}
