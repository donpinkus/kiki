export interface AppConfig {
  readonly PORT: number;
  readonly HOST: string;
  readonly RUNPOD_API_KEY: string;
  /** Optional RunPod container registry credential ID for authenticated Docker
   * Hub pulls. Used only by the one-off probe and populate-volume scripts;
   * runtime pod creation uses `RUNPOD_GHCR_AUTH_ID`. */
  readonly RUNPOD_REGISTRY_AUTH_ID: string;

  // ─── Auth (Workstream 1) ──────────────────────────────────────────────
  /** HS256 secret for signing/verifying access tokens (1h TTL). */
  readonly JWT_ACCESS_SECRET: string;
  /** Separate HS256 secret for refresh tokens (30d TTL). */
  readonly JWT_REFRESH_SECRET: string;
  /** iOS app's bundle identifier — used as Apple identity-token audience. */
  readonly APPLE_BUNDLE_ID: string;
  /** When true, reject WS connections without a valid Bearer token. When
   * false (default), backend accepts both legacy ?session= and new Bearer
   * for the rollout window. */
  readonly AUTH_REQUIRED: boolean;

  // ─── Entitlement (Workstream 1 stub, finished in Workstream 8) ────────
  /** Free GPU-seconds granted per user before they must subscribe. */
  readonly FREE_TIER_SECONDS: number;

  // ─── On-demand fallback (Workstream 2) ────────────────────────────────
  /** When true, orchestrator falls back to on-demand pods when spot capacity
   * is exhausted. Default false so the flag can be flipped on per deploy. */
  readonly ONDEMAND_FALLBACK_ENABLED: boolean;

  /** When true, skip the spot attempt entirely and provision on-demand pods
   * directly. Implies `ONDEMAND_FALLBACK_ENABLED` semantics regardless of that
   * flag's value. Used to ride out RunPod spot capacity instability without
   * removing the spot code path. Default false. */
  readonly ONDEMAND_ONLY_MODE: boolean;

  // ─── Pre-baked Docker image ──────────────────────────────────────────
  /** Full image reference (e.g. ghcr.io/owner/kiki-flux-klein:sha-abc). Required. */
  readonly FLUX_IMAGE: string;
  /** RunPod registry credential ID for authenticated GHCR pulls. */
  readonly RUNPOD_GHCR_AUTH_ID: string;
  /** Map of RunPod datacenter ID → network volume ID, each pre-populated with
   * FLUX weights at /workspace/huggingface. Baked mode uses this to skip the
   * 2-3 min model download on cold start. Parse from JSON env var, e.g.
   * `{"EUR-NO-1":"49n6i3twuw","US-NC-1":"5vz7ubospw"}`. Empty = no volume path. */
  readonly NETWORK_VOLUMES_BY_DC: Readonly<Record<string, string>>;

  // ─── Redis (Workstream 5) ──────────────────────────────────────────────
  /** Redis connection URL. Required for session registry persistence. */
  readonly REDIS_URL: string;

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

  // ─── Image-pull stall watchdog ─────────────────────────────────────────
  /** When true, `waitForRuntime` fast-fails with `ImagePullStallError` once
   * `pod.runtime` has stayed null longer than `CONTAINER_PULL_STALL_MS`, and
   * `provision` rerolls onto a different DC. Disable to restore legacy binary
   * 10-min timeout. */
  readonly CONTAINER_PULL_WATCHDOG_ENABLED: boolean;
  /** Ms to wait for `pod.runtime` to become non-null before calling a stall.
   * Default 120000 (2 min). Tune upward if Sentry shows false-positive stalls
   * on legitimately cold hosts. */
  readonly CONTAINER_PULL_STALL_MS: number;
  /** Max retries with a different DC per provision attempt. Default 2 (so up
   * to 3 attempts total). Set to 0 to emit Sentry stall events without
   * actually rerolling — useful for a dry-run observation phase. */
  readonly CONTAINER_PULL_MAX_REROLLS: number;

  readonly NODE_ENV: 'development' | 'production' | 'test';
  readonly LOG_LEVEL: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace';
}

function parseVolumesMap(raw: string | undefined): Readonly<Record<string, string>> {
  if (!raw) return Object.freeze({});
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(
      `NETWORK_VOLUMES_BY_DC must be valid JSON (got: ${raw.slice(0, 60)}...)`,
    );
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('NETWORK_VOLUMES_BY_DC must be a JSON object { "DC-ID": "volumeId" }');
  }
  const out: Record<string, string> = {};
  for (const [dc, vol] of Object.entries(parsed)) {
    if (typeof vol !== 'string' || !vol) {
      throw new Error(`NETWORK_VOLUMES_BY_DC[${dc}] must be a non-empty string`);
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

  const fluxImage = process.env['FLUX_IMAGE'] ?? '';
  if (!fluxImage) {
    throw new Error('FLUX_IMAGE is required (GHCR image reference for pod provisioning)');
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

  return {
    PORT: port,
    HOST: process.env['HOST'] ?? '0.0.0.0',
    RUNPOD_API_KEY: runpodApiKey,
    RUNPOD_REGISTRY_AUTH_ID: process.env['RUNPOD_REGISTRY_AUTH_ID'] ?? '',
    JWT_ACCESS_SECRET: jwtAccessSecret,
    JWT_REFRESH_SECRET: jwtRefreshSecret,
    APPLE_BUNDLE_ID: appleBundleId,
    AUTH_REQUIRED: process.env['AUTH_REQUIRED'] === 'true',
    FREE_TIER_SECONDS: Number(process.env['FREE_TIER_SECONDS'] ?? 3600),
    ONDEMAND_FALLBACK_ENABLED: process.env['ONDEMAND_FALLBACK_ENABLED'] === 'true',
    ONDEMAND_ONLY_MODE: process.env['ONDEMAND_ONLY_MODE'] === 'true',
    FLUX_IMAGE: fluxImage,
    RUNPOD_GHCR_AUTH_ID: process.env['RUNPOD_GHCR_AUTH_ID'] ?? '',
    NETWORK_VOLUMES_BY_DC: parseVolumesMap(process.env['NETWORK_VOLUMES_BY_DC']),
    REDIS_URL: process.env['REDIS_URL'] ?? '',
    PREEMPTION_REPLACEMENT_ENABLED: process.env['PREEMPTION_REPLACEMENT_ENABLED'] === 'true',
    MAX_SESSION_REPLACEMENTS: Number(process.env['MAX_SESSION_REPLACEMENTS'] ?? 2),
    RECONCILE_INTERVAL_MS: Number(process.env['RECONCILE_INTERVAL_MS'] ?? 30 * 60 * 1000),
    RECONCILE_MIN_AGE_SEC: Number(process.env['RECONCILE_MIN_AGE_SEC'] ?? 600),
    POSTHOG_API_KEY: process.env['POSTHOG_API_KEY'] ?? '',
    POSTHOG_HOST: process.env['POSTHOG_HOST'] ?? 'https://us.i.posthog.com',
    CONTAINER_PULL_WATCHDOG_ENABLED: process.env['CONTAINER_PULL_WATCHDOG_ENABLED'] !== 'false',
    CONTAINER_PULL_STALL_MS: Number(process.env['CONTAINER_PULL_STALL_MS'] ?? 120_000),
    CONTAINER_PULL_MAX_REROLLS: Number(process.env['CONTAINER_PULL_MAX_REROLLS'] ?? 2),
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
