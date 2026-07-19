/**
 * Route-level tests of POST /v1/edit with the fal call, budget, and analytics
 * mocked. Auth is bypassed by decorating request.userId directly (in prod the
 * global installAuth gate provides it).
 */
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { FastifyInstance } from 'fastify';

const falKleinEdit = vi.fn();
const checkFalBudget = vi.fn();
const addMonthlySpendUsd = vi.fn();
const trackImageEdit = vi.fn();

vi.mock('../modules/fal/falEdit.js', () => ({ falKleinEdit }));
vi.mock('../modules/falBudget/index.js', () => ({ checkFalBudget, addMonthlySpendUsd }));
vi.mock('../modules/analytics/index.js', () => ({ trackImageEdit }));

const RESULT_PNG = Buffer.from('fake-png-bytes');
const SOURCE_B64 = Buffer.from([0xff, 0xd8, 0x01, 0x02]).toString('base64'); // JPEG magic

describe('/v1/edit', () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    const { default: Fastify } = await import('fastify');
    const { editRoute } = await import('./edit.js');
    app = Fastify({ logger: false });
    app.decorateRequest('userId', '');
    app.addHook('onRequest', async (req) => {
      req.userId = 'test-user';
    });
    await app.register(editRoute);
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
  });

  beforeEach(() => {
    vi.clearAllMocks();
    checkFalBudget.mockResolvedValue({ allowed: true, exempt: false, spendUsd: 0, capUsd: 10 });
    falKleinEdit.mockResolvedValue({
      image: RESULT_PNG,
      contentType: 'image/png',
      width: 1024,
      height: 1024,
      seed: 42,
      elapsedMs: 3000,
    });
  });

  it('400s without prompt or image', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/v1/edit',
      payload: { imageBase64: SOURCE_B64 },
    });
    expect(res.statusCode).toBe(400);
  });

  it('402s when the free-tier cap is hit', async () => {
    checkFalBudget.mockResolvedValue({ allowed: false, exempt: false, spendUsd: 10, capUsd: 10 });
    const res = await app.inject({
      method: 'POST',
      url: '/v1/edit',
      payload: { imageBase64: SOURCE_B64, prompt: 'make it brick' },
    });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ error: 'free_limit_reached' });
    expect(falKleinEdit).not.toHaveBeenCalled();
  });

  it('edits, bills non-exempt users, and returns the image', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/v1/edit',
      payload: { imageBase64: SOURCE_B64, prompt: ' make it brick ', scope: 'region', steps: 8, seed: 7 },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json() as { imageBase64: string; width: number; seed: number };
    expect(Buffer.from(body.imageBase64, 'base64')).toEqual(RESULT_PNG);
    expect(body.width).toBe(1024);
    expect(body.seed).toBe(42);

    const call = falKleinEdit.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(call['prompt']).toBe('make it brick'); // trimmed
    expect(call['imageContentType']).toBe('image/jpeg'); // sniffed from magic
    expect(call['steps']).toBe(8);
    expect(call['seed']).toBe(7);

    expect(addMonthlySpendUsd).toHaveBeenCalledWith('test-user', expect.any(Number));
    expect(trackImageEdit).toHaveBeenCalledWith(expect.objectContaining({ scope: 'region' }));
  });

  it('does not bill exempt users', async () => {
    checkFalBudget.mockResolvedValue({ allowed: true, exempt: true, spendUsd: 0, capUsd: 10 });
    const res = await app.inject({
      method: 'POST',
      url: '/v1/edit',
      payload: { imageBase64: SOURCE_B64, prompt: 'smooth the lines' },
    });
    expect(res.statusCode).toBe(200);
    expect(addMonthlySpendUsd).not.toHaveBeenCalled();
  });

  it('502s when the fal call fails', async () => {
    falKleinEdit.mockRejectedValue(new Error('fal edit HTTP 500: boom'));
    const res = await app.inject({
      method: 'POST',
      url: '/v1/edit',
      payload: { imageBase64: SOURCE_B64, prompt: 'x' },
    });
    expect(res.statusCode).toBe(502);
    expect(res.json()).toMatchObject({ error: 'edit_failed' });
    expect(addMonthlySpendUsd).not.toHaveBeenCalled();
  });
});
