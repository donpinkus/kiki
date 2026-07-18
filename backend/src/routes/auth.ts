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

import type { FastifyPluginAsync } from 'fastify';

import { verifyAppleIdentityToken } from '../modules/auth/appleVerifier.js';
import {
  signAccess,
  signRefresh,
  verifyRefresh,
  revokeRefresh,
  ACCESS_TTL_SECONDS,
} from '../modules/auth/jwt.js';
import { upsertUserByAppleSub, getUserEmail } from '../postgres/users.js';

interface AppleLoginBody {
  identityToken: string;
  nonce?: string;
  /** First-authorization-only credential.email fallback (client-asserted). */
  email?: string;
}

interface RefreshBody {
  refreshToken: string;
}

// User identity is the durable Postgres `users` table (see postgres/users.ts).
// `upsertUserByAppleSub` find-or-creates by Apple `sub` (UNIQUE), so the same
// Apple ID keeps its `userId` across deploys without re-minting. This replaced
// the former Redis `user:{userId}` / `apple-sub:{sub}` hash.
export const authRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: AppleLoginBody }>(
    '/v1/auth/apple',
    {
      config: { public: true },
      schema: {
        body: {
          type: 'object',
          required: ['identityToken'],
          properties: {
            identityToken: { type: 'string', minLength: 1 },
            nonce: { type: 'string' },
            // ASAuthorizationAppleIDCredential.email — iOS populates it only
            // on the FIRST authorization (one-shot). Client-asserted, NOT
            // Apple-signed: used strictly as a fallback when the verified
            // token lacks the email claim, and only ever for contact info
            // (identity is keyed on apple_sub alone).
            email: { type: 'string', maxLength: 320 },
          },
        },
      },
    },
    async (request, reply) => {
      try {
        const { appleSub, email } = await verifyAppleIdentityToken(request.body.identityToken);
        const fallbackEmail =
          !email && typeof request.body.email === 'string' && request.body.email.includes('@')
            ? request.body.email
            : undefined;
        const user = await upsertUserByAppleSub(appleSub, email ?? fallbackEmail);
        const accessToken = await signAccess(user.userId);
        const refreshToken = await signRefresh(user.userId);

        request.log.info(
          {
            userId: user.userId,
            appleSub: appleSub.slice(0, 8) + '...',
            newUser: user.isNew,
            emailSource: email ? 'token' : fallbackEmail ? 'credential_fallback' : 'none',
          },
          'Apple sign-in success',
        );
        if (user.isNew && !user.email) {
          // The first authorization is the ONLY time Apple sends the email —
          // a new user landing without one is permanently unreachable unless
          // they revoke+reauthorize or we set it manually (Insights).
          request.log.warn(
            { userId: user.userId, event: 'auth.signup_no_email' },
            'new user signed up with no email captured (one-shot missed)',
          );
        }

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

  // POST /v1/auth/signout — sign-out marker. There is no server-side session
  // state to tear down anymore (image relays live and die with the WS
  // connection); the JWT and refresh tokens stay valid (no server-side
  // revocation today) so the caller can sign back in freely. Kept because
  // shipped iOS clients call it on sign-out.
  fastify.post('/v1/auth/signout', async (request, reply) => {
    // Authed by the global gate (not public) — `request.userId` is set.
    const userId = request.userId;
    if (!userId) {
      return reply.code(401).send({ error: 'authentication_required' });
    }
    request.log.info({ userId }, 'Signout');
    return reply.send({ ok: true });
  });

  fastify.post<{ Body: RefreshBody }>(
    '/v1/auth/refresh',
    {
      config: { public: true },
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
        // Rotate: revoke old (durable, in Postgres), issue new pair
        await revokeRefresh(claims);
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
