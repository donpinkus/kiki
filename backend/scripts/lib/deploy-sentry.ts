/**
 * Sentry init for deploy CLI scripts (deploy.ts, sync-all-dcs.ts, sync-flux-app.ts).
 *
 * Pipes console.log/info/warn/error into the Sentry Logs product so deploy
 * activity is correlatable with pod boot logs and backend events. Every log
 * carries `phase=deploying` for cross-stack filtering — distinct from the
 * user-journey phases (session_starting, drawing, animating, etc.).
 *
 * No-op when SENTRY_DSN is unset (so devs without a local Sentry config can
 * still run `npm run deploy` without errors). Reads from .env.local at the
 * repo root or from process.env (Railway sets it on the deployed backend).
 *
 * Each deploy CLI script runs as its own Node process (deploy.ts spawns
 * sync-all-dcs.ts which spawns sync-flux-app.ts), so each must call
 * `initDeployLogging()` at top and `await flushDeployLogging()` before
 * `process.exit()` so logs aren't dropped.
 */

import * as Sentry from '@sentry/node';
import { existsSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..', '..', '..');

let initialized = false;
const extraAttributes: Record<string, string | number | boolean> = {};

function loadDsnFromEnvLocal(): string | undefined {
  if (process.env['SENTRY_DSN']) return process.env['SENTRY_DSN'];
  const path = resolve(REPO_ROOT, '.env.local');
  if (!existsSync(path)) return undefined;
  const content = readFileSync(path, 'utf-8');
  for (const line of content.split('\n')) {
    const m = line.match(/^SENTRY_DSN=(.*)$/);
    if (!m || !m[1]) continue;
    let value = m[1];
    if (
      (value.startsWith("'") && value.endsWith("'")) ||
      (value.startsWith('"') && value.endsWith('"'))
    ) {
      value = value.slice(1, -1);
    }
    return value;
  }
  return undefined;
}

export function initDeployLogging(scriptName: string): void {
  if (initialized) return;
  const dsn = loadDsnFromEnvLocal();
  if (!dsn) return;
  Sentry.init({
    dsn,
    environment: 'deploy',
    enabled: true,
    enableLogs: true,
    integrations: [
      Sentry.consoleLoggingIntegration({ levels: ['log', 'info', 'warn', 'error'] }),
    ],
    beforeSendLog: (log) => {
      log.attributes ??= {};
      log.attributes['phase'] = 'deploying';
      log.attributes['script'] = scriptName;
      for (const [k, v] of Object.entries(extraAttributes)) {
        log.attributes[k] = v;
      }
      return log;
    },
  });
  Sentry.setTag('component', 'deploy-script');
  Sentry.setTag('script', scriptName);
  initialized = true;
}

/**
 * Attach an additional attribute to every log emitted by this process from
 * now on. Use after init when a value (e.g. the DC name in sync-flux-app.ts)
 * isn't known until after CLI args are parsed.
 */
export function setLogAttribute(key: string, value: string | number | boolean): void {
  extraAttributes[key] = value;
}

export async function flushDeployLogging(): Promise<void> {
  if (!initialized) return;
  await Sentry.flush(5000);
}
