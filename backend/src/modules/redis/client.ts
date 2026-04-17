/**
 * Shared Redis client for the session registry (WS5) and future modules.
 *
 * Single ioredis client, multiplexed over one TCP connection. Lazy-connect
 * so import doesn't block; call `ensureRedis()` at boot to fail fast on
 * bad config.
 */

import { Redis } from 'ioredis';
import { config } from '../../config/index.js';

let redis: Redis | null = null;
let log: { info: (...a: unknown[]) => void; warn: (...a: unknown[]) => void; error: (...a: unknown[]) => void } =
  console;

export function setLogger(logger: typeof log): void {
  log = logger;
}

export function getRedis(): Redis {
  if (!redis) {
    if (!config.REDIS_URL) {
      throw new Error('REDIS_URL is not configured');
    }
    redis = new Redis(config.REDIS_URL, {
      maxRetriesPerRequest: null, // buffer commands during reconnect
      enableReadyCheck: true,
      lazyConnect: true,
      connectTimeout: 10_000,
      keepAlive: 30_000,
    });
    redis.on('error', (err: Error) => log.error({ err: err.message }, 'Redis error'));
    redis.on('reconnecting', (ms: number) => log.warn({ ms }, 'Redis reconnecting'));
    redis.on('ready', () => log.info('Redis ready'));
  }
  return redis;
}

/** Connect + PING. Call at boot to fail fast on bad config. */
export async function ensureRedis(): Promise<void> {
  const r = getRedis();
  await r.connect();
  const pong = await r.ping();
  if (pong !== 'PONG') {
    throw new Error(`Redis PING returned unexpected: ${pong}`);
  }
  log.info('Redis connected and healthy');
}
