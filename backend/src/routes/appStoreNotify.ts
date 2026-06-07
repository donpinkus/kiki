/**
 * App Store Server Notifications V2 webhook (Apple → backend).
 *
 * Public (in `authPlugin`'s PUBLIC_PATHS) because Apple calls it with no Bearer
 * token — the JWS signature on `signedPayload` IS the authentication. Apple
 * posts here for renewals, expirations, refunds, revokes, auto-renew changes,
 * etc. App Store Connect lets you set a Production and a Sandbox URL both
 * pointing here; the environment is in the payload and the verifier routes by it.
 *
 * Response policy: return 2xx on any successfully-verified notification, even
 * when it's a no-op (unknown subscription, other product, test ping). A non-2xx
 * makes Apple retry for hours, so we only 4xx when the signature itself fails.
 */

import type { FastifyPluginAsync } from 'fastify';

import { verifyNotification, verifyTransaction, KIKI_SUBSCRIPTION_PRODUCT_ID } from '../modules/appstore/verifier.js';
import { applyTransaction, findUserByOriginalTransactionId } from '../modules/appstore/subscriptions.js';

interface NotifyBody {
  signedPayload: string;
}

export const appStoreNotifyRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: NotifyBody }>(
    '/v1/app-store/notify',
    {
      schema: {
        body: {
          type: 'object',
          required: ['signedPayload'],
          properties: { signedPayload: { type: 'string', minLength: 1 } },
        },
      },
    },
    async (request, reply) => {
      let notif;
      try {
        notif = await verifyNotification(request.body.signedPayload);
      } catch (err) {
        // Signature failure is the one case we reject — could be spoofed.
        request.log.warn(
          { err, event: 'app_store_notify.invalid_signature' },
          'app_store_notify: signature verification failed',
        );
        return reply.code(401).send({ error: 'invalid_signature' });
      }

      const notificationType = notif.notificationType;
      const subtype = notif.subtype;
      const notificationUUID = notif.notificationUUID;
      const environment = notif.data?.environment;
      const signedTx = notif.data?.signedTransactionInfo;

      // TEST pings, EXTERNAL_PURCHASE_TOKEN, and summary notifications carry no
      // transaction to apply. Verified-and-acknowledged.
      if (!signedTx) {
        request.log.info(
          { event: 'app_store_notify.no_transaction', notificationType, subtype, notificationUUID, environment },
          'app_store_notify: no transaction info, acknowledged',
        );
        return reply.code(200).send({ ok: true });
      }

      let tx;
      try {
        tx = await verifyTransaction(signedTx);
      } catch (err) {
        request.log.warn(
          { err, notificationType, subtype, event: 'app_store_notify.invalid_transaction' },
          'app_store_notify: nested transaction verification failed',
        );
        return reply.code(401).send({ error: 'invalid_transaction' });
      }

      if (tx.productId !== KIKI_SUBSCRIPTION_PRODUCT_ID) {
        request.log.info(
          { event: 'app_store_notify.other_product', productId: tx.productId, notificationType, subtype },
          'app_store_notify: not our product, acknowledged',
        );
        return reply.code(200).send({ ok: true });
      }

      const otid = tx.originalTransactionId;
      const userId = otid ? await findUserByOriginalTransactionId(otid) : null;
      if (!userId) {
        // The notification can arrive before the client's first /verify bound
        // this OTID to a user. Acknowledge; the next /verify (or launch re-post)
        // establishes the binding and current state.
        request.log.info(
          { event: 'app_store_notify.unknown_otid', otid, notificationType, subtype, notificationUUID },
          'app_store_notify: no user for original_transaction_id, acknowledged',
        );
        return reply.code(200).send({ ok: true });
      }

      const state = await applyTransaction(userId, tx);
      request.log.info(
        {
          userId,
          event: 'app_store_notify.applied',
          notificationType,
          subtype,
          subscription_status: state.status,
          expiresAt: state.expiresAt,
          environment,
          notificationUUID,
        },
        'app_store_notify: applied',
      );
      return reply.code(200).send({ ok: true });
    },
  );
};
