/**
 * User account repository (Postgres) — the durable system-of-record for
 * identity, replacing the former Redis `user:{userId}` / `apple-sub:{sub}`
 * hash. `apple_sub` is UNIQUE, so the upsert dedups across deploys natively.
 */

import { randomUUID } from 'node:crypto';

import { query } from './client.js';

export interface UserRecord {
  userId: string;
  appleSub: string;
  email?: string;
  createdAt: number; // epoch ms
  isNew: boolean;
}

interface UserRow {
  user_id: string;
  apple_sub: string;
  email: string | null;
  created_at_ms: string; // numeric comes back as string from pg
  inserted: boolean;
}

/**
 * Find-or-create a user by their Apple `sub`. Atomic: a fresh sign-in inserts a
 * new `randomUUID()` row; a returning sign-in hits the UNIQUE(apple_sub)
 * conflict and yields the existing `user_id` (never re-minted). Email is kept
 * from the first sign-in that supplied one (Apple only returns it on first
 * authorization) and only backfilled if previously null.
 */
export async function upsertUserByAppleSub(
  appleSub: string,
  email?: string,
): Promise<UserRecord> {
  const res = await query<UserRow>(
    `INSERT INTO users (user_id, apple_sub, email)
     VALUES ($1, $2, $3)
     ON CONFLICT (apple_sub) DO UPDATE
       SET email = COALESCE(users.email, EXCLUDED.email),
           updated_at = now()
     RETURNING user_id,
               apple_sub,
               email,
               (EXTRACT(EPOCH FROM created_at) * 1000)::bigint AS created_at_ms,
               (xmax = 0) AS inserted`,
    [randomUUID(), appleSub, email ?? null],
  );
  const row = res.rows[0];
  if (!row) throw new Error('upsertUserByAppleSub returned no row');
  return {
    userId: row.user_id,
    appleSub: row.apple_sub,
    email: row.email ?? undefined,
    createdAt: Number(row.created_at_ms),
    isNew: row.inserted,
  };
}

export async function getUserEmail(userId: string): Promise<string | undefined> {
  const res = await query<{ email: string | null }>(
    'SELECT email FROM users WHERE user_id = $1',
    [userId],
  );
  return res.rows[0]?.email ?? undefined;
}
