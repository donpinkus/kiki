/**
 * Subscription verification route (StoreKit 2, client → backend).
 *
 * The iOS client posts a verified `Transaction.jwsRepresentation` here:
 *   - right after a successful purchase, and
 *   - on each launch for every entry in `Transaction.currentEntitlements`
 *     (keeps the backend in sync without relying solely on the webhook), and
 *   - for Restore Purchases (same shape).
 *
 * JWT-authed: the global `authPlugin` preHandler verifies the Bearer token and
 * sets `request.userId` before this handler runs (this path is not in
 * PUBLIC_PATHS). That authenticated `userId` is the only moment we have both the
 * Kiki user and the Apple subscription, so this is where we bind
 * `original_transaction_id ↔ user_id` for the (unauthenticated) webhook to use.
 */

import type { FastifyPluginAsync } from 'fastify';

import { config } from '../config/index.js';
import { extractBearer } from '../modules/auth/index.js';
import { verifyAccess } from '../modules/auth/jwt.js';
import { verifyTransaction, KIKI_SUBSCRIPTION_PRODUCT_ID } from '../modules/appstore/verifier.js';
import { applyTransaction, findUserByOriginalTransactionId } from '../modules/appstore/subscriptions.js';

interface VerifyBody {
  jws: string;
}

export const subscriptionRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: VerifyBody }>(
    '/v1/subscription/verify',
    {
      schema: {
        body: {
          type: 'object',
          required: ['jws'],
          properties: { jws: { type: 'string', minLength: 1 } },
        },
      },
    },
    async (request, reply) => {
      // Self-authenticate: the global authPlugin preHandler is encapsulated and
      // does NOT run for sibling routes, so `request.userId` is never set here.
      // Verify the Bearer token directly (same pattern as /v1/auth/signout).
      const token = extractBearer(request.headers.authorization);
      if (!token) {
        return reply.code(401).send({ error: 'authentication_required' });
      }
      let userId: string;
      try {
        userId = (await verifyAccess(token)).sub;
      } catch {
        return reply.code(401).send({ error: 'invalid_token' });
      }

      let tx;
      try {
        tx = await verifyTransaction(request.body.jws);
      } catch (err) {
        request.log.warn(
          { err, userId, event: 'subscription.verify_failed' },
          'subscription.verify: JWS verification failed',
        );
        return reply.code(400).send({
          error: 'invalid_transaction',
          message: err instanceof Error ? err.message : 'verification failed',
        });
      }

      if (tx.bundleId !== config.APPLE_BUNDLE_ID || tx.productId !== KIKI_SUBSCRIPTION_PRODUCT_ID) {
        request.log.warn(
          { userId, productId: tx.productId, bundleId: tx.bundleId, event: 'subscription.unexpected_product' },
          'subscription.verify: unexpected product/bundle',
        );
        return reply.code(400).send({ error: 'unexpected_product' });
      }

      // One Apple subscription ↔ one Kiki account. If this OTID is already bound
      // to a different user (e.g. a second Apple ID restoring the same purchase),
      // refuse rather than silently re-home the subscription.
      const otid = tx.originalTransactionId;
      if (otid) {
        const owner = await findUserByOriginalTransactionId(otid);
        if (owner && owner !== userId) {
          request.log.warn(
            { userId, otherUserId: owner, otid, event: 'subscription.otid_conflict' },
            'subscription.verify: original_transaction_id already bound to another user',
          );
          return reply.code(409).send({ error: 'subscription_bound_to_other_account' });
        }
      }

      const state = await applyTransaction(userId, tx);
      request.log.info(
        {
          userId,
          event: 'subscription.verified',
          subscription_status: state.status,
          expiresAt: state.expiresAt,
          environment: tx.environment,
        },
        'subscription.verify: applied',
      );
      return reply.send({ subscriptionStatus: state.status, expiresAt: state.expiresAt });
    },
  );
};
