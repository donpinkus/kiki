/**
 * fal.ai short-lived token route — SPIKE / ISOLATED.
 *
 * Mints a short-lived fal JWT from the server-side `FAL_KEY` so a client (the
 * bench harness now, the iPad later) can open a realtime WebSocket to our
 * private fal app WITHOUT ever holding the long-lived `FAL_KEY`. This proves the
 * "No secrets on client" constraint (CLAUDE.md #3) holds on the fal path.
 *
 * ISOLATION (read before touching):
 *   - This module is the ONLY backend coupling to fal during the spike.
 *   - It is NOT imported by the orchestrator, relay, or anything in the RunPod
 *     path. Register it manually for the spike (see registration note below) and
 *     unregister to fully detach fal. Deleting fal later = delete this folder +
 *     remove the one registration line.
 *   - Do NOT add a provider abstraction or fold this into auth/orchestrator.
 *
 * To enable for the spike, in the server bootstrap add:
 *     import { falSpikeTokenRoute } from './modules/fal_spike/token-route.js';
 *     await fastify.register(falSpikeTokenRoute);
 * and set FAL_KEY in the Railway/.env environment.
 *
 * VERIFY BEFORE TRUSTING: the fal token endpoint URL + request shape below are
 * from fal's docs (https://fal.ai/docs/model-apis/real-time/secrets) and have
 * NOT been run against the live API yet. Confirm the endpoint, payload keys
 * (`allowed_apps`, `token_expiration`), and response shape during the spike;
 * they're env-overridable so you can correct without a code change.
 */
import type { FastifyPluginAsync } from 'fastify';

const FAL_TOKEN_ENDPOINT =
  process.env['FAL_TOKEN_ENDPOINT'] ?? 'https://rest.alpha.fal.ai/tokens/';

// App id(s) the minted token is allowed to call, e.g. "<your-username>/kiki-image-spike".
const FAL_ALLOWED_APPS = (process.env['FAL_ALLOWED_APPS'] ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

// Token lifetime in seconds. fal docs example uses ~120s; keep it short.
const FAL_TOKEN_TTL_SECONDS = Number(process.env['FAL_TOKEN_TTL_SECONDS'] ?? 120);

export const falSpikeTokenRoute: FastifyPluginAsync = async (fastify) => {
  const falKey = process.env['FAL_KEY'];
  if (!falKey) {
    fastify.log.warn(
      { event: 'fal_spike.token_route.disabled' },
      'fal_spike token route registered but FAL_KEY is unset — endpoint will 503',
    );
  }

  fastify.post('/fal-spike/token', async (request, reply) => {
    // SPIKE NOTE: in production this MUST sit behind the same auth preHandler as
    // the rest of the app so only signed-in users can mint tokens (fal's docs
    // stress the token endpoint must verify the caller is authenticated). The
    // spike leaves it open for the bench harness; do not ship it this way.
    if (!falKey) {
      return reply.code(503).send({ error: 'FAL_KEY not configured' });
    }

    try {
      const res = await fetch(FAL_TOKEN_ENDPOINT, {
        method: 'POST',
        headers: {
          Authorization: `Key ${falKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          allowed_apps: FAL_ALLOWED_APPS,
          token_expiration: FAL_TOKEN_TTL_SECONDS,
        }),
      });

      if (!res.ok) {
        const bodySample = (await res.text()).slice(0, 500);
        request.log.error(
          {
            event: 'fal_spike.token_mint_failed',
            httpStatus: res.status,
            bodySample,
          },
          'fal token mint failed',
        );
        return reply.code(502).send({ error: 'fal token mint failed', status: res.status });
      }

      // fal returns the token as a bare JSON string (quoted) per docs; parse
      // defensively in case it's wrapped in an object.
      const raw = await res.text();
      let token: string;
      try {
        const parsed = JSON.parse(raw);
        token = typeof parsed === 'string' ? parsed : (parsed.token ?? parsed.jwt ?? raw);
      } catch {
        token = raw;
      }

      return reply.send({
        token,
        expiresInSeconds: FAL_TOKEN_TTL_SECONDS,
        allowedApps: FAL_ALLOWED_APPS,
      });
    } catch (err) {
      request.log.error(
        { event: 'fal_spike.token_route_error', err: String(err) },
        'fal token route error',
      );
      return reply.code(500).send({ error: 'internal error minting fal token' });
    }
  });
};
