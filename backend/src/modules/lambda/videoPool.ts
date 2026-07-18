/**
 * Lambda Cloud H100 VIDEO pool — dedicated LTX-2.3 instances for the
 * idle-state animation. Same orchestration machinery as the image pool
 * (modules/lambda/instancePool.ts); what differs is the node (fleet name,
 * filesystem, boot) and the LOAD MODEL, which drives deliberately slower
 * scaling:
 *
 *  - A video "stream" is a connected drawing session that only occasionally
 *    generates (one ~15-30s one-shot job per idle pause / Animate tap), not
 *    a continuous ⅓-fps image stream — so one instance serves many more
 *    sessions than an image instance (LAMBDA_VIDEO_POOL_TARGET_STREAMS=8 vs
 *    the image pool's 4).
 *  - Over-subscription degrades gracefully by design: generations queue
 *    behind the pipeline lock, videos arrive late, and cancel-on-resume
 *    prunes requests whose user started drawing again. Nothing user-visible
 *    breaks — video is best-effort everywhere — so the ceiling stays low
 *    (LAMBDA_VIDEO_POOL_MAX=1 by default; raise when real queueing shows up
 *    in video_trigger→video_complete latencies).
 *  - Floor 0 + interest-based warm-up: a user opening the app / starting a
 *    stream touches this pool, the next tick launches one instance, and
 *    sessions lazily pick up video mid-session when it becomes ready
 *    (VideoSession re-acquires on each fire attempt). Until then — and on
 *    any failure — sessions are simply image-only; there is no fal-style
 *    video fallback, "no video" IS the fallback.
 *
 * Fleet identity: `kiki-video-*` instances on the `kiki-video-<region>`
 * filesystem (populated by scripts/lambda/setup-lambda-video.ts). Instances
 * launched manually via scripts/lambda/launch-video.ts share the name prefix
 * and HMAC token scheme, so the pool ADOPTS them on backend (re)deploy —
 * setup instances use the non-colliding `kiki-vidsetup-` prefix precisely so
 * adoption never grabs one.
 */

import { config } from '../../config/index.js';
import { videoGenerationEnabled } from '../video/videoFlag.js';
import { createInstancePool } from './instancePool.js';

export type { PoolState, PoolStatusKind } from './instancePool.js';

const pool = createInstancePool({
  kind: 'video',
  namePrefix: 'kiki-video-',
  fsName: (region) => `kiki-video-${region}`,
  label: 'video H100',
  // Env opt-in AND the runtime Insights flag (admin_config.video_generation).
  // Flag off → instancePool's disabled tick DRAINS running video instances
  // within ~60s, so the kill switch also stops the billing, not just launches.
  enabled: () => videoGenerationEnabled() && config.LAMBDA_API_KEY.length > 0,
  region: () => config.LAMBDA_VIDEO_REGION,
  instanceType: () => config.LAMBDA_INSTANCE_TYPE,
  poolMin: () => config.LAMBDA_VIDEO_POOL_MIN,
  poolMax: () => config.LAMBDA_VIDEO_POOL_MAX,
  targetStreams: () => config.LAMBDA_VIDEO_POOL_TARGET_STREAMS,
  /** LTX-2.3 model load is ~5-10 min on a cold NFS page cache (no compile
   * cache to persist yet — LTX runs eager). */
  bootEstimateMs: 10 * 60_000,
});

// The factory returns plain closures, so destructuring is safe.
export const { touch, hasReady, reportFailure } = pool;
export const {
  acquireStream, releaseStream, touchInstance, wsUrl, ensure, getState, start, stop,
} = pool;

/** True when the video pool is configured on (used by stream.ts to decide
 * whether to create a pool-backed VideoSession at all). */
export function poolEnabled(): boolean {
  return videoGenerationEnabled() && config.LAMBDA_API_KEY.length > 0;
}
