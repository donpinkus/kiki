/**
 * Lambda Cloud H100 IMAGE pool — serves the production image path.
 *
 * All orchestration machinery lives in the shared factory
 * (modules/lambda/instancePool.ts, factored out 2026-07-18 when the video
 * pool landed) — this module is the image-fleet instantiation plus the
 * flat function exports the existing call sites (stream.ts, sketchify.ts,
 * lambdaDev.ts, index.ts) were written against.
 *
 * Fleet identity: `kiki-serve-*` instances on the `kiki-image-<region>`
 * filesystem. Capacity model (measured): ~5 fully-served active drawers per
 * instance at 4-step 9B-KV; overload degrades gracefully (fair round-robin),
 * so the LAMBDA_POOL_TARGET_STREAMS dial is a UX knob, not a stability one.
 */

import type { FastifyBaseLogger } from 'fastify';
import { config } from '../../config/index.js';
import { createInstancePool } from './instancePool.js';

export type { DevPoolState, DevPoolStatusKind } from './instancePool.js';

const pool = createInstancePool({
  kind: 'image',
  namePrefix: 'kiki-serve-',
  fsName: (region) => `kiki-image-${region}`,
  label: 'H100',
  enabled: () => config.LAMBDA_DEV_POOL_ENABLED && config.LAMBDA_API_KEY.length > 0,
  region: () => config.LAMBDA_REGION,
  instanceType: () => config.LAMBDA_INSTANCE_TYPE,
  poolMin: () => config.LAMBDA_POOL_MIN,
  poolMax: () => config.LAMBDA_POOL_MAX,
  targetStreams: () => config.LAMBDA_POOL_TARGET_STREAMS,
  /** First-ever boot pays full compile (~10 min); with the persisted
   * inductor cache subsequent boots are shorter — refreshed empirically,
   * see the lambda-image-provider plan doc. */
  bootEstimateMs: 10 * 60_000,
});

export const touch = pool.touch;
export const hasReady = pool.hasReady;
export const reportFailure = pool.reportFailure;
export const acquireStream = pool.acquireStream;
export const releaseStream = pool.releaseStream;
export const touchInstance = pool.touchInstance;
export const wsUrl = pool.wsUrl;
export const ensure = pool.ensure;
export const getState = pool.getState;

export function start(logger: FastifyBaseLogger): void {
  pool.start(logger);
}

export function stop(): void {
  pool.stop();
}
