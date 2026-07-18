export interface AppConfig {
  readonly PORT: number;
  readonly HOST: string;
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

  // ─── Image provider (fal.ai hosted realtime vs Lambda Cloud) ──────────
  /** Which backend serves the live img2img path. `fal` (default, production)
   * relays each frame to fal's hosted `fal-ai/flux-2/klein/realtime` model
   * (~1.5s first frame). `lambda` relays to a Lambda Cloud H100 instance
   * running our own image server (scripts/lambda/) — dev toggle for
   * sketch-adherence comparison vs fal. */
  readonly IMAGE_PROVIDER: 'fal' | 'lambda' | 'auto';
  /** Full WS URL of a manually-launched Lambda image instance, including path
   * and token (printed by scripts/lambda/coldstart-bench.ts --keep). Optional
   * static override — when set it takes precedence over the dev pool. */
  readonly LAMBDA_IMAGE_URL: string;
  /** Lambda Cloud API key (cloud.lambda.ai/api-keys) — required for the dev
   * pool; also the HMAC key for per-instance WS tokens. Server-side only. */
  readonly LAMBDA_API_KEY: string;
  /** When true (and LAMBDA_API_KEY set), the backend keeps at most one
   * kiki-serve H100 instance for the per-session `imageProvider=lambda`
   * toggle: launched on demand (app login / stream request via
   * modules/lambda/devPool.ts), idle-reaped after 30 min. Dev/test-account
   * only. Default false. */
  readonly LAMBDA_DEV_POOL_ENABLED: boolean;
  /** Region for dev-pool instances. Its `kiki-image-<region>` filesystem must
   * be pre-populated via scripts/lambda/setup-lambda.ts. */
  readonly LAMBDA_REGION: string;
  /** Instance type for dev-pool instances. */
  readonly LAMBDA_INSTANCE_TYPE: string;
  /** Pool floor — instances kept warm regardless of load (0 = scale to zero
   * when nobody has shown interest for 10 min). */
  readonly LAMBDA_POOL_MIN: number;
  /** Pool ceiling — hard cap on concurrent instances ($4.29/hr each). */
  readonly LAMBDA_POOL_MAX: number;
  /** Autoscale dial: target concurrent streams per instance before the pool
   * grows. Measured: ~5 fully-served active drawers/instance at 4-step;
   * overload degrades gracefully, so this is a UX knob. */
  readonly LAMBDA_POOL_TARGET_STREAMS: number;
  /** Base64 PEM of the fleet's self-signed TLS cert. When set, relays and
   * sketchify connect wss:// and PIN this exact cert (hostname check skipped
   * — instances are bare IPs). Empty = plain ws:// (pre-TLS dev). Decoded
   * form exposed as LAMBDA_TLS_CA. */
  readonly LAMBDA_TLS_CA: string;

  // ─── Video (LTX-2.3 idle-state animation on a dedicated Lambda H100) ──
  /** Full WS URL of the dedicated Lambda VIDEO instance (LTX-2.3 server),
   * including path and token — printed by scripts/lambda/launch-video.ts.
   * Empty = video disabled (the POC gate). The video GPU is SEPARATE from
   * the image pool: LTX 22B FP8 + Gemma hold ~46 GiB resident and cannot
   * share an 80 GB H100 with the 9B-KV image server (~37 GB) — which also
   * guarantees image-generation latency is never impacted by video work. */
  readonly LAMBDA_VIDEO_URL: string;
  /** Idle window: a video_request fires this many ms after the user's LAST
   * sketch frame (provided a generated image newer than that sketch exists).
   * Default 3000 (product decision 2026-07-18). */
  readonly VIDEO_IDLE_TRIGGER_MS: number;
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

  // ─── Postgres (durable accounts; usage ledger) ─────────────────────────
  /** Postgres connection string — the durable store for user accounts (and,
   * later, the per-user usage ledger). Required; the backend fails to boot
   * without it. Railway injects this from the Postgres addon. */
  readonly DATABASE_URL: string;

  // ─── Kiki Insights (internal per-user analytics microsite) ─────────────
  /** Base URL of the Insights service (e.g. https://kiki-insights.up.railway.app).
   * When set together with INSIGHTS_INGEST_KEY, every backend analytics event is
   * written to Insights' /ingest (best-effort, fire-and-forget).
   * Unset → no-op (local dev / CI). */
  readonly INSIGHTS_URL: string;
  /** Service key presented as `x-insights-key` to Insights' /ingest. MUST equal
   * the value set on the Insights service. Unset → Insights dual-write no-ops. */
  readonly INSIGHTS_INGEST_KEY: string;

  readonly NODE_ENV: 'development' | 'production' | 'test';
  readonly LOG_LEVEL: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace';
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

  const imageProvider = (process.env['IMAGE_PROVIDER'] ?? 'fal') as AppConfig['IMAGE_PROVIDER'];
  if (!['fal', 'lambda', 'auto'].includes(imageProvider)) {
    throw new Error(`Invalid IMAGE_PROVIDER: ${imageProvider} (expected 'fal', 'lambda', or 'auto')`);
  }
  const falKey = process.env['FAL_KEY'] ?? '';
  if (imageProvider === 'fal' && !falKey && nodeEnv !== 'test') {
    throw new Error("IMAGE_PROVIDER=fal requires FAL_KEY (fal.ai API key) to be set");
  }
  const lambdaVideoUrl = process.env['LAMBDA_VIDEO_URL'] ?? '';
  if (lambdaVideoUrl && !/^wss?:\/\//.test(lambdaVideoUrl)) {
    throw new Error(`Invalid LAMBDA_VIDEO_URL: ${lambdaVideoUrl} (expected ws:// or wss:// URL)`);
  }

  const lambdaImageUrl = process.env['LAMBDA_IMAGE_URL'] ?? '';
  const lambdaDevPoolEnabled = process.env['LAMBDA_DEV_POOL_ENABLED'] === 'true';
  if (imageProvider === 'lambda' && !/^wss?:\/\//.test(lambdaImageUrl) && !lambdaDevPoolEnabled) {
    throw new Error(
      'IMAGE_PROVIDER=lambda requires LAMBDA_IMAGE_URL (static instance) or LAMBDA_DEV_POOL_ENABLED=true',
    );
  }

  return {
    PORT: port,
    HOST: process.env['HOST'] ?? '0.0.0.0',
    JWT_ACCESS_SECRET: jwtAccessSecret,
    JWT_REFRESH_SECRET: jwtRefreshSecret,
    APPLE_BUNDLE_ID: appleBundleId,
    APPLE_APP_APPLE_ID: Number(process.env['APPLE_APP_APPLE_ID'] ?? 0),
    AUTH_REQUIRED: process.env['AUTH_REQUIRED'] === 'true',
    FREE_TIER_FAL_USD: Number(process.env['FREE_TIER_FAL_USD'] ?? 10),
    IMAGE_PROVIDER: imageProvider,
    LAMBDA_IMAGE_URL: lambdaImageUrl,
    LAMBDA_API_KEY: process.env['LAMBDA_API_KEY'] ?? '',
    LAMBDA_DEV_POOL_ENABLED: lambdaDevPoolEnabled,
    LAMBDA_REGION: process.env['LAMBDA_REGION'] ?? 'us-south-2',
    LAMBDA_INSTANCE_TYPE: process.env['LAMBDA_INSTANCE_TYPE'] ?? 'gpu_1x_h100_sxm5',
    LAMBDA_POOL_MIN: Number(process.env['LAMBDA_POOL_MIN'] ?? 0),
    LAMBDA_POOL_MAX: Number(process.env['LAMBDA_POOL_MAX'] ?? 3),
    LAMBDA_POOL_TARGET_STREAMS: Number(process.env['LAMBDA_POOL_TARGET_STREAMS'] ?? 4),
    LAMBDA_TLS_CA: process.env['LAMBDA_TLS_CA_B64']
      ? Buffer.from(process.env['LAMBDA_TLS_CA_B64'], 'base64').toString('utf-8')
      : '',
    LAMBDA_VIDEO_URL: lambdaVideoUrl,
    VIDEO_IDLE_TRIGGER_MS: Number(process.env['VIDEO_IDLE_TRIGGER_MS'] ?? 3000),
    FAL_KEY: falKey,
    FAL_IDLE_CLOSE_MS: Number(process.env['FAL_IDLE_CLOSE_MS'] ?? 0),
    FAL_WARMER_ENABLED: process.env['FAL_WARMER_ENABLED'] !== 'false',
    FAL_WARMER_INTERVAL_MS: Number(process.env['FAL_WARMER_INTERVAL_MS'] ?? 90_000),
    FAL_WARMER_OFF_START_HOUR: Number(process.env['FAL_WARMER_OFF_START_HOUR'] ?? 2),
    FAL_WARMER_OFF_END_HOUR: Number(process.env['FAL_WARMER_OFF_END_HOUR'] ?? 8),
    SESSION_CAPTURE_ENABLED: process.env['SESSION_CAPTURE_ENABLED'] !== 'false',
    SESSION_CAPTURE_MIN_INTERVAL_MS: Number(process.env['SESSION_CAPTURE_MIN_INTERVAL_MS'] ?? 1000),
    SESSION_CAPTURE_MAX_FRAMES: Number(process.env['SESSION_CAPTURE_MAX_FRAMES'] ?? 600),
    DATABASE_URL: databaseUrl,
    INSIGHTS_URL: process.env['INSIGHTS_URL'] ?? '',
    INSIGHTS_INGEST_KEY: process.env['INSIGHTS_INGEST_KEY'] ?? '',
    NODE_ENV: nodeEnv,
    LOG_LEVEL: logLevel,
  };
}

export const config: AppConfig = validateConfig();
