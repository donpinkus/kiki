export interface AppConfig {
  readonly PORT: number;
  readonly HOST: string;
  readonly RUNPOD_API_KEY: string;
  readonly RUNPOD_SSH_PRIVATE_KEY: string;
  /** Optional RunPod container registry credential ID for authenticated Docker
   * Hub pulls. Strongly recommended in production to bypass anonymous rate
   * limits (100 pulls/6hr per IP). */
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

  const runpodApiKey = process.env['RUNPOD_API_KEY'] ?? '';
  if (!runpodApiKey) {
    throw new Error('RUNPOD_API_KEY is required (orchestrator needs it to create/query/terminate pods)');
  }

  const runpodSshKey = process.env['RUNPOD_SSH_PRIVATE_KEY'] ?? '';
  if (!runpodSshKey) {
    throw new Error('RUNPOD_SSH_PRIVATE_KEY is required (orchestrator SSHes into pods to run setup)');
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
    RUNPOD_SSH_PRIVATE_KEY: runpodSshKey,
    RUNPOD_REGISTRY_AUTH_ID: process.env['RUNPOD_REGISTRY_AUTH_ID'] ?? '',
    JWT_ACCESS_SECRET: jwtAccessSecret,
    JWT_REFRESH_SECRET: jwtRefreshSecret,
    APPLE_BUNDLE_ID: appleBundleId,
    AUTH_REQUIRED: process.env['AUTH_REQUIRED'] === 'true',
    FREE_TIER_SECONDS: Number(process.env['FREE_TIER_SECONDS'] ?? 3600),
    NODE_ENV: nodeEnv,
    LOG_LEVEL: logLevel,
  };
}

export const config: AppConfig = validateConfig();
