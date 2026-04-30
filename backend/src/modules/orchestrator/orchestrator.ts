/**
 * Per-session pod lifecycle orchestration.
 *
 * Responsibilities (all in this one file because they share state and are
 * tightly coupled — separating would just spread the reader's attention across
 * imports):
 *   - Registry: Map<sessionId, Session>
 *   - Provisioner: create pod → wait for runtime → poll health
 *   - Reaper: terminate pods idle > 30 min
 *   - Reconcile: on boot, kill orphaned `kiki-session-*` pods from prior runs
 *   - Semaphore: cap concurrent provisions to prevent rate-limit + burst OOM
 *
 * ─── Pod Lifecycle Edge Cases ────────────────────────────────────────────
 *
 * Every scenario below MUST be handled. If you change provisioning, replacement,
 * or session logic, verify each case still works. Add new rows as we discover them.
 *
 * ┌─────────────────────────────────────┬──────────────────────────────────────────────────┬──────────────────────────────┐
 * │ Scenario                            │ What happens                                     │ Handling                     │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 1. Spot pod preempted (disappears)  │ Upstream WS closes with code 1006/1012.          │ stream.ts relay.onClose      │
 * │                                     │ RunPod deletes pod entirely.                     │ tries same-pod reconnect     │
 * │                                     │                                                  │ (fails fast — pod is gone),  │
 * │                                     │                                                  │ falls through to             │
 * │                                     │                                                  │ replaceSession which emits   │
 * │                                     │                                                  │ finding_gpu and provisions a │
 * │                                     │                                                  │ fresh pod.                   │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 2. Pod vanishes during provisioning │ Pod created on RunPod but disappears before      │ waitForRuntime / waitForHealth│
 * │    (spot preempted before serving)  │ becoming serve-ready. getPod() returns null.      │ throw PodVanishedError;       │
 * │                                     │                                                  │ provision()'s reroll loop     │
 * │                                     │                                                  │ blacklists the DC and retries.│
 * │                                     │                                                  │ Only after rerolls exhausted  │
 * │                                     │                                                  │ does abortSession fire.       │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 3. Pod errors during provisioning   │ Container pulls but the app crashes on startup   │ waitForHealth polls /health  │
 * │    (e.g. Python import error,       │ — /health never reaches 200, or supervisord       │ AND tracks runtime uptime    │
 * │    crashlooping container)          │ restarts the container repeatedly (uptime resets  │ across probes; uptime         │
 * │                                     │ every probe).                                    │ regression OR 4-min timeout  │
 * │                                     │                                                  │ both throw                    │
 * │                                     │                                                  │ PodBootStallError → reroll.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 4. User idle >30min on gallery      │ No WS connection → no touch() calls.             │ Reaper scans every 60s,      │
 * │                                     │ lastActivityAt goes stale.                       │ terminates pod if idle >30min.│
 * │                                     │                                                  │ Redis session deleted. Next   │
 * │                                     │                                                  │ startStream() provisions     │
 * │                                     │                                                  │ fresh.                       │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 5. User idle >30min on canvas       │ WS stays open but no frames sent (canvas         │ Same as #4 — touch() only    │
 * │    (not drawing)                    │ unchanged). No touch() calls from relay.          │ fires on relayed messages.   │
 * │                                     │                                                  │ Pod reaped. Next stroke →    │
 * │                                     │                                                  │ frame send fails → iOS       │
 * │                                     │                                                  │ reconnects → provisions new. │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 6. Railway redeploy during          │ Backend process dies. In-memory                  │ New process boots → reconcile │
 * │    provisioning                     │ inFlightProvisions map lost. Pod may still be    │ adopts or terminates orphans. │
 * │                                     │ provisioning on RunPod.                          │ iOS reconnects → session in  │
 * │                                     │                                                  │ any non-ready state without  │
 * │                                     │                                                  │ an in-flight promise is      │
 * │                                     │                                                  │ stale → deleted, fresh       │
 * │                                     │                                                  │ provision starts.            │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 7. iOS reconnect during replacement │ replaceSession is live; inFlightProvisions has  │ getOrProvisionPod sees the    │
 * │    (duplicate pod race)             │ the replacement promise.                         │ in-flight promise → joins    │
 * │                                     │                                                  │ it. Broker subscribe seeds   │
 * │                                     │                                                  │ joiner with current state.   │
 * │                                     │                                                  │ No duplicate pod created.    │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 8. Network glitch during drawing    │ WS momentarily drops. iOS receive loop ends      │ iOS attemptReconnect (3x     │
 * │                                     │ unexpectedly.                                    │ with exponential backoff).   │
 * │                                     │                                                  │ Backend pod stays alive      │
 * │                                     │                                                  │ (sessionClosed keeps it for  │
 * │                                     │                                                  │ reconnect within 30min).     │
 * │                                     │                                                  │ Reconnect reuses ready pod.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 9. App backgrounded then resumed    │ iOS stopStream() on background, restarts on      │ Pod stays alive up to 30min  │
 * │                                     │ foreground if streamWasActiveBeforeBackground.   │ (idle reaper). If resumed    │
 * │                                     │                                                  │ within window, reuses pod.   │
 * │                                     │                                                  │ If >30min, fresh provision.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 10. Pod boot stalls on a bad host   │ Pod created but runtime stays null. NFS mount    │ waitForRuntime throws        │
 * │     (stock image pull on fresh      │ delay or stock-image pull on a cold host —       │ PodBootStallError after      │
 * │     host, NFS mount hang).          │ pod.runtime stays null.                          │ POD_BOOT_STALL_MS (default   │
 * │                                     │                                                  │ 45s). provision() terminates │
 * │                                     │                                                  │ pod, blacklists the DC, and  │
 * │                                     │                                                  │ rerolls up to                │
 * │                                     │                                                  │ POD_BOOT_MAX_REROLLS.        │
 * │                                     │                                                  │ Sentry captures each stall.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 11. User signs out mid-provision    │ /v1/auth/signout fires while _runProvisionLoop is │ abortSession aborts the     │
 * │     (Round 6 leak fix)              │ creating a pod. Without cancellation, the loop   │ AbortController on each      │
 * │                                     │ would continue, stamp the row, and leak the pod  │ inFlightProvisions entry and │
 * │                                     │ until reconcile.                                 │ awaits settlement; the loop  │
 * │                                     │                                                  │ checks signal at 3 points    │
 * │                                     │                                                  │ (pre-create / post-create / │
 * │                                     │                                                  │ pre-stamp) and terminates    │
 * │                                     │                                                  │ any pod-in-flight inline.    │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 12. Pod terminated externally       │ Spot preemption, host failure, manual            │ Image kind's                 │
 * │     (Redis row points to dead pod)  │ termination — orchestrator never observes the    │ getReusableFromRow probes    │
 * │                                     │ kill, so the session row keeps claiming          │ RunPod (getPod) before       │
 * │                                     │ state=ready with the dead podId. Reconnect would │ trusting the row. Pod gone → │
 * │                                     │ reuse blindly and 404 on the WS upgrade.         │ returns null → existing      │
 * │                                     │                                                  │ deleteSession + fresh        │
 * │                                     │                                                  │ provision path runs.         │
 * └─────────────────────────────────────┴──────────────────────────────────────────────────┴──────────────────────────────┘
 */

import { readFileSync } from 'node:fs';
import type { FastifyBaseLogger } from 'fastify';
import * as Sentry from '@sentry/node';

import { config } from '../../config/index.js';
import { getRedis, ensureRedis, setLogger as setRedisLogger } from '../redis/client.js';
import {
  createOnDemandPod,
  createSpotPod,
  getPod,
  getSpotBid,
  isCapacityError,
  listPodsByPrefix,
  terminatePod,
  type SpotBidInfo,
} from './runpodClient.js';
import { getPolicy } from './policy.js';
import { notifyPodCreated, notifyPodProgress, notifyPodTerminated } from './costMonitor.js';
import { PodBootStallError, PodVanishedError, ProvisionAbortedError, classifyProvisionError, type FailureCategory } from './errorClassification.js';
import {
  trackPodProvisionStarted,
  trackPodProvisionCompleted,
  trackPodProvisionFailed,
  trackPodProvisionStalled,
  trackPodProvisionVanished,
  trackPodReplacementExhausted,
  trackPodStateEntered,
  trackPodTerminated,
} from '../analytics/index.js';

export { PodBootStallError } from './errorClassification.js';

// ────────────────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────────────────

/**
 * Single flat state enum for a session's provisioning lifecycle. Replaces the
 * old `SessionStatus` + internal `ProvisionPhase` duo. iOS maps state codes to
 * display text; backend only tracks structured state.
 *
 * Active (in-progress) states: 'queued' through 'warming_model'.
 * Terminal states: 'ready' (pod serving), 'failed', 'terminated'.
 */
export type State =
  | 'queued'          // semaphore-held (too many concurrent provisions in process)
  | 'finding_gpu'     // selectPlacement: probing DCs for spot stock
  | 'creating_pod'    // createSpotPod / createOnDemandPod RPC
  | 'fetching_image'  // pod exists; waiting for pod.runtime (GHCR image pull)
  | 'warming_model'   // container running; polling /health while model loads
  | 'connecting'      // pod /health ok; backend wiring the iOS↔pod frame relay
  | 'ready'           // relay live; iOS can stream
  | 'failed'          // unrecoverable error; WS closes after
  | 'terminated';     // session ended (reaped / aborted / replaced out)

const ACTIVE_PROVISION_STATES: readonly State[] = [
  'queued', 'finding_gpu', 'creating_pod', 'fetching_image', 'warming_model', 'connecting',
] as const;

export function isActiveProvisioning(state: State): boolean {
  return (ACTIVE_PROVISION_STATES as readonly string[]).includes(state);
}

export type PodType = 'spot' | 'onDemand';

// ────────────────────────────────────────────────────────────────────────────
// Module-scoped state
// ────────────────────────────────────────────────────────────────────────────

// Session registry lives in Redis (WS5). Local map only holds in-flight
// provision promises for same-process join (Promises can't be serialized).
// Keyed by `${kind}:${sessionId}` so image and video pods don't collide.
// Each entry pairs the rich-shape promise with an AbortController so
// `abortSession` can cancel the provision mid-flight (otherwise a signout
// during provisioning leaks the just-created pod — see Round 6 plan).
type InFlightEntry = {
  promise: Promise<{ podId: string; podUrl: string; podType: PodType; dc: string | null }>;
  controller: AbortController;
};
const inFlightProvisions = new Map<string, InFlightEntry>();

const SESSION_PREFIX = 'session:';
const POD_PREFIX = 'kiki-session-';
const IDLE_GRACE_SECONDS = 300; // 5 min grace on top of idle timeout for Redis TTL
const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
// Headroom above the current spot floor. Larger headroom = fewer outbids =
// fewer needless fallbacks to on-demand. 0.05 costs ~$0.03/hr more than the
// 0.02 default on a typical bid, cheaper than one on-demand fallback.
const BID_HEADROOM = 0.05;

// ─── Pod boot configuration ─────────────────────────────────────────────
// We launch pods from stock `runpod/pytorch` and bootstrap the FLUX server
// from files on the attached network volume. See scripts/sync-flux-app.ts
// for how the volume gets populated, and documents/decisions.md entry
// 2026-04-23 for the full context + rollback procedure.
const BASE_IMAGE = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';

// SSH bootstrap: RunPod's stock `runpod/pytorch` image normally writes
// $PUBLIC_KEY → /root/.ssh/authorized_keys and starts sshd via its entrypoint
// script. We override the entrypoint with BOOT_DOCKER_ARGS, so that script
// never runs. Replicate it inline before exec'ing the server, gated by
// PUBLIC_KEY so the bootstrap is a no-op when the env var is unset (prod).
//
// One-time use: pre-launch dev iteration. Lets us scp updated files into
// /workspace/app + restart uvicorn instead of waiting 8–10 min per
// sync-all-dcs deploy. Remove PUBLIC_KEY from Railway env (not the code) to
// re-disable SSH on all subsequently-spawned pods. Existing pods retain
// whichever path was active when they booted; terminate them to refresh.
//
// `ssh-keygen -A` generates any missing /etc/ssh/ssh_host_*_key files
// (rsa/ecdsa/ed25519). Without those, sshd silently exits. We also try
// `service ssh start` first (mirrors RunPod's own start.sh), with a fallback
// to `/usr/sbin/sshd` for images that don't ship sysv init scripts. All
// output captured to /tmp/ssh-bootstrap.log so we can post-mortem inspect
// without needing SSH itself to debug why SSH didn't start.
const SSH_BOOTSTRAP =
  'if [ -n "$PUBLIC_KEY" ]; then ' +
  '{ ' +
  'echo "ssh bootstrap start at $(date -u +%FT%TZ)"; ' +
  'mkdir -p /root/.ssh && ' +
  'echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys && ' +
  'chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && ' +
  'echo "wrote authorized_keys"; ' +
  'ssh-keygen -A && echo "host keys generated"; ' +
  'if service ssh start; then echo "service ssh start ok"; ' +
  'else echo "service ssh start failed; trying /usr/sbin/sshd"; /usr/sbin/sshd && echo "/usr/sbin/sshd ok"; ' +
  'fi; ' +
  'echo "ssh bootstrap done at $(date -u +%FT%TZ)"; ' +
  '} > /tmp/ssh-bootstrap.log 2>&1 || true; ' +
  'fi';

// `bash -lc` sources /etc/profile.d/* for CUDA paths; activate the volume venv
// (inherits base-image torch via --system-site-packages).
//
// Server-launch path is conditional on PUBLIC_KEY:
//   - prod (PUBLIC_KEY unset): `exec python3` — python becomes PID 1, SIGTERM
//     reaches uvicorn directly for clean orchestrator-initiated termination.
//   - dev  (PUBLIC_KEY set):   respawn loop — bash stays as PID 1 and respawns
//     the python child if it exits. Lets us `pkill -f python3` over SSH to
//     pick up scp'd code changes without restarting the container (which
//     trips the orchestrator's crashloop reaper). Container termination still
//     works because docker stop → SIGTERM bash → 10s grace → SIGKILL.
//
// Built as separate constants to keep the prod path bit-identical to the
// previous BOOT_DOCKER_ARGS — a leaked PUBLIC_KEY env still flips to dev mode
// but anything else is unchanged.
const SERVER_LAUNCH = (script: string): string =>
  'if [ -n "$PUBLIC_KEY" ]; then ' +
  `while true; do python3 -u ${script}; sleep 2; done; ` +
  'else ' +
  `exec python3 -u ${script}; ` +
  'fi';

const BOOT_DOCKER_ARGS =
  `bash -lc '${SSH_BOOTSTRAP}; source /workspace/venv/bin/activate && cd /workspace/app && ${SERVER_LAUNCH('server.py')}'`;
// Video pod runs LTXV i2v on a separate pod (see flux-klein-server/video_server.py).
// Same volume / venv / port as the image pod — only the entry script differs.
const BOOT_DOCKER_ARGS_VIDEO =
  `bash -lc '${SSH_BOOTSTRAP}; source /workspace/venv/bin/activate && cd /workspace/app && ${SERVER_LAUNCH('video_server.py')}'`;
// Pod name prefix for video pods. Distinct from POD_PREFIX so reconcile
// can list them separately and so RunPod console / Discord alerts are
// unambiguous about which kind died.
const VIDEO_POD_PREFIX = 'kiki-vsession-';
const BOOT_ENV: Array<{ key: string; value: string }> = [
  { key: 'HF_HOME', value: '/workspace/huggingface' },
  { key: 'HF_HUB_OFFLINE', value: '1' },
  { key: 'FLUX_HOST', value: '0.0.0.0' },
  { key: 'FLUX_PORT', value: '8766' },
  { key: 'FLUX_USE_NVFP4', value: '1' },
  // Lets PyTorch grow a single CUDA memory segment instead of failing on
  // fragmentation. Required for the LTX-2.3 video pod: fp8_cast's per-
  // matmul bf16 upcast buffers churn the caching allocator, leading to
  // OOM on H100 80GB even at small resolutions when allocator fragments.
  // Strict improvement (or no-op) for image pod's FLUX path too.
  // Recommended by the OOM error message itself.
  { key: 'PYTORCH_CUDA_ALLOC_CONF', value: 'expandable_segments:True' },
  // Step P2 (perf plan, post-first-trace) — torch.compile experiment.
  // DISABLED 2026-04-30 after pods crashlooped: the wrap call's
  // try/except in video_pipeline.py:load() only catches errors from
  // torch.compile() itself, but the actual graph tracing/lowering is
  // LAZY and fires on the first transformer(...) call inside warmup's
  // _run_inference(). When that lowering raised, the exception bubbled
  // out of load(), the pod stayed not-ready, and the orchestrator's
  // health-based reaper rerolled it — infinite loop. The right fix is
  // to wrap the warmup inference itself with a fallback-to-eager path,
  // not just the wrap call. Until that defensive change ships, leave
  // compile off so we don't re-trigger the crashloop.
  { key: 'LTX_TORCH_COMPILE', value: '0' },
];

// Forward orchestrator's PUBLIC_KEY env (set in Railway) to the pod so the
// SSH_BOOTSTRAP block above can write authorized_keys. Conditional so prod
// (no PUBLIC_KEY set) gets no SSH access by default.
if (process.env['PUBLIC_KEY']) {
  BOOT_ENV.push({ key: 'PUBLIC_KEY', value: process.env['PUBLIC_KEY'] });
}

const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const REAPER_INTERVAL_MS = 60 * 1000;
const MAX_CONCURRENT_PROVISIONS = Number(process.env['MAX_CONCURRENT_PROVISIONS'] ?? 5);

// Drift check uses the git tree-hash of `flux-klein-server/` — the subtree
// that sync-flux-app actually rsyncs to volumes. This changes only when files
// in that path change, so doc/iOS/backend commits don't false-trigger drift
// (which was the problem with the prior commit-SHA-based check). Written by
// `npm run deploy` (`git rev-parse HEAD:flux-klein-server > .flux-app-version`)
// and baked into the Docker image via the Dockerfile's `COPY . .`. Empty
// string = file missing; drift check no-ops.
const BACKEND_FLUX_APP_VERSION = (() => {
  try {
    return readFileSync('/app/.flux-app-version', 'utf-8').trim();
  } catch {
    return '';
  }
})();

// Backend's commit SHA — kept for forensic context only (logged at startup,
// not used for drift comparison). Same fallback chain as before.
const BACKEND_GIT_SHA = (() => {
  const fromEnv = process.env['RAILWAY_GIT_COMMIT_SHA'];
  if (fromEnv) return fromEnv.trim();
  try {
    return readFileSync('/app/.git-sha', 'utf-8').trim();
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

export type PodKind = 'image' | 'video';

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
   *  cleaner than spot complexity at our scale). */
  createPodForDc: (
    target: PlacementTarget,
    sessionId: string,
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

// Semaphore state
let activeProvisions = 0;
const semaphoreWaiters: Array<() => void> = [];

// Logger injected by start()
let log: FastifyBaseLogger = console as unknown as FastifyBaseLogger;

// ────────────────────────────────────────────────────────────────────────────
// Redis session helpers
// ────────────────────────────────────────────────────────────────────────────

interface RedisSession {
  sessionId: string;
  podId: string | null;
  podUrl: string | null;
  podType: PodType | null;
  state: State;
  stateEnteredAt: number;       // ms epoch — updated on every state transition
  failureCategory: FailureCategory | null;  // only non-null when state === 'failed'
  createdAt: number;
  lastActivityAt: number;
  replacementCount: number;
  // Best-effort video pod tracking. Stamped by POD_CONFIGS.video.stampRow
  // on successful provision; cleared by clearVideoPod() on relay-wire
  // failure or replacement. The image pod can serve without this — it
  // exists only to (a) drive reconcile so we don't orphan video pods
  // after crashes, and (b) let the reaper terminate both pods together.
  videoPodId: string | null;
}

const IDLE_TTL_SECONDS = Math.ceil(IDLE_TIMEOUT_MS / 1000) + IDLE_GRACE_SECONDS;

function sessionKey(sessionId: string): string {
  return `${SESSION_PREFIX}${sessionId}`;
}

async function readSession(sessionId: string): Promise<RedisSession | null> {
  const data = await getRedis().hgetall(sessionKey(sessionId));
  if (!data || !data['sessionId']) return null;
  const rawState = data['state'];
  // Guard against legacy rows written by the pre-refactor backend (`status` field).
  // Reconcile / reaper will clean these up; meanwhile treat them as non-existent.
  if (!rawState) return null;
  return {
    sessionId: data['sessionId']!,
    podId: data['podId'] || null,
    podUrl: data['podUrl'] || null,
    podType: (data['podType'] as PodType) || null,
    state: rawState as State,
    stateEnteredAt: Number(data['stateEnteredAt'] ?? 0),
    failureCategory: (data['failureCategory'] as FailureCategory) || null,
    createdAt: Number(data['createdAt'] ?? 0),
    lastActivityAt: Number(data['lastActivityAt'] ?? 0),
    replacementCount: Number(data['replacementCount'] ?? 0),
    videoPodId: data['videoPodId'] || null,
  };
}

async function writeSession(session: RedisSession): Promise<void> {
  const key = sessionKey(session.sessionId);
  const fields: Record<string, string> = {
    sessionId: session.sessionId,
    state: session.state,
    stateEnteredAt: String(session.stateEnteredAt),
    createdAt: String(session.createdAt),
    lastActivityAt: String(session.lastActivityAt),
  };
  if (session.podId) fields['podId'] = session.podId;
  if (session.podUrl) fields['podUrl'] = session.podUrl;
  if (session.podType) fields['podType'] = session.podType;
  if (session.failureCategory) fields['failureCategory'] = session.failureCategory;
  if (session.replacementCount > 0) fields['replacementCount'] = String(session.replacementCount);
  await getRedis().multi()
    .hset(key, fields)
    .expire(key, IDLE_TTL_SECONDS)
    .exec();
}

/**
 * Partial update — only writes the fields in `patch`, refreshes TTL.
 * Safer than `writeSession` for transitions because it never risks clobbering
 * a field the caller didn't intend to set.
 */
async function patchSession(
  sessionId: string,
  patch: Partial<Pick<
    RedisSession,
    'state' | 'stateEnteredAt' | 'failureCategory' | 'podId' | 'podUrl' | 'podType' | 'lastActivityAt' | 'replacementCount' | 'videoPodId'
  >>,
): Promise<void> {
  const key = sessionKey(sessionId);
  const fields: Record<string, string> = {};
  if (patch.state !== undefined) fields['state'] = patch.state;
  if (patch.stateEnteredAt !== undefined) fields['stateEnteredAt'] = String(patch.stateEnteredAt);
  if (patch.failureCategory !== undefined) fields['failureCategory'] = patch.failureCategory ?? '';
  if (patch.podId !== undefined) fields['podId'] = patch.podId ?? '';
  if (patch.podUrl !== undefined) fields['podUrl'] = patch.podUrl ?? '';
  if (patch.podType !== undefined) fields['podType'] = patch.podType ?? '';
  if (patch.lastActivityAt !== undefined) fields['lastActivityAt'] = String(patch.lastActivityAt);
  if (patch.replacementCount !== undefined) fields['replacementCount'] = String(patch.replacementCount);
  if (patch.videoPodId !== undefined) fields['videoPodId'] = patch.videoPodId ?? '';
  if (Object.keys(fields).length === 0) return;
  await getRedis().multi()
    .hset(key, fields)
    .expire(key, IDLE_TTL_SECONDS)
    .exec();
}

async function deleteSession(sessionId: string): Promise<void> {
  await getRedis().del(sessionKey(sessionId));
}

// ────────────────────────────────────────────────────────────────────────────
// Broker — per-process fan-out of state transitions to WS subscribers
// ────────────────────────────────────────────────────────────────────────────
//
// Redis is the source of truth for session state (durable, survives deploys).
// The broker is just the efficient-push layer: when a provision transitions
// from one state to the next, every iOS WS currently subscribed to that
// sessionId gets the event in real time. No in-memory state cache — on
// subscribe, the handler is seeded with the current Redis state so joiners
// see whatever phase is active right now, then receives every future emit.

export interface StateEvent {
  state: State;
  stateEnteredAt: number;
  /// Ms epoch when this warm-up cycle began (= session.createdAt). Stable
  /// across all state transitions so a reconnecting client can resume the
  /// progress bar instead of restarting from zero.
  warmingStartedAt: number;
  replacementCount: number;
  failureCategory: FailureCategory | null;
  /** Real error message from the failure source. Populated only on
   * `state === 'failed'`. Client renders it directly — no client-side
   * category-to-string mapping that fabricates a cause. */
  message?: string;
}

type StateHandler = (event: StateEvent) => void;

const subscribers = new Map<string, Set<StateHandler>>();

/**
 * Subscribe a handler to a session's state events. Immediately invokes the
 * handler with the current Redis state (if any) so joiners see their current
 * phase synchronously. Returns an unsubscribe function — call it when the
 * client disconnects or the provision settles.
 */
export async function subscribe(
  sessionId: string,
  handler: StateHandler,
): Promise<() => void> {
  const existing = subscribers.get(sessionId);
  const set = existing ?? new Set<StateHandler>();
  set.add(handler);
  if (!existing) subscribers.set(sessionId, set);

  // Seed with current state (if session exists) so joiner sees where we are.
  const session = await readSession(sessionId);
  log.info(
    {
      sessionId,
      seeded: !!session,
      seededState: session?.state ?? null,
      stateAgeMs: session?.stateEnteredAt ? Date.now() - session.stateEnteredAt : null,
      subscriberCount: set.size,
      event: 'subscribe_seed',
    },
    'subscribe_seed',
  );
  if (session) {
    handler({
      state: session.state,
      stateEnteredAt: session.stateEnteredAt,
      warmingStartedAt: session.createdAt,
      replacementCount: session.replacementCount,
      failureCategory: session.failureCategory,
    });
  }

  return () => {
    const s = subscribers.get(sessionId);
    if (!s) return;
    s.delete(handler);
    if (s.size === 0) subscribers.delete(sessionId);
  };
}

/**
 * Write a state transition to Redis and fan out to every subscriber.
 * Exported so stream.ts can emit `connecting` / `ready` after the frame
 * relay is wired up (those emits can't happen inside provision() because
 * provision doesn't own the relay).
 */
export async function emitState(
  sessionId: string,
  state: State,
  failureCategory: FailureCategory | null = null,
  message?: string,
): Promise<void> {
  const now = Date.now();

  // Read the *current* (soon-to-be-previous) state so we can attach its
  // duration to the outgoing PostHog event. This turns per-state duration
  // analytics into a one-line query: AVG(previous_state_duration_ms) WHERE
  // previous_state = 'X'. The alternative (post-hoc LEAD() in HogQL) works
  // but costs a self-join on every dashboard.
  const prevSession = await readSession(sessionId);
  const previousState = prevSession?.state ?? null;
  const previousStateDurationMs = prevSession?.stateEnteredAt
    ? now - prevSession.stateEnteredAt
    : null;
  const replacementCount = prevSession?.replacementCount ?? 0;
  const warmingStartedAt = prevSession?.createdAt ?? now;

  await patchSession(sessionId, { state, stateEnteredAt: now, failureCategory });

  const event: StateEvent = {
    state,
    stateEnteredAt: now,
    warmingStartedAt,
    replacementCount,
    failureCategory,
    ...(message !== undefined ? { message } : {}),
  };

  // Fan out to in-process subscribers (iOS WebSocket handlers in stream.ts).
  const subSet = subscribers.get(sessionId);
  const subCount = subSet?.size ?? 0;
  log.info(
    {
      sessionId,
      state,
      previousState,
      subscriberCount: subCount,
      // 0 subscribers ⇒ no iPad will ever see this transition. Critical
      // signal for stuck-on-Connecting diagnoses where the state machine
      // moved but the client never saw it.
      orphaned: subCount === 0,
      event: 'emit_state',
    },
    'emit_state',
  );
  subSet?.forEach((h) => {
    try { h(event); } catch (err) {
      log.warn({ sessionId, err: (err as Error).message }, 'State subscriber threw');
    }
  });

  // Sentry breadcrumb for error-trace context + PostHog event for funnel analytics.
  Sentry.addBreadcrumb({
    category: 'provision',
    level: 'info',
    message: `state → ${state}`,
    data: { sessionId, state, previousState, previousStateDurationMs, replacementCount, failureCategory },
  });
  trackPodStateEntered({
    userId: sessionId,
    state,
    stateEnteredAt: now,
    previousState,
    previousStateDurationMs,
    replacementCount,
    failureCategory,
  });
}

/**
 * Yields every session key in Redis. Wraps the `scanStream` + nested
 * for-await iteration so the three sweep sites (reaper, reconcile pass 1,
 * reconcile pass 2) don't each re-derive the boilerplate.
 */
async function* eachSessionKey(): AsyncIterable<string> {
  const stream = getRedis().scanStream({ match: `${SESSION_PREFIX}*`, count: 100 });
  for await (const keys of stream) {
    for (const key of keys as string[]) {
      yield key;
    }
  }
}

/**
 * Atomically tear down a session: terminate the pod on RunPod (if any), then
 * delete the Redis row. Used from error paths where we've decided the session
 * is unusable — e.g. relay to the pod's `/ws` failed on upgrade, or provision
 * failed mid-way.
 *
 * Never throws. Logs + swallows individual failures so callers on an error
 * path aren't pushed further off the rails.
 */
export async function abortSession(
  sessionId: string,
  reason: 'manual' | 'error' = 'error',
): Promise<void> {
  try {
    // Cancel in-flight provisions FIRST (image and video may both be
    // running concurrently). The signal causes _runProvisionLoop to
    // terminate any just-created pod and reject; awaiting settlement
    // ensures no provision can stamp+leak a pod after we return.
    const settled: Promise<unknown>[] = [];
    for (const kind of ['image', 'video'] as const) {
      const entry = inFlightProvisions.get(`${kind}:${sessionId}`);
      if (entry) {
        log.info({ sessionId, kind, reason }, 'Aborting in-flight provision');
        entry.controller.abort('session aborted');
        settled.push(entry.promise.catch(() => {}));
      }
    }
    if (settled.length > 0) await Promise.all(settled);

    const session = await readSession(sessionId);
    if (session?.podId) {
      const lifetimeMs = session.createdAt > 0 ? Date.now() - session.createdAt : 0;
      trackPodTerminated({ userId: sessionId, reason, lifetimeMs });
      terminatePod(session.podId).catch((err) =>
        log.warn({ sessionId, podId: session.podId, err: (err as Error).message }, 'abortSession: terminatePod failed'),
      );
    }
    if (session?.videoPodId) {
      terminatePod(session.videoPodId).catch((err) =>
        log.warn({ sessionId, videoPodId: session.videoPodId, err: (err as Error).message }, 'abortSession: terminate video pod failed'),
      );
    }
    await deleteSession(sessionId);
  } catch (err) {
    log.warn({ sessionId, err: (err as Error).message }, 'abortSession failed');
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Public API
// ────────────────────────────────────────────────────────────────────────────

/**
 * Returns a healthy pod URL for the given session, provisioning one if needed.
 * If the same sessionId calls this concurrently while a provision is in flight,
 * both calls await the same promise — we don't create two pods.
 *
 * Session state is stored in Redis (survives deploys). In-flight provision
 * promises are kept in a local map for same-process join only. State transitions
 * during provision fan out to the broker; stream.ts subscribes to drive the
 * WebSocket status envelope.
 */
export async function getOrProvisionPod(sessionId: string): Promise<{ podUrl: string }> {
  // 1. Check Redis for existing session
  const existing = await readSession(sessionId);

  const reusable = existing ? await POD_CONFIGS.image.getReusableFromRow(existing) : null;
  if (reusable) {
    log.info({ sessionId, podId: reusable.podId }, 'Reusing existing session pod');
    return { podUrl: reusable.podUrl };
  }

  // 2. Check local in-flight map (same-process concurrent callers — fresh
  // provision OR replacement). Joiners subscribe via broker; here we just
  // await the same promise.
  const key = `image:${sessionId}`;
  const inFlight = inFlightProvisions.get(key);
  if (inFlight) {
    log.info({ sessionId }, 'Joining in-flight provision');
    return inFlight.promise.then((r) => ({ podUrl: r.podUrl }));
  }

  // 3. If Redis has a non-ready session but we don't own the promise
  // (post-restart, different replica, or orphaned), clean up and re-provision.
  if (existing) {
    log.warn({ sessionId, state: existing.state }, 'Stale session in Redis — re-provisioning');
    await deleteSession(sessionId);
  }

  // 4. Fresh provision — claim in Redis + start. Initial state is 'finding_gpu';
  // if we're about to wait on the semaphore we'll flip to 'queued' first.
  const now = Date.now();
  await writeSession({
    sessionId,
    podId: null,
    podUrl: null,
    podType: null,
    state: 'finding_gpu',
    stateEnteredAt: now,
    failureCategory: null,
    createdAt: now,
    lastActivityAt: now,
    replacementCount: 0,
    videoPodId: null,
  });

  let provisionedPodId: string | null = null;

  const controller = new AbortController();
  const promise = (async () => {
    try {
      if (isSemaphoreFull()) await emitState(sessionId, 'queued');
      await acquireSemaphore();
      try {
        await emitState(sessionId, 'finding_gpu');
        const result = await provision(sessionId, controller.signal);
        provisionedPodId = result.podId;
        return { podId: result.podId, podUrl: result.podUrl, podType: result.podType, dc: null };
      } finally {
        releaseSemaphore();
      }
    } catch (err) {
      const elapsedMs = Date.now() - now;
      const category = classifyProvisionError(err as Error);
      log.error({ sessionId, err, category, elapsedMs }, 'Provision failed');
      if (provisionedPodId) {
        notifyPodProgress(provisionedPodId, `❌ **Failed:** ${(err as Error).message}`);
        terminatePod(provisionedPodId).catch((e) =>
          log.warn({ podId: provisionedPodId, err: e }, 'Failed to clean up pod after provision failure'),
        );
      }
      // provision() already emitted state='failed' to subscribers; delete the
      // Redis row now that downstream has been notified.
      await deleteSession(sessionId).catch(() => {});
      throw err;
    } finally {
      inFlightProvisions.delete(key);
    }
  })();

  inFlightProvisions.set(key, { promise, controller });
  return promise.then((r) => ({ podUrl: r.podUrl }));
}

export function touch(sessionId: string): void {
  // Fire-and-forget — don't block frame-relay hot path on Redis round-trip
  const key = sessionKey(sessionId);
  void getRedis().multi()
    .hset(key, 'lastActivityAt', String(Date.now()))
    .expire(key, IDLE_TTL_SECONDS)
    .exec()
    .catch((err) => log.warn({ err: (err as Error).message, sessionId }, 'touch failed'));
}

/**
 * Check if a user already has an active pod — used to skip rate limiting on
 * reconnect. "Active" includes all in-progress states (`queued` through
 * `warming_model`) plus `ready`: a user navigating away and back during cold
 * start is reconnecting to their existing in-flight pod, not creating a new
 * one. Treating this as a fresh provision triggers spurious
 * `too_many_active_pods` rejections.
 */
export async function hasReadySession(sessionId: string): Promise<boolean> {
  const session = await readSession(sessionId);
  if (!session) return false;
  return session.state === 'ready' || isActiveProvisioning(session.state);
}

// ────────────────────────────────────────────────────────────────────────────
// Preemption handling (WS7)
// ────────────────────────────────────────────────────────────────────────────

/**
 * Replace a session's pod after preemption or crash. Holds the existing session
 * key in Redis, provisions a new pod, swaps podId/podUrl atomically.
 *
 * Returns the new podUrl. Throws if replacement fails or retry bound exceeded.
 */
export async function replaceSession(sessionId: string): Promise<{ podUrl: string }> {
  const session = await readSession(sessionId);
  if (!session) throw new Error('No session to replace');

  if (session.replacementCount >= config.MAX_SESSION_REPLACEMENTS) {
    trackPodReplacementExhausted({
      userId: sessionId,
      maxAttempts: config.MAX_SESSION_REPLACEMENTS,
    });
    await deleteSession(sessionId);
    throw new Error(`Replacement limit reached (${config.MAX_SESSION_REPLACEMENTS} attempts)`);
  }

  const oldPodId = session.podId;
  const attempt = session.replacementCount + 1;

  log.info({ sessionId, oldPodId, attempt }, 'Starting session replacement');

  // Bump replacement count + clear old pod info. Then emit finding_gpu so any
  // current broker subscribers see the UI reset from 'ready' → 'finding_gpu'
  // (iOS will prefix "Replacing — " because replacementCount > 0).
  await patchSession(sessionId, {
    podId: null,
    podUrl: null,
    podType: null,
    lastActivityAt: Date.now(),
    replacementCount: attempt,
  });
  await emitState(sessionId, 'finding_gpu');

  // Clean up old pod (fire-and-forget — may already be gone)
  if (oldPodId) {
    terminatePod(oldPodId).catch((e) =>
      log.warn(
        { sessionId, oldPodId, err: (e as Error).message },
        'Failed to terminate old pod during replacement — will be reaped',
      ),
    );
  }

  const t0 = Date.now();
  let newPodId: string | null = null;
  const key = `image:${sessionId}`;
  const controller = new AbortController();
  const replacementPromise = (async () => {
    try {
      if (isSemaphoreFull()) await emitState(sessionId, 'queued');
      await acquireSemaphore();
      try {
        await emitState(sessionId, 'finding_gpu');
        const result = await provision(sessionId, controller.signal);
        newPodId = result.podId;
        const replacementMs = Date.now() - t0;
        log.info({ sessionId, oldPodId, newPodId: result.podId, replacementMs, attempt }, 'Session replaced');
        return { podId: result.podId, podUrl: result.podUrl, podType: result.podType, dc: null };
      } finally {
        releaseSemaphore();
      }
    } catch (err) {
      log.error({ sessionId, attempt, err }, 'Session replacement failed');
      Sentry.captureException(err, {
        tags: { sessionId, attempt: String(attempt), phase: 'session_replacement' },
      });
      if (newPodId) {
        terminatePod(newPodId).catch((e) => {
          log.warn({ sessionId, newPodId, err: (e as Error).message }, 'Failed to clean up replacement pod');
          Sentry.captureException(e, {
            tags: { sessionId, phase: 'replacement_pod_cleanup' },
          });
        });
      }
      await deleteSession(sessionId).catch((delErr) => {
        log.error(
          { sessionId, err: (delErr as Error).message },
          'Failed to delete session after replacement failure',
        );
        Sentry.captureException(delErr, {
          tags: { sessionId, phase: 'replacement_session_cleanup' },
        });
      });
      throw err;
    } finally {
      inFlightProvisions.delete(key);
    }
  })();

  // Register in inFlight so concurrent getOrProvisionPod calls join this
  // replacement instead of starting a duplicate.
  inFlightProvisions.set(key, { promise: replacementPromise, controller });
  return replacementPromise.then((r) => ({ podUrl: r.podUrl }));
}

export function sessionClosed(sessionId: string): void {
  // Don't terminate — user may reconnect. Just log. Reaper handles the timeout.
  log.info(
    { sessionId, idleAfterMs: IDLE_TIMEOUT_MS },
    'Client disconnected; pod stays alive pending reconnect',
  );
}

/**
 * Runs once at backend boot: connect to Redis, reconcile orphan pods, then
 * arm the idle reaper + periodic reconcile sweep.
 */
export async function start(logger: FastifyBaseLogger): Promise<void> {
  log = logger;
  setRedisLogger(logger);
  await ensureRedis();
  // Boot-time reconcile is aggressive (no age gate) — we just restarted so
  // anything not in Redis is genuinely orphaned.
  await reconcileOrphanPods(0);
  setInterval(() => void runReaper(), REAPER_INTERVAL_MS);
  // Periodic reconcile with age gate to catch leaks between restarts without
  // killing pods mid-provision.
  setInterval(
    () => void reconcileOrphanPods(config.RECONCILE_MIN_AGE_SEC),
    config.RECONCILE_INTERVAL_MS,
  );
  log.info(
    {
      idleTimeoutMs: IDLE_TIMEOUT_MS,
      maxConcurrent: MAX_CONCURRENT_PROVISIONS,
      reconcileIntervalMs: config.RECONCILE_INTERVAL_MS,
      reconcileMinAgeSec: config.RECONCILE_MIN_AGE_SEC,
      backendFluxVersion: BACKEND_FLUX_APP_VERSION ? BACKEND_FLUX_APP_VERSION.slice(0, 8) : '(unset — drift checks disabled)',
      backendGitSha: BACKEND_GIT_SHA ? BACKEND_GIT_SHA.slice(0, 8) : '(unset)',
    },
    'Orchestrator started',
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Semaphore
// ────────────────────────────────────────────────────────────────────────────

function isSemaphoreFull(): boolean {
  return activeProvisions >= MAX_CONCURRENT_PROVISIONS;
}

async function acquireSemaphore(): Promise<void> {
  if (activeProvisions < MAX_CONCURRENT_PROVISIONS) {
    activeProvisions++;
    return;
  }
  const queuedAt = Date.now();
  const queueDepth = semaphoreWaiters.length + 1;
  log.info({ active: activeProvisions, cap: MAX_CONCURRENT_PROVISIONS, queueDepth }, 'Provision queued');
  await Sentry.startSpan(
    { name: 'pod.semaphore_wait', op: 'pod.semaphore_wait', attributes: { queueDepth } },
    () => new Promise<void>((resolve) => semaphoreWaiters.push(resolve)),
  );
  activeProvisions++;
  const waitedMs = Date.now() - queuedAt;
  log.info({ waitedMs, active: activeProvisions }, 'Provision dequeued');
}

function releaseSemaphore(): void {
  activeProvisions--;
  const next = semaphoreWaiters.shift();
  if (next) next();
}

// ────────────────────────────────────────────────────────────────────────────
// Reaper + reconcile
// ────────────────────────────────────────────────────────────────────────────

async function runReaper(): Promise<void> {
  const now = Date.now();
  const redis = getRedis();
  for await (const key of eachSessionKey()) {
    try {
      const data = await redis.hgetall(key);
      const state = data['state'];
      if (!data['sessionId'] || !data['podId']) continue;
      if (state !== 'ready') continue; // skip in-progress and terminal states
      const lastActivity = Number(data['lastActivityAt'] ?? 0);
      const idleMs = now - lastActivity;
      if (idleMs <= IDLE_TIMEOUT_MS) continue;

      // Atomic: only reap if state is still 'ready' (prevents two reapers
      // both reaping the same session across replicas).
      const claimed = await redis.multi()
        .hget(key, 'state')
        .hset(key, 'state', 'terminated')
        .exec();
      const prevState = claimed?.[0]?.[1];
      if (prevState !== 'ready') continue; // another reaper got it

      const podId = data['podId']!;
      const sessionId = data['sessionId']!;
      const videoPodId = data['videoPodId'] || null;
      const createdAt = Number(data['createdAt'] ?? 0);
      const lifetimeMs = createdAt > 0 ? now - createdAt : 0;
      log.info({ sessionId, podId, videoPodId, idleMs, lifetimeMs, kind: 'image' }, '[reaper] terminating idle session');
      trackPodTerminated({ userId: sessionId, reason: 'idle', lifetimeMs });
      notifyPodTerminated(podId, `idle ${Math.round(idleMs / 1000)}s`);
      // Emit through the broker so the iPad sees state='terminated' with
      // failure_category='idle_timeout' BEFORE we close the upstream pod WS.
      // stream.ts's broker subscriber will close the iPad WS cleanly with
      // code 1000, so when relay.onClose fires from the pod kill below,
      // the recovery path's clientDisconnected check exits early — no
      // confusing "Recovery failed" bounce.
      await emitState(sessionId, 'terminated', 'idle_timeout');
      terminatePod(podId)
        .then(() => redis.del(key))
        .catch((err) => log.error({ sessionId, podId, err }, 'Reap failed'));
      if (videoPodId) {
        log.info({ sessionId, videoPodId, kind: 'video' }, '[reaper] terminating video pod alongside image');
        terminatePod(videoPodId).catch((err) =>
          log.error({ sessionId, videoPodId, err }, 'Reap video pod failed'),
        );
      }
    } catch (err) {
      log.warn({ key, err: (err as Error).message }, 'Reaper error on key');
    }
  }
}

/**
 * Cross-reference Redis sessions with RunPod pods matching our prefix.
 * Pods that no Redis session points at are terminated. Sessions whose pods
 * no longer exist on RunPod are deleted.
 *
 * @param minAgeSec Skip pods younger than this (or whose runtime hasn't
 *   started yet). Pass 0 at boot — every pod is fair game since we just
 *   restarted. At runtime, pass a value comfortably over the provision
 *   deadline so we don't kill pods mid-provision.
 */
async function reconcileOrphanPods(minAgeSec = 0): Promise<void> {
  try {
    // 1. Read all session keys from Redis
    const redis = getRedis();
    const sessionPodIds = new Set<string>();
    const sessionVideoPodIds = new Set<string>();
    const staleKeys: string[] = [];
    for await (const key of eachSessionKey()) {
      const data = await redis.hgetall(key);
      const state = data['state'];
      if (data['podId'] && state === 'ready') {
        sessionPodIds.add(data['podId']);
      } else if (state && isActiveProvisioning(state as State)) {
        // Stale in-progress row (no live promise to resume). Clean up.
        staleKeys.push(key);
      } else if (!state) {
        // Legacy row from pre-refactor backend (had `status` field instead);
        // treat as stale and clean up.
        staleKeys.push(key);
      }
      // Video pods: in use whenever a session row references them, regardless
      // of the image pod's state — the video provision happens after image
      // 'ready', so the row's state is always 'ready' by the time videoPodId
      // is set. But guard with the same `state === 'ready'` filter to avoid
      // adopting a videoPodId from a row that's mid-cleanup.
      if (data['videoPodId'] && state === 'ready') {
        sessionVideoPodIds.add(data['videoPodId']);
      }
    }

    // Clean up stale in-progress rows
    for (const key of staleKeys) {
      log.warn({ key }, 'Reconcile: deleting stale in-progress session');
      await redis.del(key);
    }

    // 2. List RunPod pods (image + video, separately so we count distinctly).
    const pods = await listPodsByPrefix(POD_PREFIX);
    const videoPods = await listPodsByPrefix(VIDEO_POD_PREFIX);

    // 3. Adopt, skip young, or terminate (image pods)
    let adopted = 0;
    let skippedYoung = 0;
    let terminated = 0;
    for (const pod of pods) {
      if (sessionPodIds.has(pod.id)) {
        adopted++;
        continue;
      }
      if (minAgeSec > 0) {
        const uptime = pod.runtime?.uptimeInSeconds ?? 0;
        if (pod.runtime === null || uptime < minAgeSec) {
          // Pod might be mid-provision — its Redis row hasn't been written yet.
          skippedYoung++;
          continue;
        }
      }
      // Genuine orphan — no Redis session references this pod and it's old enough
      log.warn({ podId: pod.id, name: pod.name }, 'Reconcile: terminating orphan pod');
      terminated++;
      await terminatePod(pod.id).catch((err) =>
        log.error({ podId: pod.id, name: pod.name, err }, 'Failed to terminate orphan'),
      );
    }

    // 3b. Same logic for video pods. Source of truth: videoPodId fields on
    // Redis session rows. Anything else under the kiki-vsession-* prefix is
    // an orphan (backend crash mid-stream, or stream.ts close handler missed
    // the terminate). Boot reconcile (minAgeSec=0) is aggressive — there
    // are no live sessions yet — and periodic respects skip-young.
    let videoAdopted = 0;
    let videoSkippedYoung = 0;
    let videoTerminated = 0;
    for (const pod of videoPods) {
      if (sessionVideoPodIds.has(pod.id)) {
        videoAdopted++;
        continue;
      }
      if (minAgeSec > 0) {
        const uptime = pod.runtime?.uptimeInSeconds ?? 0;
        if (pod.runtime === null || uptime < minAgeSec) {
          videoSkippedYoung++;
          continue;
        }
      }
      log.warn({ podId: pod.id, name: pod.name, kind: 'video' }, '[reconcile] orphans found terminating video pod');
      videoTerminated++;
      await terminatePod(pod.id).catch((err) =>
        log.error({ podId: pod.id, name: pod.name, err }, 'Failed to terminate orphan video pod'),
      );
    }

    // 4. Clean up Redis sessions whose pods no longer exist on RunPod
    const runpodPodIds = new Set(pods.map((p) => p.id));
    const runpodVideoPodIds = new Set(videoPods.map((p) => p.id));
    for await (const key of eachSessionKey()) {
      const podId = await redis.hget(key, 'podId');
      if (podId && !runpodPodIds.has(podId)) {
        log.warn({ key, podId }, 'Reconcile: deleting session for pod no longer on RunPod');
        await redis.del(key);
        continue;
      }
      // Image pod still exists; clear stale videoPodId if the video pod is gone.
      const stashedVideoPodId = await redis.hget(key, 'videoPodId');
      if (stashedVideoPodId && !runpodVideoPodIds.has(stashedVideoPodId)) {
        log.warn(
          { key, videoPodId: stashedVideoPodId },
          'Reconcile: clearing stale videoPodId on session (video pod gone)',
        );
        await redis.hdel(key, 'videoPodId');
      }
    }

    log.info(
      {
        adopted, terminated, skippedYoung, staleProvisioning: staleKeys.length,
        videoAdopted, videoTerminated, videoSkippedYoung,
        minAgeSec,
        event: '[reconcile] orphans found',
        image: pods.length,
        video: videoPods.length,
      },
      'Reconcile complete',
    );
  } catch (err) {
    log.error({ err }, 'Reconcile failed (continuing anyway)');
  }
}

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
 *   - 'current'        — volume is on the same flux-klein-server tree as backend
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
 * `flux-klein-server/` subtree at the respective deploy times, so they only
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
async function provision(sessionId: string, signal?: AbortSignal): Promise<ProvisionResult> {
  return Sentry.startSpan(
    { name: 'pod.provision', op: 'pod.provision', attributes: { sessionId } },
    async () => {
      try {
        const result = await _runProvisionLoop('image', sessionId, {
          signal,
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

// ────────────────────────────────────────────────────────────────────────────
// Video pod public entry points. Both call into the unified machinery
// (`_runProvisionLoop` via POD_CONFIGS.video). The only video-specific
// concerns here are: (a) best-effort contract — return null on any failure,
// image session continues; (b) co-locate with image's DC; (c) join
// concurrent in-flight provisions (covers a quick iPad reconnect during
// the LTXV warmup window).
// ────────────────────────────────────────────────────────────────────────────

/** Kick off (or reuse) a video provision in the inFlight map. Stores the
 *  rich-shape promise from _runProvisionLoop, returns the narrower
 *  best-effort {podId, podUrl}|null. Used by both fresh provision
 *  (getOrProvisionVideoPod) and replacement (replaceVideoSession).
 *
 *  Note: pre-LTX-2.3 we passed `preferredDc=imagePodDc` here to co-locate
 *  the video pod with the image pod's DC. Post-migration, image and video
 *  use disjoint GPU SKUs (5090 vs H100 SXM) which RunPod allocates to
 *  disjoint DCs — co-location can never succeed. The forwarded video_request
 *  payload is one JPEG (~200 KB) over RunPod's backbone (~50 ms cross-DC),
 *  acceptable. */
async function _runVideoProvision(
  sessionId: string,
): Promise<{ podId: string; podUrl: string } | null> {
  const key = `video:${sessionId}`;
  const controller = new AbortController();
  const promise = (async () => {
    try {
      return await _runProvisionLoop('video', sessionId, { signal: controller.signal });
    } finally {
      inFlightProvisions.delete(key);
    }
  })();
  inFlightProvisions.set(key, { promise, controller });
  try {
    const r = await promise;
    return { podId: r.podId, podUrl: r.podUrl };
  } catch (err) {
    log.warn(
      { sessionId, err: (err as Error).message, pod_kind: 'video' },
      'video provision failed; session is image-only',
    );
    return null;
  }
}

/**
 * Get-or-provision the video pod for a session.
 *
 * Returns null on failure (best-effort — image session keeps going). On
 * success returns { podId, podUrl } for stream.ts to wire its relay.
 *
 * Reuse path: probes RunPod via POD_CONFIGS.video.getReusableFromRow.
 * If pod is RUNNING+runtime, reuse. If RUNNING-but-still-booting AND we
 * own the in-flight promise, join it. Otherwise (gone, mid-boot on a
 * different replica, or no prior pod) fall through to a fresh provision.
 */
export async function getOrProvisionVideoPod(
  sessionId: string,
): Promise<{ podId: string; podUrl: string } | null> {
  const existing = await readSession(sessionId);

  // ── Reuse path: ready pod (RUNNING+runtime). ───────────────────────
  if (existing) {
    const reusable = await POD_CONFIGS.video.getReusableFromRow(existing);
    if (reusable) {
      log.info(
        { sessionId, videoPodId: reusable.podId, pod_kind: 'video', event: '[provision/video] reused' },
        '[provision/video] reusing existing pod (no cold start)',
      );
      return reusable;
    }
  }

  // ── In-flight join: another concurrent caller is already provisioning. ──
  // (Catches both "row has videoPodId, mid-boot on this instance" and
  // "no row stamp yet, but provision started microseconds ago".)
  const inFlight = inFlightProvisions.get(`video:${sessionId}`);
  if (inFlight) {
    log.info(
      { sessionId, pod_kind: 'video', event: '[provision/video] joined in-flight' },
      '[provision/video] joining in-flight provision',
    );
    try {
      const r = await inFlight.promise;
      return { podId: r.podId, podUrl: r.podUrl };
    } catch {
      return null;
    }
  }

  // ── Stale row stamp: pod gone or owned by a different replica. ────
  if (existing?.videoPodId) {
    log.info(
      { sessionId, videoPodId: existing.videoPodId, pod_kind: 'video', event: '[provision/video] stale id' },
      '[provision/video] stashed videoPodId is stale; reprovisioning',
    );
    await clearVideoPod(sessionId).catch(() => {});
  }

  // ── Fresh provision. ──────────────────────────────────────────────
  return _runVideoProvision(sessionId);
}

/**
 * Replace a session's video pod after it dies mid-session. Mirror of
 * `replaceSession` for the video kind: terminate the old video pod,
 * reprovision via the shared loop, return the new pod info or null on
 * failure. Called by stream.ts's `handleVideoUpstreamClose` after a
 * same-pod reconnect attempt fails (i.e., the pod is truly gone, not
 * just a transient WS drop).
 *
 * Best-effort contract: returns null on any failure. No `replacementCount`
 * bump — that budget is for image (where exhaustion bounces the iPad);
 * video replacement just falls back to image-only on giveup.
 */
export async function replaceVideoSession(
  sessionId: string,
): Promise<{ podId: string; podUrl: string } | null> {
  const session = await readSession(sessionId);
  if (!session) {
    log.warn({ sessionId }, 'replaceVideoSession: no session to replace');
    return null;
  }
  log.info(
    { sessionId, oldPodId: session.videoPodId, pod_kind: 'video' },
    'Starting video session replacement',
  );

  // Clear old pod ref + terminate (fire-and-forget).
  await clearVideoPod(sessionId).catch(() => {});
  if (session.videoPodId) {
    terminatePod(session.videoPodId).catch((e) =>
      log.warn(
        { sessionId, oldPodId: session.videoPodId, err: (e as Error).message },
        'replaceVideoSession: terminate old pod failed (reaper will clean)',
      ),
    );
  }

  return _runVideoProvision(sessionId);
}

/** Terminate a video pod by ID. Never throws. Used by stream.ts on relay
 *  wire failure. */
export async function terminateVideoPod(podId: string): Promise<void> {
  try {
    await terminatePod(podId);
    log.info({ podId, pod_kind: 'video', event: '[provision/video] terminated' }, '[provision/video] terminated');
  } catch (err) {
    log.warn(
      { podId, err: (err as Error).message, pod_kind: 'video' },
      '[provision/video] terminate failed (will be cleaned by reconcile)',
    );
  }
}

/** Clear videoPodId on session row. Never throws. Used by stream.ts on
 *  relay wire failure to ensure the next reconnect provisions fresh. */
export async function clearVideoPod(sessionId: string): Promise<void> {
  try {
    await patchSession(sessionId, { videoPodId: null });
  } catch (err) {
    log.warn(
      { sessionId, err: (err as Error).message },
      'clearVideoPod patchSession failed',
    );
  }
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
): Promise<{ podId: string; podType: PodType; dc: string | null }> {
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
        env: BOOT_ENV,
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
      env: BOOT_ENV,
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
    // Both image (server.py) and video (video_server.py) bind to 8766 via
    // BOOT_ENV.FLUX_PORT — same Python server framework, different scripts.
    // Kept parametric in case a future pod kind diverges.
    port: 8766,
    gpuTypeId: 'NVIDIA GeForce RTX 5090',
    volumesByDc: config.NETWORK_VOLUMES_BY_DC,
    stallMs: config.POD_BOOT_WATCHDOG_ENABLED ? config.POD_BOOT_STALL_MS : Infinity,
    createPodForDc: (target, sessionId) => {
      const podName = `${POD_PREFIX}${sessionId.slice(0, 16)}`;
      return createPodWithFallback(sessionId, target, podName, BOOT_DOCKER_ARGS);
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
    createPodForDc: async (target, sessionId) => {
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
        env: BOOT_ENV,
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
async function _runProvisionLoop(
  kind: PodKind,
  sessionId: string,
  opts: {
    preferredDc?: string;
    signal?: AbortSignal;
    onProvisionPhase?: (phase: State, podId: string | null) => Promise<void>;
  } = {},
): Promise<{ podId: string; podUrl: string; podType: PodType; dc: string | null }> {
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
        () => cfg.createPodForDc(target, sessionId),
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
        // for the whole flux-klein-server/ tree (server.py + video_server.py),
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
