/**
 * Script-side entry for the Lambda Cloud client.
 *
 * The actual client lives in src/modules/lambda/client.ts (shared with the
 * runtime dev-pool orchestrator). This wrapper adds the script conveniences:
 * .env.local loading from the repo root and requireClient().
 */

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LambdaClient, type LambdaInstance } from '../../src/modules/lambda/client.js';

export {
  LambdaApiError,
  LambdaClient,
  launchWithRetry,
  isTransientNetworkError,
  lambdaSleep as sleep,
  type InstanceTypeEntry,
  type LaunchRequest,
  type SshKey,
  type Filesystem,
  type FirewallRule,
} from '../../src/modules/lambda/client.js';

/** Alias kept for existing scripts. */
export type Instance = LambdaInstance;

const __dirname = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(__dirname, '..', '..', '..');

export function loadEnvLocal(): void {
  try {
    const content = readFileSync(resolve(REPO_ROOT, '.env.local'), 'utf-8');
    for (const line of content.split('\n')) {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m && m[1] && !process.env[m[1]]) process.env[m[1]] = m[2];
    }
  } catch {
    // No .env.local — env vars must already be set
  }
}

export function requireClient(): LambdaClient {
  loadEnvLocal();
  const key = process.env['LAMBDA_API_KEY'];
  if (!key) {
    console.error(
      'LAMBDA_API_KEY is required. Create one at https://cloud.lambda.ai/api-keys and add\n' +
        `LAMBDA_API_KEY=... to ${resolve(REPO_ROOT, '.env.local')}`,
    );
    process.exit(1);
  }
  return new LambdaClient(key);
}