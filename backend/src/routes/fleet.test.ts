import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import Fastify from 'fastify';

const fleetDir = mkdtempSync(join(tmpdir(), 'kiki-fleet-'));
process.env['FLEET_DIR'] = fleetDir;
process.env['LAMBDA_API_KEY'] = 'test-lambda-key';
process.env['DATABASE_URL'] ??= 'postgres://x:y@localhost:5432/test';

const { fleetRoute, fleetToken } = await import('../modules/lambda/fleet.js');

describe('fleet bundle routes', () => {
  const app = Fastify();
  beforeAll(async () => {
    await app.register(fleetRoute);
    await app.ready();
  });
  afterAll(async () => {
    await app.close();
  });

  it('rejects a missing or wrong bearer', async () => {
    expect((await app.inject({ method: 'GET', url: '/v1/fleet/manifest' })).statusCode).toBe(401);
    expect(
      (await app.inject({ method: 'GET', url: '/v1/fleet/bundle', headers: { authorization: 'Bearer nope' } })).statusCode,
    ).toBe(401);
  });

  it('404s when the deploy carried no bundle (bare railway up)', async () => {
    const r = await app.inject({ method: 'GET', url: '/v1/fleet/manifest', headers: { authorization: `Bearer ${fleetToken()}` } });
    expect(r.statusCode).toBe(404);
  });

  it('serves manifest + bundle to the fleet token', async () => {
    writeFileSync(join(fleetDir, 'manifest.json'), JSON.stringify({ sha256: 'abc', git_sha: 'g', built_at: 't', files: 1, bytes: 1 }));
    writeFileSync(join(fleetDir, 'model-servers.tgz'), Buffer.from([0x1f, 0x8b, 0x08, 0x00]));
    const m = await app.inject({ method: 'GET', url: '/v1/fleet/manifest', headers: { authorization: `Bearer ${fleetToken()}` } });
    expect(m.statusCode).toBe(200);
    expect(m.json()).toMatchObject({ sha256: 'abc' });
    const b = await app.inject({ method: 'GET', url: '/v1/fleet/bundle', headers: { authorization: `Bearer ${fleetToken()}` } });
    expect(b.statusCode).toBe(200);
    expect(b.headers['content-type']).toContain('application/gzip');
    expect(b.rawPayload.length).toBe(4);
  });
});
