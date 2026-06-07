/**
 * Apply schema.sql. Idempotent (all CREATE ... IF NOT EXISTS). Run at boot from
 * index.ts and also exposed as `npm run migrate` for manual use.
 */

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { pool } from './db.js';

const here = dirname(fileURLToPath(import.meta.url));

export async function migrate(): Promise<void> {
  // schema.sql sits next to this file in src/ and is copied to dist/ at build.
  const sqlPath = join(here, 'schema.sql');
  const sql = await readFile(sqlPath, 'utf8');
  await pool.query(sql);
}

// Allow `tsx src/migrate.ts` / `node dist/migrate.js` standalone.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  migrate()
    .then(() => {
      console.log('Kiki Insights schema applied.');
      return pool.end();
    })
    .catch((err: unknown) => {
      console.error('Migration failed:', err);
      process.exit(1);
    });
}
