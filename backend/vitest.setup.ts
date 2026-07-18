// Minimal env so `src/config/index.ts` validateConfig() passes when imported
// under test. Real prod values live in Railway.
const DUMMY_SECRET = 'x'.repeat(64);

process.env['JWT_ACCESS_SECRET'] =
  process.env['JWT_ACCESS_SECRET'] ?? DUMMY_SECRET;
process.env['JWT_REFRESH_SECRET'] =
  process.env['JWT_REFRESH_SECRET'] ?? `${DUMMY_SECRET}-refresh`;
process.env['APPLE_BUNDLE_ID'] =
  process.env['APPLE_BUNDLE_ID'] ?? 'com.kiki.test';
process.env['DATABASE_URL'] =
  process.env['DATABASE_URL'] ?? 'postgres://localhost:5432/kiki_test';
