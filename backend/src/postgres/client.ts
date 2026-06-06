/**
 * Postgres connection pool + tiny query helper — the durable store for user
 * accounts (and, later, the usage ledger). Mirrors the `analytics/` service's
 * `db.ts` so the two Postgres-touching codebases stay consistent.
 *
 * One shared `pg.Pool` for the process (pg opens connections lazily on first
 * query, so importing this module is cheap and doesn't block boot). Reach for
 * `query` at call sites; use `pool` directly for transactions.
 */

import pg, { type QueryResult, type QueryResultRow } from 'pg';

import { config } from '../config/index.js';

export const pool = new pg.Pool({
  connectionString: config.DATABASE_URL,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
});

export async function query<T extends QueryResultRow = QueryResultRow>(
  text: string,
  params?: unknown[],
): Promise<QueryResult<T>> {
  return pool.query<T>(text, params as never[]);
}

/** Connect + `SELECT 1` to fail fast on bad config at boot. */
export async function ensureDb(): Promise<void> {
  const r = await pool.query('SELECT 1 AS ok');
  if (r.rows[0]?.['ok'] !== 1) {
    throw new Error('Postgres health check returned unexpected result');
  }
}
