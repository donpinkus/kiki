export interface AppConfig {
  readonly PORT: number;
  readonly HOST: string;
  readonly RUNPOD_API_KEY: string;
  /** Optional RunPod container registry credential ID for authenticated Docker
   * Hub pulls. Used only by the one-off probe and populate-volume scripts.
   * Runtime pod creation does not use a registry credential (stock RunPod base
   * image is public). */
  readonly RUNPOD_REGISTRY_AUTH_ID: string;

  // ─── Auth (Workstream 1) ──────────────────────────────────────────────
  /** HS256 secret for signing/verifying access tokens (1h TTL). */
  readonly JWT_ACCESS_SECRET: string;
  /** Separate HS256 secret for refresh tokens (30d TTL). */
  readonly JWT_REFRESH_SECRET: string;
  /** iOS app's bundle identifier — used as Apple identity-token audience and as
   * the bundle id when verifying StoreKit transactions / App Store notifications. */
  readonly APPLE_BUNDLE_ID: string;
  /** Numeric App Store app id ("Apple ID" in App Store Connect → App Information).
   * Required by Apple's lib to build a PRODUCTION StoreKit verifier; until set,
   * the backend verifies Sandbox/TestFlight transactions but rejects Production
   * ones with a clear error. 0/unset = not configured (pre-App-Store-launch). */
  readonly APPLE_APP_APPLE_ID: number;
  /** When true, reject WS connections without a valid Bearer token. When
   * false (default), backend accepts both legacy ?session= and new Bearer
   * for the rollout window. */
  readonly AUTH_REQUIRED: boolean;

  // ─── Entitlement / fal budget ─────────────────────────────────────────
  /** Free fal image-generation spend (USD) per unsubscribed user per calendar
   * month before they must subscribe. Test accounts + active subscribers are
   * exempt. Default 10. */
  readonly FREE_TIER_FAL_USD: number;

  // ─── On-demand fallback (Workstream 2) ────────────────────────────────
  /** When true, orchestrator falls back to on-demand pods when spot capacity
   * is exhausted. Default false so the flag can be flipped on per deploy. */
  readonly ONDEMAND_FALLBACK_ENABLED: boolean;

  /** When true, skip the spot attempt entirely and provision on-demand pods
   * directly. Implies `ONDEMAND_FALLBACK_ENABLED` semantics regardless of that
   * flag's value. Used to ride out RunPod spot capacity instability without
   * removing the spot code path. Default false. */
  readonly ONDEMAND_ONLY_MODE: boolean;

  /** When true, stream.ts provisions a video pod alongside the image pod for
   * each session. When false, sessions are image-only and queueEmpty triggers
   * log 'video_skipped: relay_disconnected' (same code path as a runtime
   * provision failure). Lets us deploy backend-side video changes ahead of
   * the pod-side code reaching every network volume. Default false. */
  readonly VIDEO_POD_ENABLED: boolean;

  // ─── Image provider (fal.ai hosted realtime vs RunPod) ────────────────
  /** Which backend serves the live img2img path. `runpod` (default) provisions
   * per-session FLUX.2-klein pods. `fal` relays each frame to fal's hosted
   * `fal-ai/flux-2/klein/realtime` model instead (no pod, ~1.5s first frame).
   * The VIDEO idle-state path stays on RunPod regardless. Revert = set back to
   * `runpod` + redeploy; the RunPod image path is dormant, not removed. */
  readonly IMAGE_PROVIDER: 'runpod' | 'fal';
  /** fal.ai API key — server-side only (CLAUDE.md #3: no secrets on client).
   * Used as `Authorization: Key <FAL_KEY>` on the fal realtime WS upgrade.
   * Required when `IMAGE_PROVIDER=fal`; ignored otherwise. */
  readonly FAL_KEY: string;
  /** Cost lever: proactively close the fal realtime WS after this many ms with
   * no new frame (then lazily reconnect on the next stroke), instead of paying
   * for the runner until fal's ~30s idle timeout. 0 = disabled (default).
   * Only beneficial if fal bills actual connection duration (verify first).
   * A few seconds (e.g. 2000-4000) balances savings vs reconnect churn. */
  readonly FAL_IDLE_CLOSE_MS: number;
  /** fal keep-warm loop (modules/fal/falWarmer.ts) — env values are only the
   * SEED for the `admin_config.fal_warmer` row (created at boot if absent);
   * after that, the row is the runtime truth and is edited live from Kiki
   * Insights → Ops. fal's marketplace pool for klein/realtime scales to zero
   * and takes ~2-3.5 min to spin up (measured 2026-07-13), so without warming
   * the first stroke of a session waits minutes for its first image. */
  readonly FAL_WARMER_ENABLED: boolean;
  /** Ping cadence. Binary-searched 2026-07-14: warmth holds at <=120s gaps
   * (0% cold across 61 pings at 60/90/120s) and collapses at 150s (60% cold).
   * Default 90s, NOT 120s: the warmer's 30s tick granularity stretches real
   * gaps up to interval+30s, and 120+30=150s is exactly the cold boundary
   * (observed in production 2026-07-15: a 150s effective gap → 111s cold
   * start). 90+30=120s keeps worst-case gaps inside proven-warm territory.
   * Cost is a non-factor between cadences — fal doesn't bill the cold
   * spin-up/enqueue wait, only warm-runner-attached time. */
  readonly FAL_WARMER_INTERVAL_MS: number;
  /** Daily no-warm window, hours in America/Los_Angeles local time (handles
   * PST/PDT). Pings are skipped from OFF_START (inclusive) to OFF_END
   * (exclusive). Default 2→8 (2am-8am Pacific). Equal values = no window. */
  readonly FAL_WARMER_OFF_START_HOUR: number;
  readonly FAL_WARMER_OFF_END_HOUR: number;

  // ─── Session capture (admin replay in Kiki Insights) ──────────────────
  /** When true (default), the stream route mirrors a throttled sample of each
   * session's sketch JPEGs (iPad→provider) and generated JPEGs (provider→iPad)
   * to Insights /ingest/capture for admin replay (Insights → Gallery).
   * PRIVACY: this persists user drawings server-side — it supersedes the old
   * "sketches are ephemeral" rule (owner decision 2026-07-15). The privacy
   * policy + App Store data disclosure must reflect it before external users.
   * No-op unless INSIGHTS_URL + INSIGHTS_INGEST_KEY are also set. */
  readonly SESSION_CAPTURE_ENABLED: boolean;
  /** Per-kind capture floor: at most one sketch + one generated frame per this
   * many ms per stream (default 1000 → ≤2 frames/s stored vs ~4 generated). */
  readonly SESSION_CAPTURE_MIN_INTERVAL_MS: number;
  /** Per-kind, per-stream frame cap — bounds storage per session (default 600
   * ≈ 10 min of active drawing at the 1s floor; ~50 MB worst case). */
  readonly SESSION_CAPTURE_MAX_FRAMES: number;

  // ─── Network volumes (pre-populated with weights, venv, app code) ────
  /** Map of RunPod datacenter ID → network volume ID for IMAGE pods (FLUX
   * BF16 + NVFP4, ~20 GB). Volumes live in 5090-stocked DCs. Pre-populated
   * by `populate-volume.ts --kind image`. JSON env var, e.g.
   * `{"EUR-NO-1":"49n6i3twuw","US-NC-1":"5vz7ubospw"}`. */
  readonly NETWORK_VOLUMES_BY_DC: Readonly<Record<string, string>>;
  /** Map of RunPod datacenter ID → network volume ID for VIDEO pods
   * (LTX-2.3 22B FP8 + Gemma-3-12B + spatial upscaler, ~52 GB). Volumes
   * live in H100-SXM-stocked DCs (different set than image volumes —
   * 5090 DCs typically don't have H100 SXM, and vice versa). Pre-populated
   * by `populate-volume.ts --kind video` (requires HF_TOKEN with Gemma
   * access accepted). JSON env var. Empty → video pods skip provisioning. */
  readonly NETWORK_VOLUMES_BY_DC_VIDEO: Readonly<Record<string, string>>;

  // ─── Redis (Workstream 5) ──────────────────────────────────────────────
  /** Redis connection URL. Required for session registry persistence. */
  readonly REDIS_URL: string;

  // ─── Postgres (durable accounts; usage ledger) ─────────────────────────
  /** Postgres connection string — the durable store for user accounts (and,
   * later, the per-user usage ledger). Required; the backend fails to boot
   * without it. Railway injects this from the Postgres addon. */
  readonly DATABASE_URL: string;

  // ─── Cost monitoring (Workstream 4) ────────────────────────────────────
  /** Shared secret for /v1/ops/* endpoints. Unset → ops routes reject all. */
  readonly OPS_API_KEY: string;
  /** Tick interval for cost monitor. Default 5 min. */
  readonly COST_MONITOR_INTERVAL_MS: number;
  /** Discord webhook URL for cost alerts + hourly digest. Unset → log only. */
  readonly COST_ALERT_WEBHOOK_URL: string;
  /** Discord Forum channel webhook for per-pod lifecycle threads. Unset → falls
   * back to COST_ALERT_WEBHOOK_URL (no threads). */
  readonly COST_POD_LOG_WEBHOOK_URL: string;
  /** Alert when active pod count exceeds this. */
  readonly COST_ALERT_MAX_ACTIVE_PODS: number;
  /** Alert when rolling 24h spend exceeds this (USD). */
  readonly COST_ALERT_MAX_24H_SPEND: number;
  /** Hard monthly spend cap (USD). Trips a provision gate when breached. */
  readonly COST_ALERT_MAX_MONTHLY_SPEND: number;
  /** Alert when any pod's age exceeds this (seconds). */
  readonly COST_ALERT_MAX_POD_AGE_SECONDS: number;
  /** Minimum seconds between alerts of the same type. */
  readonly COST_ALERT_COOLDOWN_SECONDS: number;

  // ─── Preemption handling (Workstream 7) ────────────────────────────────
  /** When true, hold client WS open and transparently replace the pod on
   * preemption. When false, close client with error (legacy behavior). */
  readonly PREEMPTION_REPLACEMENT_ENABLED: boolean;
  /** Max replacement attempts per session before giving up. */
  readonly MAX_SESSION_REPLACEMENTS: number;

  // ─── Orphan pod reconciliation ─────────────────────────────────────────
  /** Interval between continuous `reconcileOrphanPods` sweeps (ms). Default 30 min. */
  readonly RECONCILE_INTERVAL_MS: number;
  /** Minimum pod age (seconds) before a runtime reconcile will consider it
   * orphaned. Guards against terminating pods that are still mid-provision.
   * Default 600 (10 min), well above the ~150s provision deadline. Boot-time
   * reconcile ignores this (uses 0) since the process was just rebuilt. */
  readonly RECONCILE_MIN_AGE_SEC: number;

  // ─── Product analytics (PostHog) ───────────────────────────────────────
  /** PostHog project API key (write-only, `phc_...`). If unset, all analytics
   * calls no-op — safe to leave empty in dev. */
  readonly POSTHOG_API_KEY: string;
  /** PostHog ingestion host. Default US cloud. Override for EU cloud or
   * self-hosted. */
  readonly POSTHOG_HOST: string;

  // ─── Kiki Insights (internal per-user analytics microsite) ─────────────
  /** Base URL of the Insights service (e.g. https://kiki-insights.up.railway.app).
   * When set together with INSIGHTS_INGEST_KEY, every backend analytics event is
   * dual-written to Insights' /ingest (best-effort, fire-and-forget) alongside
   * PostHog. Unset → no-op (local dev / CI). */
  readonly INSIGHTS_URL: string;
  /** Service key presented as `x-insights-key` to Insights' /ingest. MUST equal
   * the value set on the Insights service. Unset → Insights dual-write no-ops. */
  readonly INSIGHTS_INGEST_KEY: string;

  // ─── Pod-boot stall watchdog ───────────────────────────────────────────
  /** When true, `waitForRuntime` fast-fails with `PodBootStallError` once
   * `pod.runtime` has stayed null longer than `POD_BOOT_STALL_MS`, and
   * `provision` rerolls onto a different DC. Disable to restore legacy binary
   * 10-min timeout. Covers NFS mount stalls and stock-image pulls on cold
   * hosts (the watchdog was originally GHCR-focused pre-2026-04-23). */
  readonly POD_BOOT_WATCHDOG_ENABLED: boolean;
  /** Ms to wait for `pod.runtime` to become non-null before calling a stall.
   * Default 45000 (45 s) — tighter than the old 120 s budget because the
   * stock image usually boots in ~5–90 s on a host with the base cached.
   * Tune upward if Sentry shows false-positive stalls on legitimately cold
   * hosts. */
  readonly POD_BOOT_STALL_MS: number;
  /** Max retries with a different DC per provision attempt. Default 2 (so up
   * to 3 attempts total). Set to 0 to emit Sentry stall events without
   * actually rerolling — useful for a dry-run observation phase. */
  readonly POD_BOOT_MAX_REROLLS: number;

  readonly NODE_ENV: 'development' | 'production' | 'test';
  readonly LOG_LEVEL: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace';
}

function parseVolumesMap(raw: string | undefined, varName: string): Readonly<Record<string, string>> {
  if (!raw) return Object.freeze({});
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(
      `${varName} must be valid JSON (got: ${raw.slice(0, 60)}...)`,
    );
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${varName} must be a JSON object { "DC-ID": "volumeId" }`);
  }
  const out: Record<string, string> = {};
  for (const [dc, vol] of Object.entries(parsed)) {
    if (typeof vol !== 'string' || !vol) {
      throw new Error(`${varName}[${dc}] must be a non-empty string`);
    }
    out[dc] = vol;
  }
  return Object.freeze(out);
}

function validateConfig(): AppConfig {
  const nodeEnv = (process.env['NODE_ENV'] ?? 'development') as AppConfig['NODE_ENV'];
  if (!['development', 'production', 'test'].includes(nodeEnv)) {
    throw new Error(`Invalid NODE_ENV: ${nodeEnv}`);
  }

  const logLevel = (process.env['LOG_LEVEL'] ?? 'info') as AppConfig['LOG_LEVEL'];
  if (!['fatal', 'error', 'warn', 'info', 'debug', 'trace'].includes(logLevel)) {
    throw new Error(`Invalid LOG_LEVEL: ${logLevel}`);
  }

  const port = Number(process.env['PORT'] ?? 3000);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid PORT: ${process.env['PORT']}`);
  }

  const runpodApiKey = process.env['RUNPOD_API_KEY'] ?? '';
  if (!runpodApiKey) {
    throw new Error('RUNPOD_API_KEY is required (orchestrator needs it to create/query/terminate pods)');
  }

  const jwtAccessSecret = process.env['JWT_ACCESS_SECRET'] ?? '';
  if (!jwtAccessSecret || jwtAccessSecret.length < 32) {
    throw new Error(
      'JWT_ACCESS_SECRET is required and must be ≥32 bytes (generate with `openssl rand -hex 32`)',
    );
  }

  const jwtRefreshSecret = process.env['JWT_REFRESH_SECRET'] ?? '';
  if (!jwtRefreshSecret || jwtRefreshSecret.length < 32) {
    throw new Error(
      'JWT_REFRESH_SECRET is required and must be ≥32 bytes (generate with `openssl rand -hex 32`)',
    );
  }
  if (jwtRefreshSecret === jwtAccessSecret) {
    throw new Error(
      'JWT_REFRESH_SECRET must differ from JWT_ACCESS_SECRET (separate secrets are a security boundary)',
    );
  }

  const appleBundleId = process.env['APPLE_BUNDLE_ID'] ?? '';
  if (!appleBundleId) {
    throw new Error(
      'APPLE_BUNDLE_ID is required (used as audience when verifying Apple identity tokens)',
    );
  }

  const databaseUrl = process.env['DATABASE_URL'] ?? '';
  if (!databaseUrl) {
    throw new Error('DATABASE_URL is required (Postgres connection string for the durable user/account store)');
  }

  const imageProvider = (process.env['IMAGE_PROVIDER'] ?? 'runpod') as AppConfig['IMAGE_PROVIDER'];
  if (!['runpod', 'fal'].includes(imageProvider)) {
    throw new Error(`Invalid IMAGE_PROVIDER: ${imageProvider} (expected 'runpod' or 'fal')`);
  }
  const falKey = process.env['FAL_KEY'] ?? '';
  if (imageProvider === 'fal' && !falKey) {
    throw new Error("IMAGE_PROVIDER=fal requires FAL_KEY (fal.ai API key) to be set");
  }

  return {
    PORT: port,
    HOST: process.env['HOST'] ?? '0.0.0.0',
    RUNPOD_API_KEY: runpodApiKey,
    RUNPOD_REGISTRY_AUTH_ID: process.env['RUNPOD_REGISTRY_AUTH_ID'] ?? '',
    JWT_ACCESS_SECRET: jwtAccessSecret,
    JWT_REFRESH_SECRET: jwtRefreshSecret,
    APPLE_BUNDLE_ID: appleBundleId,
    APPLE_APP_APPLE_ID: Number(process.env['APPLE_APP_APPLE_ID'] ?? 0),
    AUTH_REQUIRED: process.env['AUTH_REQUIRED'] === 'true',
    FREE_TIER_FAL_USD: Number(process.env['FREE_TIER_FAL_USD'] ?? 10),
    ONDEMAND_FALLBACK_ENABLED: process.env['ONDEMAND_FALLBACK_ENABLED'] === 'true',
    VIDEO_POD_ENABLED: process.env['VIDEO_POD_ENABLED'] === 'true',
    IMAGE_PROVIDER: imageProvider,
    FAL_KEY: falKey,
    FAL_IDLE_CLOSE_MS: Number(process.env['FAL_IDLE_CLOSE_MS'] ?? 0),
    FAL_WARMER_ENABLED: process.env['FAL_WARMER_ENABLED'] !== 'false',
    FAL_WARMER_INTERVAL_MS: Number(process.env['FAL_WARMER_INTERVAL_MS'] ?? 90_000),
    FAL_WARMER_OFF_START_HOUR: Number(process.env['FAL_WARMER_OFF_START_HOUR'] ?? 2),
    FAL_WARMER_OFF_END_HOUR: Number(process.env['FAL_WARMER_OFF_END_HOUR'] ?? 8),
    SESSION_CAPTURE_ENABLED: process.env['SESSION_CAPTURE_ENABLED'] !== 'false',
    SESSION_CAPTURE_MIN_INTERVAL_MS: Number(process.env['SESSION_CAPTURE_MIN_INTERVAL_MS'] ?? 1000),
    SESSION_CAPTURE_MAX_FRAMES: Number(process.env['SESSION_CAPTURE_MAX_FRAMES'] ?? 600),
    ONDEMAND_ONLY_MODE: process.env['ONDEMAND_ONLY_MODE'] === 'true',
    NETWORK_VOLUMES_BY_DC: parseVolumesMap(process.env['NETWORK_VOLUMES_BY_DC'], 'NETWORK_VOLUMES_BY_DC'),
    NETWORK_VOLUMES_BY_DC_VIDEO: parseVolumesMap(
      process.env['NETWORK_VOLUMES_BY_DC_VIDEO'],
      'NETWORK_VOLUMES_BY_DC_VIDEO',
    ),
    REDIS_URL: process.env['REDIS_URL'] ?? '',
    DATABASE_URL: databaseUrl,
    PREEMPTION_REPLACEMENT_ENABLED: process.env['PREEMPTION_REPLACEMENT_ENABLED'] === 'true',
    MAX_SESSION_REPLACEMENTS: Number(process.env['MAX_SESSION_REPLACEMENTS'] ?? 2),
    RECONCILE_INTERVAL_MS: Number(process.env['RECONCILE_INTERVAL_MS'] ?? 30 * 60 * 1000),
    RECONCILE_MIN_AGE_SEC: Number(process.env['RECONCILE_MIN_AGE_SEC'] ?? 600),
    POSTHOG_API_KEY: process.env['POSTHOG_API_KEY'] ?? '',
    POSTHOG_HOST: process.env['POSTHOG_HOST'] ?? 'https://us.i.posthog.com',
    INSIGHTS_URL: process.env['INSIGHTS_URL'] ?? '',
    INSIGHTS_INGEST_KEY: process.env['INSIGHTS_INGEST_KEY'] ?? '',
    POD_BOOT_WATCHDOG_ENABLED: process.env['POD_BOOT_WATCHDOG_ENABLED'] !== 'false',
    POD_BOOT_STALL_MS: Number(process.env['POD_BOOT_STALL_MS'] ?? 45_000),
    POD_BOOT_MAX_REROLLS: Number(process.env['POD_BOOT_MAX_REROLLS'] ?? 2),
    OPS_API_KEY: process.env['OPS_API_KEY'] ?? '',
    COST_MONITOR_INTERVAL_MS: Number(process.env['COST_MONITOR_INTERVAL_MS'] ?? 300_000),
    COST_ALERT_WEBHOOK_URL: process.env['COST_ALERT_WEBHOOK_URL'] ?? '',
    COST_POD_LOG_WEBHOOK_URL: process.env['COST_POD_LOG_WEBHOOK_URL'] ?? '',
    COST_ALERT_MAX_ACTIVE_PODS: Number(process.env['COST_ALERT_MAX_ACTIVE_PODS'] ?? 50),
    COST_ALERT_MAX_24H_SPEND: Number(process.env['COST_ALERT_MAX_24H_SPEND'] ?? 200),
    COST_ALERT_MAX_MONTHLY_SPEND: Number(process.env['COST_ALERT_MAX_MONTHLY_SPEND'] ?? 5000),
    COST_ALERT_MAX_POD_AGE_SECONDS: Number(process.env['COST_ALERT_MAX_POD_AGE_SECONDS'] ?? 3600),
    COST_ALERT_COOLDOWN_SECONDS: Number(process.env['COST_ALERT_COOLDOWN_SECONDS'] ?? 1800),
    NODE_ENV: nodeEnv,
    LOG_LEVEL: logLevel,
  };
}

export const config: AppConfig = validateConfig();
