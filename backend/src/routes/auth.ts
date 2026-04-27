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

import { extractBearer } from '../modules/auth/index.js';
import { verifyAppleIdentityToken } from '../modules/auth/appleVerifier.js';
import {
  signAccess,
  signRefresh,
  verifyRefresh,
  revokeRefresh,
  ACCESS_TTL_SECONDS,
  verifyAccess,
} from '../modules/auth/jwt.js';
import { abortSession } from '../modules/orchestrator/orchestrator.js';
import { getRedis } from '../modules/redis/client.js';

interface AppleLoginBody {
  identityToken: string;
  nonce?: string;
}

interface RefreshBody {
  refreshToken: string;
}

// User store backed by Redis so identity survives backend redeploys. Two keys:
//   apple-sub:{appleSub} → userId        (looked up at sign-in to reuse)
//   user:{userId}        → HSET fields    (email is the only field consumed
//                                          today, by /v1/auth/refresh)
// Pre-Round-6 this lived in two in-memory Maps that reset every redeploy,
// causing the same Apple ID to mint a fresh userId after each deploy and
// orphaning whatever pods/sessions belonged to the old userId.
interface UserRecord {
  userId: string;
  appleSub: string;
  email?: string;
  createdAt: number;
}

async function upsertUser(appleSub: string, email?: string): Promise<UserRecord> {
  const redis = getRedis();
  const subKey = `apple-sub:${appleSub}`;
  const existingId = await redis.get(subKey);
  if (existingId) {
    const stored = await redis.hgetall(`user:${existingId}`);
    return {
      userId: existingId,
      appleSub,
      email: stored['email'] || email,
      createdAt: Number(stored['createdAt'] ?? 0),
    };
  }
  const userId = randomUUID();
  const createdAt = Date.now();
  const fields: Record<string, string> = {
    appleSub,
    createdAt: String(createdAt),
  };
  if (email) fields['email'] = email;
  await redis.multi()
    .set(subKey, userId)
    .hset(`user:${userId}`, fields)
    .exec();
  return { userId, appleSub, email, createdAt };
}

async function getUserEmail(userId: string): Promise<string | undefined> {
  const stored = await getRedis().hget(`user:${userId}`, 'email');
  return stored ?? undefined;
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
        const user = await upsertUser(appleSub, email);
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
          email: user.email,
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

  // POST /v1/auth/signout — clean up the caller's session: terminate their
  // pod and delete the Redis session row. The JWT and refresh tokens stay
  // valid (no server-side revocation today) so the caller can sign back in
  // freely. Idempotent: safe to call when there's no active session.
  fastify.post('/v1/auth/signout', async (request, reply) => {
    const token = extractBearer(request.headers.authorization);
    if (!token) {
      return reply.code(401).send({ error: 'authentication_required' });
    }
    let userId: string;
    try {
      const claims = await verifyAccess(token);
      userId = claims.sub;
    } catch {
      return reply.code(401).send({ error: 'invalid_token' });
    }
    await abortSession(userId, 'manual');
    request.log.info({ userId }, 'Signout: session aborted');
    return reply.send({ ok: true });
  });

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
        const email = await getUserEmail(claims.sub);
        return reply.send({
          accessToken,
          refreshToken,
          expiresIn: ACCESS_TTL_SECONDS,
          userId: claims.sub,
          email,
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
