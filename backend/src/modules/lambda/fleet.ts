/**
 * Fleet bundle delivery — how model-server code reaches Lambda instances.
 *
 * scripts/deploy.ts packs model-servers/ into fleet/ (content-hashed manifest
 * + tgz) and `railway up` ships it inside the backend image. Every instance's
 * cloud-init bootstrap (instancePool.userData) asks GET /v1/fleet/manifest,
 * compares it to the region filesystem's $FS/kiki/app/.manifest, downloads
 * /v1/fleet/bundle and swaps the app directory when they differ, then starts
 * the server from that code. Auth: a bearer token derived from
 * LAMBDA_API_KEY (same trust root as the per-instance WS tokens) — never the
 * user JWT secret.
 */
import { createHmac, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { FastifyPluginAsync } from 'fastify';
import { config } from '../../config/index.js';

export function fleetToken(): string {
  return createHmac('sha256', config.LAMBDA_API_KEY).update('kiki-fleet-bundle').digest('hex').slice(0, 40);
}

export function fleetBaseUrl(): string {
  return config.BACKEND_PUBLIC_URL.replace(/\/+$/, '');
}

function authorized(header: string | undefined): boolean {
  if (!config.LAMBDA_API_KEY) return false;
  const got = (header ?? '').replace(/^Bearer\s+/i, '');
  const want = fleetToken();
  return got.length === want.length && timingSafeEqual(Buffer.from(got), Buffer.from(want));
}

function readFleet(name: string): Buffer | null {
  try {
    return readFileSync(resolve(config.FLEET_DIR, name));
  } catch {
    return null;
  }
}

export const fleetRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/fleet/manifest', { config: { public: true } }, async (request, reply) => {
    if (!authorized(request.headers.authorization)) return reply.code(401).send({ error: 'unauthorized' });
    const m = readFleet('manifest.json');
    if (!m) return reply.code(404).send({ error: 'no fleet bundle in this deploy (run npm run deploy, not bare railway up)' });
    return reply.type('application/json').send(m);
  });
  fastify.get('/v1/fleet/bundle', { config: { public: true } }, async (request, reply) => {
    if (!authorized(request.headers.authorization)) return reply.code(401).send({ error: 'unauthorized' });
    const b = readFleet('model-servers.tgz');
    if (!b) return reply.code(404).send({ error: 'no fleet bundle in this deploy' });
    return reply.type('application/gzip').header('content-length', String(b.length)).send(b);
  });
};
