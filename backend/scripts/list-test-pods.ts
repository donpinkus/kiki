/**
 * List all live `kiki-vtest-*` test pods.
 *
 * Useful for: figuring out which pod ID to terminate; checking whether
 * a test pod from yesterday is still running and burning credits;
 * spotting forgotten pods at the start of a session.
 *
 * Usage (from backend/):
 *   npm run list-test-pods
 */

import { existsSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { listPodsByPrefix, getPod } from '../src/modules/orchestrator/runpodClient.js';

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

if (!process.env['RUNPOD_API_KEY']) {
  console.error('RUNPOD_API_KEY required (set in .env.local at repo root)');
  process.exit(1);
}

const VIDEO_TEST_PREFIX = 'kiki-vtest-';

async function main(): Promise<void> {
  const pods = await listPodsByPrefix(VIDEO_TEST_PREFIX);
  if (pods.length === 0) {
    console.log('No test pods running.');
    return;
  }
  console.log(`${pods.length} test pod(s):\n`);
  for (const summary of pods) {
    const pod = await getPod(summary.id);
    const dc = pod?.machine?.dataCenterId ?? '?';
    const uptime = pod?.runtime?.uptimeInSeconds ?? 0;
    const sshPort = pod?.runtime?.ports?.find((p) => p.privatePort === 22)?.publicPort;
    const sshIp = pod?.runtime?.ports?.find((p) => p.privatePort === 22)?.ip;
    const uptimeHrs = (uptime / 3600).toFixed(1);
    console.log(`  ${summary.id}  name=${summary.name}  dc=${dc}  status=${summary.desiredStatus}  uptime=${uptimeHrs}h`);
    if (sshIp && sshPort) {
      console.log(`    ssh root@${sshIp} -p ${sshPort} -i ~/.ssh/id_ed25519`);
    }
    console.log(`    npm run terminate-test-pod -- ${summary.id}`);
    console.log('');
  }
}

main().catch((err) => {
  console.error('[list-test-pods] failed:', err);
  process.exit(1);
});
