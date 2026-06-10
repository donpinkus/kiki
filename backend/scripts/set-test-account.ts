/**
 * Admin: mark a user account as a test account (exempt from the fal-spend cap),
 * and/or reset their current-month fal spend.
 *
 * The free-tier cap (`FREE_TIER_FAL_USD`, $10/UTC-month of fal drawing spend)
 * is enforced in `modules/falBudget/checkFalBudget`. `users.is_test_account =
 * true` makes a user `exempt` (so does an active subscription) — the durable
 * "no limit" switch. `--reset-spend` instead (or additionally) zeroes the
 * current month's `monthly_usage` row, a one-time reset that lets the cap come
 * back next month / once $10 is spent again.
 *
 * Identify the user by `--email` (Apple only returns an email on the FIRST
 * sign-in, so the row's email is whatever was supplied then) or `--user-id`.
 *
 * Self-contained: needs only DATABASE_URL (does NOT import the backend config,
 * so it won't demand RUNPOD_API_KEY / JWT secrets / etc.). Reads DATABASE_URL
 * from the environment, or from .env.local at the repo root.
 *
 * Usage — run where DATABASE_URL points at the production Postgres, e.g.:
 *   railway run --service kiki-backend npm run set-test-account -- --email don.pinkus@gmail.com
 *
 *   # mark as test account (default action):
 *   npm run set-test-account -- --email don.pinkus@gmail.com
 *   # also wipe this month's accrued spend:
 *   npm run set-test-account -- --email don.pinkus@gmail.com --reset-spend
 *   # ONLY reset spend, leave the test flag alone:
 *   npm run set-test-account -- --email don.pinkus@gmail.com --reset-spend --no-test-flag
 *   # remove the test-account flag again:
 *   npm run set-test-account -- --email don.pinkus@gmail.com --unset
 *   # look without touching:
 *   npm run set-test-account -- --email don.pinkus@gmail.com --dry-run
 */

import { existsSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import pg from 'pg';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..', '..');

function loadEnvLocal(): void {
  const path = resolve(REPO_ROOT, '.env.local');
  if (!existsSync(path)) return;
  const content = readFileSync(path, 'utf-8');
  for (const line of content.split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (!m || !m[1]) continue;
    if (process.env[m[1]]) continue;
    let value = m[2] ?? '';
    if (
      (value.startsWith("'") && value.endsWith("'")) ||
      (value.startsWith('"') && value.endsWith('"'))
    ) {
      value = value.slice(1, -1);
    }
    process.env[m[1]] = value;
  }
}
loadEnvLocal();

interface Args {
  email?: string;
  userId?: string;
  setTestFlag: boolean; // true = set, false = unset
  applyTestFlag: boolean; // whether to touch the flag at all
  resetSpend: boolean;
  dryRun: boolean;
}

function parseArgs(argv: string[]): Args {
  const args: Args = {
    setTestFlag: true,
    applyTestFlag: true,
    resetSpend: false,
    dryRun: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--email':
        args.email = argv[++i];
        break;
      case '--user-id':
        args.userId = argv[++i];
        break;
      case '--reset-spend':
        args.resetSpend = true;
        break;
      case '--unset':
        args.setTestFlag = false;
        break;
      case '--no-test-flag':
        args.applyTestFlag = false;
        break;
      case '--dry-run':
        args.dryRun = true;
        break;
      default:
        console.error(`Unknown argument: ${a}`);
        process.exit(1);
    }
  }
  return args;
}

interface UserRow {
  user_id: string;
  email: string | null;
  is_test_account: boolean;
  subscription_status: string;
  subscription_expires_at: Date | null;
}

const FREE_TIER_FAL_USD = Number(process.env['FREE_TIER_FAL_USD'] ?? 10);

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (!args.email && !args.userId) {
    console.error('Provide --email <addr> or --user-id <uuid>.');
    process.exit(1);
  }
  if (!process.env['DATABASE_URL']) {
    console.error(
      'DATABASE_URL required. Run via `railway run --service kiki-backend ...`,\n' +
        'or put DATABASE_URL in .env.local at the repo root.',
    );
    process.exit(1);
  }

  const pool = new pg.Pool({
    connectionString: process.env['DATABASE_URL'],
    connectionTimeoutMillis: 10_000,
  });

  try {
    // Resolve the user (and reject ambiguous email matches rather than guessing).
    const where = args.userId ? 'user_id = $1' : 'email = $1';
    const key = args.userId ?? args.email!;
    const found = await pool.query<UserRow>(
      `SELECT user_id, email, is_test_account, subscription_status, subscription_expires_at
         FROM users WHERE ${where}`,
      [key],
    );
    if (found.rows.length === 0) {
      console.error(`No user found for ${args.userId ? 'user_id' : 'email'}=${key}.`);
      process.exit(1);
    }
    if (found.rows.length > 1) {
      console.error(
        `Ambiguous: ${found.rows.length} users match email=${key}. ` +
          `Re-run with --user-id. Candidates:`,
      );
      for (const r of found.rows) console.error(`  ${r.user_id}`);
      process.exit(1);
    }
    const user = found.rows[0]!;
    const month = new Date().toISOString().slice(0, 7); // YYYY-MM (UTC)

    const spendBefore = await pool.query<{ fal_spend_usd: string }>(
      `SELECT fal_spend_usd FROM monthly_usage WHERE user_id = $1 AND month = $2`,
      [user.user_id, month],
    );
    const spendUsd = Number(spendBefore.rows[0]?.fal_spend_usd ?? 0);

    console.log('Current state:');
    console.log(`  user_id              ${user.user_id}`);
    console.log(`  email                ${user.email ?? '(none)'}`);
    console.log(`  is_test_account      ${user.is_test_account}`);
    console.log(`  subscription_status  ${user.subscription_status}`);
    console.log(`  this month (${month})   $${spendUsd.toFixed(4)} of $${FREE_TIER_FAL_USD} cap`);
    console.log('');

    const plan: string[] = [];
    if (args.applyTestFlag) {
      plan.push(`set is_test_account = ${args.setTestFlag}`);
    }
    if (args.resetSpend) {
      plan.push(`reset ${month} fal spend ($${spendUsd.toFixed(4)} -> $0)`);
    }
    if (plan.length === 0) {
      console.log('Nothing to do (--no-test-flag with no --reset-spend).');
      return;
    }

    console.log(`Plan: ${plan.join('; ')}.`);
    if (args.dryRun) {
      console.log('(--dry-run: no changes written.)');
      return;
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      if (args.applyTestFlag) {
        await client.query(
          `UPDATE users SET is_test_account = $2, updated_at = now() WHERE user_id = $1`,
          [user.user_id, args.setTestFlag],
        );
      }
      if (args.resetSpend) {
        await client.query(
          `UPDATE monthly_usage SET fal_spend_usd = 0, updated_at = now()
             WHERE user_id = $1 AND month = $2`,
          [user.user_id, month],
        );
      }
      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }

    const after = await pool.query<UserRow>(
      `SELECT is_test_account FROM users WHERE user_id = $1`,
      [user.user_id],
    );
    console.log('');
    console.log('Done. New state:');
    console.log(`  is_test_account      ${after.rows[0]?.is_test_account}`);
    if (args.resetSpend) console.log(`  this month (${month})   $0.0000`);
    if (args.applyTestFlag && args.setTestFlag) {
      console.log('\nThe fal-spend cap no longer applies to this account (exempt).');
    }
  } finally {
    await pool.end();
  }
}

main().catch((err: unknown) => {
  console.error('[set-test-account] failed:', err);
  process.exit(1);
});
