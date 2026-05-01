/**
 * Terminate a manually-managed video test pod.
 *
 * Test pods (kiki-vtest-*) are NOT auto-reaped, so this script is the
 * cleanup mechanism. Companion to launch-test-pod.ts.
 *
 * Usage (from backend/):
 *   npm run terminate-test-pod -- <podId>
 *   npm run terminate-test-pod -- <podId1> <podId2>   # multiple
 *
 * Pod IDs are printed by launch-test-pod and visible in `npm run
 * list-test-pods` and the RunPod web console.
 *
 * Safety: refuses to terminate any pod whose name doesn't start with
 * `kiki-vtest-` to prevent accidentally killing a real session pod.
 */

import { existsSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { getPod, terminatePod, listPodsByPrefix } from '../src/modules/orchestrator/runpodClient.js';

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
  const podIds = process.argv.slice(2);
  if (podIds.length === 0) {
    console.error('Usage: npm run terminate-test-pod -- <podId> [<podId>...]');
    console.error('       npm run list-test-pods  # to see what is alive');
    process.exit(1);
  }

  // Look up all current test pods so we can verify the requested IDs
  // actually have the test prefix. Refuses to kill anything else.
  const livePods = await listPodsByPrefix(VIDEO_TEST_PREFIX);
  const liveIds = new Set(livePods.map((p) => p.id));

  for (const podId of podIds) {
    if (!liveIds.has(podId)) {
      // Could be already gone, or could be a non-test pod ID. Look it up
      // to give a better error.
      const pod = await getPod(podId);
      if (!pod) {
        console.log(`[terminate-test-pod] ${podId}: not found (already terminated?)`);
        continue;
      }
      // Pod exists but isn't in the test-prefix list — refuse.
      console.error(
        `[terminate-test-pod] ${podId}: not a test pod (refuses to terminate ` +
          `anything outside the ${VIDEO_TEST_PREFIX} prefix to protect production sessions). ` +
          `If this is intentional, terminate via the RunPod web console.`,
      );
      process.exit(1);
    }
    console.log(`[terminate-test-pod] terminating ${podId}...`);
    await terminatePod(podId);
    console.log(`[terminate-test-pod] ✅ terminated ${podId}`);
  }
}

main().catch((err) => {
  console.error('[terminate-test-pod] failed:', err);
  process.exit(1);
});
