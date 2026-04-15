/**
 * Auth routes — sign in with Apple + JWT refresh.
 *
 * Flow:
 *   1. Client does SignInWithAppleButton, gets `identityToken` from Apple.
 *   2. POST /v1/auth/apple { identityToken } — we verify against Apple's
 *      JWKS, upsert the user by `appleSub`, return access + refresh JWTs.
 *   3. Client stores the tokens in Keychain. On WS stream open, sends
 *      `Authorization: Bearer <accessToken>`.
 *   4. Before access expiry (1h), client POST /v1/auth/refresh { refreshToken }
 *      → new pair, old refresh token revoked.
 */

import { randomUUID } from 'node:crypto';
import type { FastifyPluginAsync } from 'fastify';

import { verifyAppleIdentityToken } from '../modules/auth/appleVerifier.js';
import {
  signAccess,
  signRefresh,
  verifyRefresh,
  revokeRefresh,
  ACCESS_TTL_SECONDS,
} from '../modules/auth/jwt.js';

interface AppleLoginBody {
  identityToken: string;
  nonce?: string;
}

interface RefreshBody {
  refreshToken: string;
}

// In-memory user store for v1. Maps Apple `sub` → internal userId.
// Moves to Redis in Workstream 5 / persistence tier in Workstream 8.
const appleSubToUserId = new Map<string, string>();

interface UserRecord {
  userId: string;
  appleSub: string;
  email?: string;
  createdAt: number;
  ageGateAcceptedAt?: number;
  aiConsentAcceptedAt?: number;
}
const users = new Map<string, UserRecord>();

function upsertUser(appleSub: string, email?: string): UserRecord {
  const existingId = appleSubToUserId.get(appleSub);
  if (existingId) {
    const existing = users.get(existingId);
    if (existing) return existing;
  }
  const userId = randomUUID();
  const user: UserRecord = {
    userId,
    appleSub,
    email,
    createdAt: Date.now(),
  };
  users.set(userId, user);
  appleSubToUserId.set(appleSub, userId);
  return user;
}

export const authRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: AppleLoginBody }>(
    '/v1/auth/apple',
    {
      schema: {
        body: {
          type: 'object',
          required: ['identityToken'],
          properties: {
            identityToken: { type: 'string', minLength: 1 },
            nonce: { type: 'string' },
          },
        },
      },
    },
    async (request, reply) => {
      try {
        const { appleSub, email } = await verifyAppleIdentityToken(request.body.identityToken);
        const user = upsertUser(appleSub, email);
        const accessToken = await signAccess(user.userId);
        const refreshToken = await signRefresh(user.userId);

        request.log.info(
          { userId: user.userId, appleSub: appleSub.slice(0, 8) + '...', newUser: !email || user.createdAt > Date.now() - 5000 },
          'Apple sign-in success',
        );

        return reply.send({
          accessToken,
          refreshToken,
          expiresIn: ACCESS_TTL_SECONDS,
          userId: user.userId,
        });
      } catch (err) {
        request.log.warn({ err }, 'Apple sign-in failed');
        return reply.code(401).send({
          error: 'invalid_identity_token',
          message: err instanceof Error ? err.message : 'Verification failed',
        });
      }
    },
  );

  fastify.post<{ Body: RefreshBody }>(
    '/v1/auth/refresh',
    {
      schema: {
        body: {
          type: 'object',
          required: ['refreshToken'],
          properties: { refreshToken: { type: 'string', minLength: 1 } },
        },
      },
    },
    async (request, reply) => {
      try {
        const claims = await verifyRefresh(request.body.refreshToken);
        // Rotate: revoke old, issue new pair
        revokeRefresh(claims.jti);
        const accessToken = await signAccess(claims.sub);
        const refreshToken = await signRefresh(claims.sub);
        return reply.send({
          accessToken,
          refreshToken,
          expiresIn: ACCESS_TTL_SECONDS,
        });
      } catch (err) {
        request.log.warn({ err }, 'Refresh failed');
        return reply.code(401).send({
          error: 'invalid_refresh_token',
          message: err instanceof Error ? err.message : 'Refresh failed',
        });
      }
    },
  );
};

// Exported for stream.ts so it can look up the user record (if needed).
export function getUserById(userId: string): UserRecord | undefined {
  return users.get(userId);
}
