// ────────────────────────────────────────────────────────────────────────────
// Provisioner — the provision state machine.
// ────────────────────────────────────────────────────────────────────────────
//
// Everything from "give me a healthy pod for this session" through placement →
// create (spot then on-demand) → wait for runtime + health → reroll across DCs
// on stall/vanish. The per-kind divergence is data: `POD_CONFIGS[kind]` holds the
// six fields that differ between image and video pods; `_runProvisionLoop` is the
// shared machinery. Kept whole in one module because POD_CONFIGS closes over
// createPodWithFallback and _runProvisionLoop reads POD_CONFIGS — splitting them
// would force exporting those internals. Admission control (the in-flight dedupe
// map + the concurrency semaphore) lives in orchestrator.ts, not here; the loop
// receives an AbortSignal as a parameter.
//
// ── Adding a new pod kind ──
//   1. provisioner.ts : add the kind to `PodKind` (podBoot.ts) + a row to POD_CONFIGS.
//   2. podBoot.ts     : add its BOOT_DOCKER_ARGS_<KIND> + <KIND>_POD_PREFIX.
//   3. orchestrator.ts: add 1-2 thin public wrappers (mirror getOrProvisionVideoPod).
//   4. reaper.ts      : wire the new prefix into reconcileOrphanPods' listing.

import { readFileSync } from 'node:fs';
import * as Sentry from '@sentry/node';

import { config } from '../../config/index.js';
import {
  createOnDemandPod,
  createSpotPod,
  getPod,
  getSpotBid,
  isCapacityError,
  terminatePod,
  type SpotBidInfo,
} from './runpodClient.js';
import { getPolicy } from './policy.js';
import { notifyPodCreated, notifyPodProgress } from './costMonitor.js';
import {
  PodBootStallError,
  PodVanishedError,
  ProvisionAbortedError,
  classifyProvisionError,
} from './errorClassification.js';
import { log } from './logger.js';
import {
  type State,
  type PodType,
  type RedisSession,
  patchSession,
} from './sessionStore.js';
import {
  type PodKind,
  POD_PREFIX,
  VIDEO_POD_PREFIX,
  BASE_IMAGE,
  BOOT_DOCKER_ARGS,
  BOOT_DOCKER_ARGS_VIDEO,
  bootEnvFor,
} from './podBoot.js';
import { emitState } from './broker.js';
import { markPodDead } from './podDeath.js';
import {
  trackPodProvisionStarted,
  trackPodProvisionCompleted,
  trackPodProvisionFailed,
  trackPodProvisionStalled,
  trackPodProvisionVanished,
} from '../analytics/index.js';

const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
// Headroom above the current spot floor. Larger headroom = fewer outbids =
// fewer needless fallbacks to on-demand. 0.05 costs ~$0.03/hr more than the
// 0.02 default on a typical bid, cheaper than one on-demand fallback.
const BID_HEADROOM = 0.05;
// Drift check uses the git tree-hash of `model-servers/` — the subtree
// that sync-flux-app actually rsyncs to volumes. This changes only when files
// in that path change, so doc/iOS/backend commits don't false-trigger drift
// (which was the problem with the prior commit-SHA-based check). Written by
// `npm run deploy` (`git rev-parse HEAD:model-servers > .flux-app-version`)
// and baked into the Docker image via the Dockerfile's `COPY . .`. Empty
// string = file missing; drift check no-ops.
export const BACKEND_FLUX_APP_VERSION = (() => {
  try {
    return readFileSync('/app/.flux-app-version', 'utf-8').trim();
  } catch {
    return '';
  }
})();
// ────────────────────────────────────────────────────────────────────────────
// Pod kinds: one operation (provision a pod) parameterized by a small static
// config. POD_CONFIGS holds the six values that genuinely differ between
// image and video pods. Everything else — DC selection, reroll on stall,
// runtime+health waits, idle reaping, reconcile — is shared machinery in
// `_runProvisionLoop`. The four public entry points (getOrProvisionPod /
// getOrProvisionVideoPod / replaceSession / replaceVideoSession) call the
// helper with `kind` and read POD_CONFIGS[kind] for the diffs. Per-kind
// outer concerns (image: semaphore + initial-row writeSession + Sentry span +
// emitState; video: best-effort try/catch + image-DC co-location) live in
// the public functions, not the helper.
//
// One in-process inFlight map (`inFlightProvisions`, keyed `${kind}:${sessionId}`)
// dedupes concurrent provisions for both kinds. Adding a new pod kind = add
// a row to POD_CONFIGS + 1-2 thin public wrappers; no new Redis schema
// field, no new map.
// ────────────────────────────────────────────────────────────────────────────

interface PodKindConfig {
  /** Pod name prefix (must be unique per kind so reconcile + Discord alerts
   *  can list each kind separately). */
  namePrefix: string;
  /** Container entrypoint. Differs by kind only in which python script. */
  bootDockerArgs: string;
  /** RunPod proxy port for this pod's HTTP/WS service. */
  port: number;
  /** RunPod GPU SKU. Image: RTX 5090 (Blackwell, NVFP4 path for FLUX).
   *  Video: H100 80GB HBM3 (SXM, needed for LTX-2.3 22B FP8 + Gemma + activations
   *  — the ~46 GB total VRAM footprint doesn't fit on 5090). */
  gpuTypeId: string;
  /** Per-kind map of DC → networkVolumeId, sourced from config.NETWORK_VOLUMES_BY_DC*
   *  at construction time. Image and video volume sets diverge: image lives in
   *  5090 DCs, video lives in H100-SXM DCs (different DCs because RunPod's
   *  capacity allocation differs by GPU). selectPlacement consumes this. */
  volumesByDc: Readonly<Record<string, string>>;
  /** Watchdog budget for `waitForRuntime`. Image: 45 s (handles by reroll).
   *  Video: 240 s (LTX-2.3 22B FP8 + Gemma encoder load is heavier than
   *  LTXV 2B distilled was; needs more headroom before giving up). */
  stallMs: number;
  /** Create a pod for the chosen DC. Image: spot then on-demand fallback.
   *  Video: on-demand only (preemption recovery via replaceVideoSession is
   *  cleaner than spot complexity at our scale).
   *
   *  `streamId` flows through into BOOT_ENV (via `bootEnvFor`) so the pod
   *  can tag every log with `stream_id` from the moment its python process
   *  starts. May be `null` when called for legacy non-JWT sessions. */
  createPodForDc: (
    target: PlacementTarget,
    sessionId: string,
    streamId?: string | null,
  ) => Promise<{ podId: string; podType: PodType; dc: string | null }>;
  /** Look up a reusable pod from an existing session row. null if none.
   *  Image: trusts row.state === 'ready' && row.podUrl (fast Redis-only).
   *  Video: row.videoPodId set AND getPod returns RUNNING+runtime
   *  (~500 ms RunPod query — needed because video doesn't have a state
   *  field; deferred state-emit follow-up would let video also do
   *  Redis-only). */
  getReusableFromRow: (
    row: RedisSession,
  ) => Promise<{ podId: string; podUrl: string } | null>;
  /** Stamp the row with the new pod's identity after provision succeeds.
   *  Image: { podId, podUrl, podType } — full set, since image's reuse
   *  check reads podUrl from the row. Video: { videoPodId } — minimal,
   *  since video's reuse check uses RunPod query. */
  stampRow: (
    sessionId: string,
    pod: { podId: string; podUrl: string; podType: PodType },
  ) => Promise<void>;
}

// `POD_CONFIGS: Record<PodKind, PodKindConfig>` is defined further below,
// after the helper functions it closes over (createPodWithFallback,
// createOnDemandPod, getPod, patchSession). Search for `const POD_CONFIGS`.
// ────────────────────────────────────────────────────────────────────────────
// Provisioner
// ────────────────────────────────────────────────────────────────────────────

interface ProvisionResult {
  podId: string;
  podUrl: string;
  podType: PodType;
}

/**
 * Classify a provision-attempt error as "recoverable by DC reroll" or not, and
 * emit the structured observability signals (log + Sentry breadcrumb + PostHog
 * event) for the recoverable class. `PodBootStallError` and `PodVanishedError`
 * are the two recoverable classes — both point at a flaky DC and are handled
 * identically except for the event names and the state attribute.
 *
 * Returns `'retry'` when the caller should blacklist `errDc` and re-enter the
 * reroll loop, `'abort'` when the caller should fall through to the generic
 * failure path (unrecoverable error, or rerolls exhausted).
 */
/**
 * Drift status the volume's flux_app_version reflects relative to the backend's
 * expected version:
 *   - 'current'        — volume is on the same model-servers tree as backend
 *   - 'drift'          — volume has a different flux_app_version than backend
 *   - 'missing_stamp'  — volume predates flux_app_version stamping (pre-2026-04-26)
 *   - 'unknown'        — backend has no expected version (local dev / no .flux-app-version)
 * Returned from checkVersionDrift and surfaced on every pod.provision.completed
 * PostHog event as `volume_status` so we can query drift trends without going
 * to Sentry.
 */
type VolumeStatus = 'current' | 'drift' | 'missing_stamp' | 'unknown';

/**
 * Compare the FLUX pod's reported flux_app_version (from /health, originally
 * written into /workspace/app/.version.json by sync-flux-app.ts) against the
 * backend's expected flux_app_version. Both are git tree-hashes of the
 * `model-servers/` subtree at the respective deploy times, so they only
 * change when files that actually get rsynced to volumes change. Doc/iOS/
 * backend commits don't false-trigger.
 *
 * Side effects on non-current status:
 *   - log.warn with structured fields (Railway logs)
 *   - Sentry.captureMessage at warning level (Sentry dedups by dc + version pair)
 * Caller forwards the returned status onto pod.provision.completed as
 * `volume_status` for PostHog visibility.
 *
 * Returns 'unknown' when BACKEND_FLUX_APP_VERSION is unset (local dev / no
 * .flux-app-version baked into the image) — drift cannot be evaluated.
 */
function checkVersionDrift(
  appVersion: Record<string, string | number | boolean>,
  ctx: { sessionId: string; podId: string; dc: string | null },
): VolumeStatus {
  if (!BACKEND_FLUX_APP_VERSION) return 'unknown';
  const actualVersion = typeof appVersion['app_flux_app_version'] === 'string'
    ? (appVersion['app_flux_app_version'] as string)
    : '';
  if (!actualVersion) {
    log.warn(
      {
        sessionId: ctx.sessionId,
        podId: ctx.podId,
        dc: ctx.dc,
        backendFluxVersion: BACKEND_FLUX_APP_VERSION.slice(0, 8),
        event: 'volume.version.missing',
      },
      'Pod has no flux_app_version on /health — volume predates flux-app-version stamping',
    );
    Sentry.captureMessage('Pod volume missing flux_app_version stamp', {
      level: 'warning',
      tags: {
        dc: ctx.dc ?? 'unknown',
        backend_flux_version: BACKEND_FLUX_APP_VERSION.slice(0, 8),
        kind: 'missing_stamp',
      },
      contexts: { pod: { id: ctx.podId, sessionId: ctx.sessionId } },
    });
    return 'missing_stamp';
  }
  if (actualVersion !== BACKEND_FLUX_APP_VERSION) {
    log.warn(
      {
        sessionId: ctx.sessionId,
        podId: ctx.podId,
        dc: ctx.dc,
        backendFluxVersion: BACKEND_FLUX_APP_VERSION.slice(0, 8),
        volumeFluxVersion: actualVersion.slice(0, 8),
        event: 'volume.version.drift',
      },
      'Pod volume flux_app_version differs from backend',
    );
    Sentry.captureMessage('Pod volume flux_app_version drift', {
      level: 'warning',
      tags: {
        dc: ctx.dc ?? 'unknown',
        backend_flux_version: BACKEND_FLUX_APP_VERSION.slice(0, 8),
        volume_flux_version: actualVersion.slice(0, 8),
        kind: 'flux_app_drift',
      },
      contexts: { pod: { id: ctx.podId, sessionId: ctx.sessionId } },
    });
    return 'drift';
  }
  return 'current';
}

function handleRecoverableProvisionError(
  err: Error,
  ctx: {
    sessionId: string;
    dc: string | null;
    podType: PodType | null;
    attempt: number;
    maxRerolls: number;
  },
): { decision: 'retry' | 'abort'; errDc: string | null } {
  if (!(err instanceof PodBootStallError) && !(err instanceof PodVanishedError)) {
    return { decision: 'abort', errDc: null };
  }
  const errDc = err.dc ?? ctx.dc;
  const willReroll = ctx.attempt < ctx.maxRerolls;
  const isStall = err instanceof PodBootStallError;
  const errState: State = isStall ? 'fetching_image' : err.state;
  const message = isStall ? 'Image pull stalled' : 'Pod vanished during provisioning';

  log.warn(
    {
      sessionId: ctx.sessionId,
      event: isStall ? 'provision.pull.stall_detected' : 'provision.pod.vanished',
      podId: err.podId,
      dc: errDc,
      state: errState,
      elapsedSec: err.elapsedSec,
      attempt: ctx.attempt,
      willReroll,
    },
    message,
  );
  Sentry.captureMessage(message, {
    level: 'warning',
    tags: {
      dc: errDc ?? 'unknown',
      podType: ctx.podType ?? 'unknown',
      state: errState,
      attempt: String(ctx.attempt),
      willReroll: String(willReroll),
    },
    contexts: {
      pod: { id: err.podId, sessionId: ctx.sessionId, elapsedSec: err.elapsedSec },
    },
  });
  if (isStall) {
    trackPodProvisionStalled({
      userId: ctx.sessionId,
      dc: errDc,
      elapsedSec: err.elapsedSec,
      attempt: ctx.attempt,
      willReroll,
    });
  } else {
    trackPodProvisionVanished({
      userId: ctx.sessionId,
      dc: errDc,
      state: errState,
      elapsedSec: err.elapsedSec,
      attempt: ctx.attempt,
      willReroll,
    });
  }
  return { decision: willReroll ? 'retry' : 'abort', errDc };
}

/**
 * Thin image-pod wrapper around _runProvisionLoop. Adds image-specific
 * outer concerns: parent Sentry span; emitState + Discord notify between
 * phases (drives the iPad's "Finding GPU... Creating pod..." overlay);
 * terminal `failed` state emit on giveup.
 *
 * The helper does the actual mechanics (selectPlacement → create → wait
 * for runtime + health, retry across DCs on stall/vanish) and the cross-
 * kind concerns (analytics, Sentry exception capture).
 */
export async function provision(
  sessionId: string,
  signal?: AbortSignal,
  streamId?: string | null,
): Promise<ProvisionResult> {
  return Sentry.startSpan(
    { name: 'pod.provision', op: 'pod.provision', attributes: { sessionId } },
    async () => {
      try {
        const result = await _runProvisionLoop('image', sessionId, {
          signal,
          streamId,
          onProvisionPhase: async (phase, podId) => {
            await emitState(sessionId, phase);
            if (podId && phase === 'fetching_image') {
              notifyPodProgress(podId, '⏳ Fetching container image...');
            } else if (podId && phase === 'warming_model') {
              notifyPodProgress(podId, '🧠 Warming up AI model...');
            }
          },
        });
        notifyPodProgress(result.podId, '✅ **Pod serving**');
        return { podId: result.podId, podUrl: result.podUrl, podType: result.podType };
      } catch (err) {
        // Helper has already done analytics + Sentry capture. Layer on the
        // image-only terminal-state emit so iPad subscribers see 'failed'.
        // Bubble the real error message up to the client — they get to see
        // exactly what went wrong instead of a category-mapped string.
        const category = classifyProvisionError(err as Error);
        await emitState(sessionId, 'failed', category, (err as Error).message);
        throw err;
      }
    },
  );
}

/**
 * A candidate placement: which DC to pin the pod to, and optionally which
 * pre-populated network volume to attach. `null` for both means "let RunPod
 * pick any DC, no volume" — only hit when NETWORK_VOLUMES_BY_DC is empty
 * (e.g. local dev without volumes configured).
 */
interface PlacementTarget {
  dataCenterId: string | null;
  networkVolumeId: string | null;
  bidInfo: SpotBidInfo | null;
}

/**
 * With a configured NETWORK_VOLUMES_BY_DC, iterate through each volume DC and
 * query spot stock. Returns the first DC with Medium/High stock (with its
 * bid info), or the best-stock DC even if Low (so the caller can
 * still try spot before falling back to on-demand). Returns `null` only if
 * every DC returns a hard capacity miss.
 *
 * In non-baked mode or with no volumes configured, returns a single unpinned
 * target (DC = null) and lets RunPod pick.
 */
async function selectPlacement(
  kind: PodKind,
  sessionId: string,
  excludeDcs: ReadonlySet<string> = new Set(),
  preferredDc?: string,
): Promise<PlacementTarget | null> {
  const cfg = POD_CONFIGS[kind];
  const volumes = cfg.volumesByDc;
  const volumeDcs = Object.keys(volumes).filter((dc) => !excludeDcs.has(dc));
  const useVolumes = volumeDcs.length > 0;

  if (!useVolumes) {
    try {
      const bidInfo = await getSpotBid(cfg.gpuTypeId);
      return { dataCenterId: null, networkVolumeId: null, bidInfo };
    } catch (err) {
      if (isCapacityError(err)) return { dataCenterId: null, networkVolumeId: null, bidInfo: null };
      throw err;
    }
  }

  // Volume-aware path: probe each DC, rank by stock, pick the best.
  const rank: Record<string, number> = { High: 3, Medium: 2, Low: 1, None: 0 };
  const probed: Array<{ dc: string; volumeId: string; bid: SpotBidInfo | null }> = [];
  await Promise.all(
    volumeDcs.map(async (dc) => {
      const volumeId = volumes[dc]!;
      try {
        const bid = await getSpotBid(cfg.gpuTypeId, { dataCenterId: dc });
        probed.push({ dc, volumeId, bid });
      } catch (err) {
        if (isCapacityError(err)) {
          probed.push({ dc, volumeId, bid: null });
        } else {
          throw err;
        }
      }
    }),
  );

  // Sort: DCs with stock first (by rank), then null-stock DCs (for on-demand only).
  probed.sort((a, b) => {
    const ar = a.bid ? (rank[a.bid.stockStatus] ?? 0) : -1;
    const br = b.bid ? (rank[b.bid.stockStatus] ?? 0) : -1;
    return br - ar;
  });

  // Float the caller's preferred DC to the front IF it shows any non-zero
  // stock. Used by video-pod placement to co-locate with the image pod's
  // DC, avoiding cross-DC trigger latency and the "image pod placed in
  // working DC X but video pod independently chose broken DC Y" trap.
  if (preferredDc) {
    const idx = probed.findIndex((p) => p.dc === preferredDc);
    if (idx > 0) {
      const candidate = probed[idx]!;
      const stockRank = candidate.bid ? (rank[candidate.bid.stockStatus] ?? 0) : 0;
      if (stockRank > 0) {
        probed.splice(idx, 1);
        probed.unshift(candidate);
      }
    }
  }

  log.info(
    {
      sessionId,
      event: 'provision.placement.ranked',
      dcs: probed.map((p) => ({ dc: p.dc, stock: p.bid?.stockStatus ?? 'none' })),
      excluded: Array.from(excludeDcs),
      preferredDc: preferredDc ?? null,
    },
    'DC placement ranked',
  );

  const top = probed[0];
  if (!top) return null;
  return { dataCenterId: top.dc, networkVolumeId: top.volumeId, bidInfo: top.bid };
}

/**
 * Tries spot first. Falls through to on-demand on capacity exhaustion if
 * `ONDEMAND_FALLBACK_ENABLED` is set and the policy allows it. Emits structured
 * events at each decision point so Workstream 4 can attribute cost by pod type.
 *
 * In baked mode with network volumes, pins both spot and on-demand attempts
 * to the selected volume's DC so the pre-populated weights are reachable.
 */
async function createPodWithFallback(
  sessionId: string,
  target: PlacementTarget,
  podName: string,
  bootDockerArgs: string,
  streamId?: string | null,
): Promise<{ podId: string; podType: PodType; dc: string | null }> {
  const env = bootEnvFor(sessionId, streamId);
  // Volume-entrypoint mode: stock RunPod pytorch image + our code/deps from
  // the attached network volume. See BASE_IMAGE / BOOT_DOCKER_ARGS / BOOT_ENV
  // constants near top of file. Replaces the previous GHCR custom-image flow —
  // eliminates registry auth, build pipeline, and the image-pull stall mode
  // that affected ~38% of provisions. See documents/decisions.md entry
  // 2026-04-23 for context + rollback procedure.
  const imageName = BASE_IMAGE;
  const bidInfo = target.bidInfo;
  const dcField = target.dataCenterId ? { dataCenterId: target.dataCenterId } : {};
  const volField = target.networkVolumeId ? { networkVolumeId: target.networkVolumeId } : {};

  // ─── Try spot ─────────────────────────────────────────────────────────
  let spotCapacityExhausted = false;
  let fallbackReason: string | null = null;

  if (config.ONDEMAND_ONLY_MODE) {
    // Operator has disabled spot for stability. Skip the spot attempt and
    // fall through to the on-demand path. Probe results from selectPlacement
    // (DC ranking) are still used; only the spot create call is bypassed.
    spotCapacityExhausted = true;
    fallbackReason = 'ondemand_only_mode';
    log.info(
      { sessionId, event: 'provision.spot.skipped', reason: fallbackReason, dc: target.dataCenterId },
      'Spot disabled by ONDEMAND_ONLY_MODE — going straight to on-demand',
    );
  } else if (!bidInfo) {
    spotCapacityExhausted = true;
    fallbackReason = 'spot_bid_unavailable';
    log.info(
      { sessionId, event: 'provision.spot.capacityMiss', reason: fallbackReason, dc: target.dataCenterId },
      'No spot pricing — will try on-demand',
    );
  } else if (bidInfo.stockStatus === 'None' || bidInfo.stockStatus === 'Low') {
    spotCapacityExhausted = true;
    fallbackReason = `stock_${bidInfo.stockStatus.toLowerCase()}`;
    log.info(
      { sessionId, event: 'provision.spot.capacityMiss', stockStatus: bidInfo.stockStatus, dc: target.dataCenterId },
      'Spot stock low — will try on-demand',
    );
  }

  if (!spotCapacityExhausted && bidInfo) {
    const bid = Math.round((bidInfo.minimumBidPrice + BID_HEADROOM) * 100) / 100;
    log.info(
      {
        sessionId,
        event: 'provision.spot.attempt',
        minBid: bidInfo.minimumBidPrice,
        stockStatus: bidInfo.stockStatus,
        bid,
        dc: target.dataCenterId,
        volumeId: target.networkVolumeId,
      },
      'Spot bid discovered',
    );
    try {
      const { id: podId, costPerHr } = await createSpotPod({
        name: podName,
        imageName,
        gpuTypeId: GPU_TYPE_ID,
        bidPerGpu: bid,
        dockerArgs: bootDockerArgs,
        env,
        containerRegistryAuthId: config.RUNPOD_REGISTRY_AUTH_ID,
        ...dcField,
        ...volField,
      });
      log.info(
        { sessionId, event: 'provision.spot.success', podId, costPerHr, podType: 'spot', dc: target.dataCenterId },
        'Pod created (spot)',
      );
      void notifyPodCreated({ podId, podType: 'spot', dc: target.dataCenterId ?? undefined, costPerHr });
      return { podId, podType: 'spot', dc: target.dataCenterId };
    } catch (err) {
      if (isCapacityError(err)) {
        spotCapacityExhausted = true;
        fallbackReason = 'spot_create_capacity_error';
        log.info(
          { sessionId, event: 'provision.spot.capacityMiss', err: (err as Error).message, dc: target.dataCenterId },
          'Spot createPod hit capacity error — will try on-demand',
        );
      } else {
        throw err;
      }
    }
  }

  // ─── Fall through to on-demand ───────────────────────────────────────
  if (!config.ONDEMAND_FALLBACK_ENABLED && !config.ONDEMAND_ONLY_MODE) {
    throw new Error(
      `5090 spot capacity exhausted (${fallbackReason ?? 'unknown'}); on-demand fallback disabled`,
    );
  }

  // Policy gate — v1 allows everyone. Post-WS8, free-tier users may stay spot-only.
  const allowed = await getPolicy().allowsOnDemand({ userId: sessionId, source: 'jwt' });
  if (!allowed) {
    throw new Error(
      `5090 spot capacity exhausted (${fallbackReason ?? 'unknown'}); on-demand not allowed by policy`,
    );
  }

  log.info(
    { sessionId, event: 'provision.fallback.triggered', reason: fallbackReason, dc: target.dataCenterId },
    'Switching to on-demand pod',
  );
  try {
    const { id: podId, costPerHr } = await createOnDemandPod({
      name: podName,
      imageName,
      gpuTypeId: GPU_TYPE_ID,
      cloudType: 'SECURE',
      dockerArgs: bootDockerArgs,
      env,
      containerRegistryAuthId: config.RUNPOD_REGISTRY_AUTH_ID,
      ...dcField,
      ...volField,
    });
    log.info(
      { sessionId, event: 'provision.onDemand.success', podId, costPerHr, podType: 'onDemand', dc: target.dataCenterId },
      'Pod created (on-demand)',
    );
    void notifyPodCreated({ podId, podType: 'onDemand', dc: target.dataCenterId ?? undefined, costPerHr });
    return { podId, podType: 'onDemand', dc: target.dataCenterId };
  } catch (err) {
    log.error(
      { sessionId, event: 'provision.onDemand.failed', err: (err as Error).message, dc: target.dataCenterId },
      'On-demand fallback also failed',
    );
    throw err;
  }
}

// ────────────────────────────────────────────────────────────────────────────
// POD_CONFIGS — see PodKindConfig declaration near top of file for the rules.
// Defined here so it can close over createPodWithFallback / createOnDemandPod.
// ────────────────────────────────────────────────────────────────────────────

const POD_CONFIGS: Record<PodKind, PodKindConfig> = {
  image: {
    namePrefix: POD_PREFIX,
    bootDockerArgs: BOOT_DOCKER_ARGS,
    // Both image (image/server.py) and video (video/server.py) bind to 8766 via
    // BOOT_ENV.FLUX_PORT — same Python server framework, different scripts.
    // Kept parametric in case a future pod kind diverges.
    port: 8766,
    gpuTypeId: 'NVIDIA GeForce RTX 5090',
    volumesByDc: config.NETWORK_VOLUMES_BY_DC,
    stallMs: config.POD_BOOT_WATCHDOG_ENABLED ? config.POD_BOOT_STALL_MS : Infinity,
    createPodForDc: (target, sessionId, streamId) => {
      const podName = `${POD_PREFIX}${sessionId.slice(0, 16)}`;
      return createPodWithFallback(sessionId, target, podName, BOOT_DOCKER_ARGS, streamId);
    },
    // Image: row says ready, but the pod may have died externally (RunPod-
    // side preemption, host failure, manual termination during ops). The
    // close-handler in stream.ts only catches mid-session deaths — initial
    // wire failure on a stale podId 404s and bounces the iPad. Probe RunPod
    // before trusting the row, matching what the video kind already does
    // below. ~500 ms per reconnect, but keeps reuse honest as a cache of
    // RunPod state rather than an authoritative claim.
    getReusableFromRow: async (row) => {
      if (row.state !== 'ready' || !row.podUrl || !row.podId) {
        log.info(
          {
            sessionId: row.sessionId,
            rowState: row.state,
            hasPodUrl: !!row.podUrl,
            hasPodId: !!row.podId,
            event: 'image_reuse_skipped_row',
          },
          'image_reuse_skipped_row',
        );
        return null;
      }
      const probeStart = Date.now();
      const pod = await getPod(row.podId).catch((err) => {
        log.warn(
          {
            sessionId: row.sessionId,
            podId: row.podId,
            err: (err as Error).message,
            elapsedMs: Date.now() - probeStart,
            event: 'image_reuse_probe_threw',
          },
          'image_reuse_probe_threw',
        );
        return null;
      });
      const probeMs = Date.now() - probeStart;
      const ok = !!pod && pod.desiredStatus === 'RUNNING' && pod.runtime !== null;
      log.info(
        {
          sessionId: row.sessionId,
          podId: row.podId,
          ok,
          desiredStatus: pod?.desiredStatus ?? null,
          hasRuntime: pod?.runtime !== null && pod?.runtime !== undefined,
          probeMs,
          event: 'image_reuse_probe',
        },
        'image_reuse_probe',
      );
      // Note: `ok` here means RunPod thinks the pod is RUNNING. It does NOT
      // mean the pod's WS port is reachable — a half-open backend↔pod TCP
      // would still pass this gate and surface as a wireRelay timeout in
      // stream.ts.
      if (ok) {
        return { podId: row.podId, podUrl: row.podUrl };
      }
      return null;
    },
    stampRow: (sessionId, pod) =>
      patchSession(sessionId, { podId: pod.podId, podUrl: pod.podUrl, podType: pod.podType }),
  },
  video: {
    namePrefix: VIDEO_POD_PREFIX,
    bootDockerArgs: BOOT_DOCKER_ARGS_VIDEO,
    port: 8766,
    // H100 SXM (80 GB) — LTX-2.3 22B FP8 transformer (~27.5 GB) + Gemma-3-12B
    // encoder (~6 GB) + spatial upscaler + activations doesn't fit on a 5090's
    // 32 GB. Image and video DC sets diverge: video volumes live in DCs that
    // stock H100 SXM, image volumes live in 5090 DCs.
    gpuTypeId: 'NVIDIA H100 80GB HBM3',
    volumesByDc: config.NETWORK_VOLUMES_BY_DC_VIDEO,
    // LTX-2.3 22B + Gemma encoder load is heavier than LTXV 0.9.8's 2B —
    // the previous 180s budget routinely tripped the watchdog on cold pulls.
    stallMs: 240_000,
    createPodForDc: async (target, sessionId, streamId) => {
      const podName = `${VIDEO_POD_PREFIX}${sessionId.slice(0, 16)}`;
      const dcField = target.dataCenterId ? { dataCenterId: target.dataCenterId } : {};
      const volField = target.networkVolumeId ? { networkVolumeId: target.networkVolumeId } : {};
      const result = await createOnDemandPod({
        name: podName,
        imageName: BASE_IMAGE,
        // H100 SXM. Defined here rather than at module scope because the
        // image kind uses a different GPU SKU; GPU_TYPE_ID at the top of
        // this file is the legacy image-only constant.
        gpuTypeId: 'NVIDIA H100 80GB HBM3',
        cloudType: 'SECURE',
        dockerArgs: BOOT_DOCKER_ARGS_VIDEO,
        env: bootEnvFor(sessionId, streamId),
        containerRegistryAuthId: config.RUNPOD_REGISTRY_AUTH_ID,
        ...dcField,
        ...volField,
      });
      return { podId: result.id, podType: 'onDemand', dc: target.dataCenterId };
    },
    // Video: row only has `videoPodId`; no state field. Probe RunPod for
    // RUNNING+runtime as the readiness signal. ~500ms cost on every
    // reconnect — acceptable because video reconnects are less frequent
    // than image's per-message touch traffic.
    getReusableFromRow: async (row) => {
      if (!row.videoPodId) return null;
      const pod = await getPod(row.videoPodId).catch(() => null);
      if (pod && pod.desiredStatus === 'RUNNING' && pod.runtime !== null) {
        return {
          podId: row.videoPodId,
          podUrl: `wss://${row.videoPodId}-${POD_CONFIGS.video.port}.proxy.runpod.net/ws`,
        };
      }
      return null;
    },
    stampRow: (sessionId, pod) =>
      patchSession(sessionId, { videoPodId: pod.podId }),
  },
};

/**
 * Shared pod-spinup mechanics: select a DC, create a pod for it, wait for
 * runtime + health, retry across DCs on stall/vanish. The kind parameter
 * drives all pod-specific differences via `POD_CONFIGS[kind]` — no
 * conditionals on `kind` in the loop body.
 *
 * Caller hooks:
 *   - `opts.onProvisionPhase(phase, podId)`: called inside the loop at each
 *     state transition. Image pod's `provision()` wrapper supplies a
 *     callback that does `emitState` + `notifyPodProgress`. Video doesn't
 *     supply one, so video provisioning is silent on the broker.
 *   - `opts.preferredDc`: if set, floats to the top of the placement
 *     ranking when stock is non-zero. Used by video to co-locate with
 *     the image pod's DC.
 *
 * Throws `PodBootStallError` / `PodVanishedError` (recoverable, but only
 * after exhausting `POD_BOOT_MAX_REROLLS`) or any other error from the
 * underlying RunPod / health-check APIs (terminal). Image's `provision()`
 * wrapper catches these and re-throws after analytics; video's caller
 * catches and returns null for best-effort behavior.
 */
export async function _runProvisionLoop(
  kind: PodKind,
  sessionId: string,
  opts: {
    preferredDc?: string;
    signal?: AbortSignal;
    onProvisionPhase?: (phase: State, podId: string | null) => Promise<void>;
    /** Forwarded into BOOT_ENV.KIKI_STREAM_ID so pod logs carry it. */
    streamId?: string | null;
  } = {},
): Promise<{ podId: string; podUrl: string; podType: PodType; dc: string | null }> {
  // `opts.signal` is the AbortSignal of the AbortController held in
  // orchestrator.ts's `inFlightProvisions` entry for this session. abortSession
  // (orchestrator.ts) fires it on signout/error; the checkpoints below are the
  // consuming end of that seam (edge-case #11). This loop never touches the
  // in-flight map itself — the signal is the only coupling.
  const cfg = POD_CONFIGS[kind];
  const t0 = Date.now();
  const blacklistedDcs = new Set<string>();
  const maxRerolls = Math.max(0, config.POD_BOOT_MAX_REROLLS);

  for (let attempt = 0; attempt <= maxRerolls; attempt++) {
    let podId: string | null = null;
    let podType: PodType | null = null;
    let dc: string | null = null;
    let currentState: State = 'finding_gpu';
    const attemptStart = Date.now();
    let phaseStart = attemptStart;
    const phaseTimings: Record<string, number> = {};

    // Checkpoint #1: bail before doing any work this iteration. Nothing to
    // clean up — no pod created yet for this attempt.
    if (opts.signal?.aborted) {
      throw new ProvisionAbortedError(null, 'pre_create');
    }

    // On reroll, return the UI to 'finding_gpu' before the next pod create.
    if (attempt > 0) {
      await opts.onProvisionPhase?.('finding_gpu', null);
      currentState = 'finding_gpu';
    }

    trackPodProvisionStarted({
      userId: sessionId,
      attempt,
      excludedDcs: Array.from(blacklistedDcs),
    });

    try {
      // 1 + 2. DC selection + pod create. Both are kind-specific via
      // POD_CONFIGS[kind] — image goes spot-then-on-demand on 5090s in
      // image volumes' DCs; video goes straight on-demand on H100 SXM in
      // video volumes' DCs. selectPlacement reads the right volume map +
      // GPU SKU from cfg.
      const target = await selectPlacement(kind, sessionId, blacklistedDcs, opts.preferredDc);
      if (!target) {
        const suffix = blacklistedDcs.size > 0
          ? ` (excluding ${Array.from(blacklistedDcs).join(',')} after earlier stall)`
          : '';
        throw new Error(
          `No RunPod DC has ${cfg.gpuTypeId} capacity right now (all volume-DCs exhausted)${suffix}`,
        );
      }
      await opts.onProvisionPhase?.('creating_pod', null);
      currentState = 'creating_pod';
      const created = await Sentry.startSpan(
        { name: 'pod.create', op: 'pod.create', attributes: { sessionId, kind, attempt } },
        () => cfg.createPodForDc(target, sessionId, opts.streamId),
      );
      podId = created.podId;
      podType = created.podType;
      dc = created.dc;

      phaseTimings.creating_pod_ms = Date.now() - phaseStart;
      phaseStart = Date.now();

      Sentry.addBreadcrumb({
        category: 'provision',
        level: 'info',
        message: 'Pod created',
        data: { podId, dc, podType, kind, attempt, creatingPodMs: phaseTimings.creating_pod_ms },
      });

      // Checkpoint #2: pod just created. If the caller aborted while we were
      // in cfg.createPodForDc, terminate this pod before doing further work.
      // The post-create catch handler below would also clean up since we
      // throw, but inlining the terminate makes the intent unambiguous.
      if (opts.signal?.aborted) {
        log.info({ sessionId, kind, podId, dc }, 'Provision aborted post-create — terminating pod');
        void markPodDead({
          podId,
          podKind: kind,
          userId: sessionId,
          dc,
          lifetimeMs: Date.now() - attemptStart,
          reason: 'manual',
          note: 'aborted post_create',
        });
        terminatePod(podId).catch((e) =>
          log.warn({ podId, err: (e as Error).message }, 'Failed to terminate aborted pod'),
        );
        throw new ProvisionAbortedError(podId, 'post_create');
      }

      try {
        // 3. Wait for container to boot. Dominated by image pull.
        await opts.onProvisionPhase?.('fetching_image', podId);
        currentState = 'fetching_image';
        await Sentry.startSpan(
          { name: 'pod.fetching_image', op: 'pod.fetching_image', attributes: { podId, kind, dc: dc ?? 'unknown', attempt } },
          () => waitForRuntime(podId as string, { stallMs: cfg.stallMs }),
        );
        phaseTimings.fetching_image_ms = Date.now() - phaseStart;
        phaseStart = Date.now();

        // 4. Poll /health until the server reports ready.
        await opts.onProvisionPhase?.('warming_model', podId);
        currentState = 'warming_model';
        const healthUrl = `https://${podId}-${cfg.port}.proxy.runpod.net/health`;
        const healthResult = await Sentry.startSpan(
          { name: 'pod.warming_model', op: 'pod.warming_model', attributes: { podId, kind, dc: dc ?? 'unknown' } },
          () => waitForHealth(podId as string, healthUrl),
        );
        phaseTimings.warming_model_ms = Date.now() - phaseStart;
        // Merge per-substage warmup timings reported by the FLUX server's
        // /health response. Keys: from_pretrained_ms, nvfp4_load_ms,
        // to_cuda_ms, warmup_inference_ms. Lets us see which substage
        // dominates the warming_model phase in PostHog.
        for (const [k, v] of Object.entries(healthResult.phaseTimingsMs)) {
          if (typeof v === 'number') phaseTimings[k] = v;
        }

        const totalMs = Date.now() - t0;
        const podUrl = `wss://${podId}-${cfg.port}.proxy.runpod.net/ws`;

        // Checkpoint #3: pod is healthy but we haven't stamped it yet. If
        // the caller aborted during waitForRuntime/waitForHealth, terminate
        // here instead of stamping a row that abortSession just deleted.
        if (opts.signal?.aborted) {
          log.info(
            { sessionId, kind, podId, dc, totalMs },
            'Provision aborted post-health — terminating pod before stamp',
          );
          void markPodDead({
            podId,
            podKind: kind,
            userId: sessionId,
            dc,
            lifetimeMs: totalMs,
            reason: 'manual',
            note: 'aborted post_health',
          });
          terminatePod(podId).catch((e) =>
            log.warn({ podId, err: (e as Error).message }, 'Failed to terminate aborted pod'),
          );
          throw new ProvisionAbortedError(podId, 'post_health');
        }

        // 5. Stamp the row with the kind-appropriate fields. Image:
        // {podId, podUrl, podType}; video: {videoPodId}.
        await cfg.stampRow(sessionId, { podId, podUrl, podType });

        log.info(
          { sessionId, kind, podId, podUrl, podType, totalMs, attempt, dc },
          'Pod serving — awaiting relay',
        );
        // Evaluate volume drift BEFORE emitting the event so volume_status
        // lands on pod.provision.completed in PostHog. Side effects (log +
        // Sentry) fire inside checkVersionDrift; we just forward the
        // returned status. Provision still succeeds regardless — this is
        // observability, not a gate.
        //
        // Both kinds: sync-flux-app stamps one .version.json into the volume
        // for the whole model-servers/ tree (image/server.py + video/server.py),
        // so a stale volume affects both pod kinds equally and we want
        // drift detection on both.
        const volumeStatus = checkVersionDrift(
          healthResult.appVersion,
          { sessionId, podId, dc },
        );
        trackPodProvisionCompleted({
          userId: sessionId,
          durationMs: Date.now() - attemptStart,
          dc,
          podType,
          attempt,
          phaseTimings,
          metadata: { ...healthResult.appVersion, volume_status: volumeStatus, kind },
        });
        return { podId, podUrl, podType, dc };
      } catch (err) {
        // Pod was created but a later step failed — clean up.
        log.warn(
          { sessionId, kind, podId, err: (err as Error).message, state: currentState, attempt },
          'Provision failed after pod creation — terminating pod',
        );
        // PodBootStallError signals "ran out of waitForRuntime/waitForHealth
        // budget" — the pod was alive but never reached ready. Tagged
        // separately from generic provision_error so triage can distinguish
        // "boot took forever" from "boot pipeline blew up." The recoverable-
        // error helper above re-emits the captureException for alerting.
        const reason = err instanceof PodBootStallError ? 'boot_stalled' : 'provision_error';
        void markPodDead({
          podId,
          podKind: kind,
          userId: sessionId,
          dc,
          lifetimeMs: Date.now() - attemptStart,
          reason,
          note: `state=${currentState} ${(err as Error).message}`,
        });
        terminatePod(podId).catch((e) =>
          log.warn({ podId, err: (e as Error).message }, 'Failed to terminate pod after provision failure'),
        );
        throw err;
      }
    } catch (err) {
      // Recoverable classes (PodBootStallError, PodVanishedError) come from
      // a flaky DC. The helper emits observability + decides whether we
      // have rerolls left; on retry, blacklist the DC and loop.
      const recovery = handleRecoverableProvisionError(err as Error, {
        sessionId,
        dc,
        podType,
        attempt,
        maxRerolls,
      });
      if (recovery.decision === 'retry') {
        if (recovery.errDc) blacklistedDcs.add(recovery.errDc);
        continue;
      }
      // Terminal: classify, fire analytics, propagate.
      const category = classifyProvisionError(err as Error);
      Sentry.captureException(err, {
        user: { id: sessionId },
        tags: {
          dc: dc ?? 'unknown',
          podType: podType ?? 'unknown',
          state: currentState,
          attempt: String(attempt),
          category,
          kind,
        },
        contexts: {
          pod: { id: podId ?? 'none', sessionId, elapsedSec: Math.round((Date.now() - t0) / 1000) },
        },
      });
      trackPodProvisionFailed({
        userId: sessionId,
        durationMs: Date.now() - attemptStart,
        category,
        dc,
        state: currentState,
        attempt,
      });
      throw err;
    }
  }

  // Unreachable: loop body either returns or throws.
  throw new Error('_runProvisionLoop: reroll loop exited without resolution');
}

/**
 * Polls the RunPod API until the pod's `runtime` field is non-null, meaning
 * the container image has been pulled and the container process is running.
 * Caller emits state transitions (fetching_image → warming_model); this just
 * blocks until pod.runtime appears or the watchdog fires.
 *
 * If `stallMs` is finite and `pod.runtime` stays null longer than that,
 * throws `PodBootStallError` so the caller can reroll onto a different DC
 * instead of waiting out the full `timeoutMs`. Pass `Infinity` to disable
 * the watchdog and preserve the legacy binary-timeout behavior.
 */
async function waitForRuntime(
  podId: string,
  opts: { timeoutMs?: number; stallMs?: number } = {},
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 10 * 60 * 1000;
  const stallMs = opts.stallMs
    ?? (config.POD_BOOT_WATCHDOG_ENABLED ? config.POD_BOOT_STALL_MS : Infinity);
  const start = Date.now();
  const deadline = start + timeoutMs;
  let lastLogAt = 0;
  let lastDc: string | null = null;
  while (Date.now() < deadline) {
    const pod = await getPod(podId);
    if (!pod) {
      const elapsed = Math.round((Date.now() - start) / 1000);
      log.warn({ podId, elapsedSec: elapsed, dc: lastDc }, 'Pod vanished during fetching_image (spot preempted?)');
      throw new PodVanishedError(podId, lastDc, 'fetching_image', elapsed);
    }
    if (pod.machine?.dataCenterId) lastDc = pod.machine.dataCenterId;
    if (pod.runtime) {
      log.info({ podId, uptimeInSeconds: pod.runtime.uptimeInSeconds }, 'Container runtime up');
      return;
    }
    const elapsedMs = Date.now() - start;
    if (elapsedMs > stallMs) {
      throw new PodBootStallError(podId, lastDc, Math.round(elapsedMs / 1000));
    }
    // Log periodically so backend observers can see long pulls; iOS gets
    // per-state elapsed via stateEnteredAt and doesn't need push updates here.
    const now = Date.now();
    if (now - lastLogAt > 30_000) {
      const elapsed = Math.round(elapsedMs / 1000);
      log.info({ podId, elapsedSec: elapsed, dc: lastDc }, 'Still waiting for container runtime');
      lastLogAt = now;
    }
    await sleep(5000);
  }
  throw new Error(`Pod ${podId} runtime never appeared within ${Math.round(timeoutMs / 1000)}s`);
}

async function waitForHealth(
  podId: string,
  healthUrl: string,
  timeoutMs = 4 * 60 * 1000,
): Promise<{
  phaseTimingsMs: Record<string, number>;
  appVersion: Record<string, string | number | boolean>;
}> {
  const start = Date.now();
  const deadline = start + timeoutMs;
  let lastLogAt = 0;
  let lastPodProbeAt = 0;
  let lastDc: string | null = null;
  // Track the last-seen runtime uptime so we can detect crashlooping pods.
  // If the container has been continuously alive since `lastSeenAt`, current
  // uptime should be ≥ `lastSeenUptime + (now - lastSeenAt)`. A materially
  // smaller value means the container restarted between probes — which the
  // simpler `uptime < prevUptime` check misses for fast crashloops where the
  // restart happens to land between probe samples.
  let lastSeenUptime: number | null = null;
  let lastSeenAt: number | null = null;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(healthUrl, { signal: AbortSignal.timeout(10_000) });
      if (res.ok) {
        const body = (await res.json()) as {
          status?: string;
          phase_timings_ms?: Record<string, number>;
          app_version?: Record<string, string | number | boolean>;
        };
        if (body.status === 'ok') {
          return {
            phaseTimingsMs: body.phase_timings_ms ?? {},
            appVersion: body.app_version ?? {},
          };
        }
      }
    } catch {
      // Ignore — health check hasn't come up yet
    }
    const now = Date.now();
    // Probe RunPod every 30s to detect a vanished or crashlooping pod. Fail
    // fast instead of waiting out the full timeoutMs polling a dead URL.
    if (now - lastPodProbeAt > 30_000) {
      const pod = await getPod(podId);
      if (!pod) {
        const elapsed = Math.round((now - start) / 1000);
        log.warn({ podId, elapsedSec: elapsed, dc: lastDc }, 'Pod vanished during warming_model (spot preempted?)');
        throw new PodVanishedError(podId, lastDc, 'warming_model', elapsed);
      }
      if (pod.machine?.dataCenterId) lastDc = pod.machine.dataCenterId;
      const uptime = pod.runtime?.uptimeInSeconds ?? null;
      if (uptime !== null && lastSeenUptime !== null && lastSeenAt !== null) {
        const expectedUptime = lastSeenUptime + (now - lastSeenAt) / 1000;
        if (uptime < expectedUptime - 5) {
          const elapsed = Math.round((now - start) / 1000);
          log.warn(
            {
              podId,
              lastSeenUptime,
              currentUptime: uptime,
              expectedUptime: Math.round(expectedUptime),
              elapsedSec: elapsed,
              dc: lastDc,
            },
            'Pod runtime uptime did not advance as expected — likely crashlooping',
          );
          throw new PodBootStallError(podId, lastDc, elapsed);
        }
      }
      if (uptime !== null) {
        lastSeenUptime = uptime;
        lastSeenAt = now;
      }
      lastPodProbeAt = now;
    }
    if (now - lastLogAt > 30_000) {
      const elapsed = Math.round((now - start) / 1000);
      log.info({ healthUrl, elapsedSec: elapsed }, 'Still waiting for health check');
      lastLogAt = now;
    }
    await sleep(10_000);
  }
  // Treat health-check timeout as a stall — same remediation as a runtime
  // stall (reroll DC). Throwing a generic Error here would fall through
  // `handleRecoverableProvisionError` to `decision: 'abort'` with no reroll.
  const elapsed = Math.round((Date.now() - start) / 1000);
  log.warn(
    { podId, healthUrl, elapsedSec: elapsed, dc: lastDc },
    'Health check never reached 200 within timeout — declaring pod stalled',
  );
  throw new PodBootStallError(podId, lastDc, elapsed);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}


// ─── P1 reuse helpers ─────────────────────────────────────────────────────────
// Thin wrappers so orchestrator's entry points can probe a reusable pod from a
// session row without importing the whole POD_CONFIGS table — keeps POD_CONFIGS
// private to this module.
export const getReusableImagePod = (row: RedisSession) =>
  POD_CONFIGS.image.getReusableFromRow(row);
export const getReusableVideoPod = (row: RedisSession) =>
  POD_CONFIGS.video.getReusableFromRow(row);

