// ────────────────────────────────────────────────────────────────────────────
// Pod boot recipe — how a pod is launched.
// ────────────────────────────────────────────────────────────────────────────
//
// The ingredients for booting a pod off the stock `runpod/pytorch` image:
// base image, the inline SSH bootstrap + server-launch docker args, the per-pod
// env, and the pod-name prefixes. Pure data + string-building, no logic deps —
// the per-kind *recipe* (which args/GPU/volumes a kind uses) is assembled in
// `POD_CONFIGS` in provisioner.ts; this file holds the shared primitives that
// recipe is built from. Prefixes live here as pod identity (provisioner names
// pods with them; reaper lists pods by them).

// The two pod kinds. One provision machine (`_runProvisionLoop` in
// provisioner.ts) parameterized by `POD_CONFIGS[kind]`. Lives here — the lowest
// shared layer — because both podDeath.ts and provisioner.ts need it, and it's
// the natural pair to the per-kind prefixes below.
export type PodKind = 'image' | 'video';

// Pod name prefix for image pods. Distinct from VIDEO_POD_PREFIX so reconcile
// can list them separately and so RunPod console / Discord alerts are
// unambiguous about which kind died.
export const POD_PREFIX = 'kiki-session-';

// Pod name prefix for video pods. Distinct from POD_PREFIX so reconcile
// can list them separately and so RunPod console / Discord alerts are
// unambiguous about which kind died.
export const VIDEO_POD_PREFIX = 'kiki-vsession-';

// We launch pods from stock `runpod/pytorch` and bootstrap the FLUX server
// from files on the attached network volume. See scripts/sync-flux-app.ts
// for how the volume gets populated, and documents/decisions.md entry
// 2026-04-23 for the full context + rollback procedure.
export const BASE_IMAGE = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';

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
// `module` is a Python package path (e.g. 'image.server') launched with -m from
// /workspace/app, so 'image', 'video', and 'shared' resolve as packages.
const SERVER_LAUNCH = (module: string): string =>
  'if [ -n "$PUBLIC_KEY" ]; then ' +
  `while true; do python3 -u -m ${module}; sleep 2; done; ` +
  'else ' +
  `exec python3 -u -m ${module}; ` +
  'fi';

export const BOOT_DOCKER_ARGS =
  `bash -lc '${SSH_BOOTSTRAP}; source /workspace/venv/bin/activate && cd /workspace/app && ${SERVER_LAUNCH('image.server')}'`;
// Video pod runs LTXV i2v on a separate pod (see model-servers/video/server.py).
// Same volume / venv / port as the image pod — only the entry module differs.
export const BOOT_DOCKER_ARGS_VIDEO =
  `bash -lc '${SSH_BOOTSTRAP}; source /workspace/venv/bin/activate && cd /workspace/app && ${SERVER_LAUNCH('video.server')}'`;

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
  // try/except in video/pipeline.py:load() only catches errors from
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

// Forward Sentry DSN for the kiki-pod project. Conditional so local runs
// without the env var stay silent (sentry_init.init no-ops when unset).
if (process.env['SENTRY_DSN_POD']) {
  BOOT_ENV.push({ key: 'SENTRY_DSN_POD', value: process.env['SENTRY_DSN_POD'] });
}

/**
 * Build the per-pod env, appending KIKI_USER_ID + KIKI_STREAM_ID to BOOT_ENV.
 *
 * The pod's `model-servers/shared/sentry_init.py` reads these once at startup
 * and attaches them as Sentry log attributes (`user_id`, `stream_id`) on
 * every log entry, plus tags errors with `set_user({id})`. This is what
 * makes `user_id:X` cross-stack queries return both pod's logs alongside
 * iOS + backend.
 *
 * Constant for the pod's lifetime — pods are 1:1 with users (idle-reaped
 * after 30 min). A single pod *can* serve multiple `streamId`s when a user
 * reconnects within the idle window; we accept slight `stream_id`
 * staleness on the second connect (cross-reference via timestamps if
 * needed). Live update via WS-hello deferred — `user_id` covers the
 * common debugging query.
 */
export function bootEnvFor(userId: string, streamId?: string | null): typeof BOOT_ENV {
  return [
    ...BOOT_ENV,
    { key: 'KIKI_USER_ID', value: userId },
    { key: 'KIKI_STREAM_ID', value: streamId ?? '' },
  ];
}
