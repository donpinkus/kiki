/**
 * Shared WebSocket-handshake identity resolution for the /v1/stream and
 * /v1/animate routes. WS routes opt out of the global JWT gate
 * (`config.public`) so they can send an error frame before closing; this is
 * the auth they run instead.
 *
 * Identity resolution (in order):
 *   1. `Authorization: Bearer <jwt>` — preferred. Extracts userId from the
 *      access token.
 *   2. `?session=<uuid>` legacy query param — accepted only when
 *      `AUTH_REQUIRED=false` (dev). Skips entitlement checks.
 */

import { config } from '../../config/index.js';
import { extractBearer } from './index.js';
import { verifyAccess } from './jwt.js';

export interface WsIdentity {
  userId: string;
  source: 'jwt' | 'legacy_session';
}

export function extractQueryParam(rawUrl: string | undefined, name: string): string | null {
  if (!rawUrl) return null;
  try {
    const url = new URL(rawUrl, 'http://placeholder');
    return url.searchParams.get(name);
  } catch {
    return null;
  }
}

export async function resolveWsIdentity(
  request: { url?: string; headers: { authorization?: string } },
): Promise<WsIdentity | { error: string; code: number }> {
  const token = extractBearer(request.headers.authorization);
  if (token) {
    try {
      const claims = await verifyAccess(token);
      return { userId: claims.sub, source: 'jwt' };
    } catch {
      return { error: 'invalid_token', code: 1008 };
    }
  }

  if (!config.AUTH_REQUIRED) {
    const sessionId = extractQueryParam(request.url, 'session');
    if (sessionId) {
      return { userId: sessionId, source: 'legacy_session' };
    }
  }

  return {
    error: config.AUTH_REQUIRED ? 'authentication_required' : 'missing_identity',
    code: 1008,
  };
}
