/**
 * Config loading + validation for Kiki Insights.
 *
 * Mirrors the prod backend's fail-fast pattern: validate everything required at
 * boot, throw a single aggregated error listing all problems. Reads .env.local
 * in development (via the dotenv-free manual loader below) — on Railway the vars
 * come from the service environment directly.
 */

export interface InsightsConfig {
  readonly PORT: number;
  readonly HOST: string;
  readonly NODE_ENV: string;
  readonly LOG_LEVEL: string;

  /** Postgres connection string. */
  readonly DATABASE_URL: string;

  /** Shared with backend — used to VERIFY iOS access tokens on /ingest. */
  readonly JWT_ACCESS_SECRET: string;
  /** Service key the backend presents (x-insights-key) for server-side events. */
  readonly INSIGHTS_INGEST_KEY: string;

  /** Admin dashboard password (single internal user). */
  readonly ADMIN_PASSWORD: string;
  /** HS256 secret for signing the admin session cookie. */
  readonly ADMIN_SESSION_SECRET: string;

  /** Directory where blob assets are stored (Railway volume mount in prod). */
  readonly BLOB_DIR: string;
}

function num(name: string, value: string | undefined, fallback: number): number {
  if (value === undefined || value === '') return fallback;
  const n = Number(value);
  if (!Number.isFinite(n)) throw new Error(`${name} must be a number, got "${value}"`);
  return n;
}

function loadConfig(): InsightsConfig {
  const errors: string[] = [];
  const env = process.env;

  function required(name: string, opts?: { minLen?: number }): string {
    const v = env[name];
    if (!v) {
      errors.push(`${name} is required`);
      return '';
    }
    if (opts?.minLen && v.length < opts.minLen) {
      errors.push(`${name} must be at least ${opts.minLen} characters`);
    }
    return v;
  }

  const cfg: InsightsConfig = {
    PORT: num('PORT', env['PORT'], 8080),
    HOST: env['HOST'] ?? '0.0.0.0',
    NODE_ENV: env['NODE_ENV'] ?? 'development',
    LOG_LEVEL: env['LOG_LEVEL'] ?? 'info',
    DATABASE_URL: required('DATABASE_URL'),
    JWT_ACCESS_SECRET: required('JWT_ACCESS_SECRET', { minLen: 16 }),
    INSIGHTS_INGEST_KEY: required('INSIGHTS_INGEST_KEY', { minLen: 16 }),
    ADMIN_PASSWORD: required('ADMIN_PASSWORD'),
    ADMIN_SESSION_SECRET: required('ADMIN_SESSION_SECRET', { minLen: 32 }),
    BLOB_DIR: env['BLOB_DIR'] ?? './blobs',
  };

  if (errors.length > 0) {
    throw new Error(`Invalid Kiki Insights config:\n  - ${errors.join('\n  - ')}`);
  }
  return cfg;
}

export const config = loadConfig();
