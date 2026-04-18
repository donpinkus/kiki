// Minimal env so `src/config/index.ts` validateConfig() passes when imported
// under test. Real prod values live in Railway.
const DUMMY_SECRET = 'x'.repeat(64);

process.env['RUNPOD_API_KEY'] = process.env['RUNPOD_API_KEY'] ?? 'test-runpod-key';
process.env['RUNPOD_SSH_PRIVATE_KEY'] =
  process.env['RUNPOD_SSH_PRIVATE_KEY'] ?? 'test-ssh-key';
process.env['JWT_ACCESS_SECRET'] =
  process.env['JWT_ACCESS_SECRET'] ?? DUMMY_SECRET;
process.env['JWT_REFRESH_SECRET'] =
  process.env['JWT_REFRESH_SECRET'] ?? `${DUMMY_SECRET}-refresh`;
process.env['APPLE_BUNDLE_ID'] =
  process.env['APPLE_BUNDLE_ID'] ?? 'com.kiki.test';
process.env['REDIS_URL'] = process.env['REDIS_URL'] ?? 'redis://localhost:6379';
