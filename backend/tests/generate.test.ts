import { describe, it, expect } from 'vitest';
import { buildApp } from '../src/app.js';

describe('POST /v1/generate', () => {
  it('validates required fields', async () => {
    const app = buildApp();

    const response = await app.inject({
      method: 'POST',
      url: '/v1/generate',
      payload: {},
    });

    expect(response.statusCode).toBe(400);
  });

  it('accepts valid request and returns mock response', async () => {
    const app = buildApp();

    const response = await app.inject({
      method: 'POST',
      url: '/v1/generate',
      payload: {
        sessionId: 'test-session',
        requestId: 'test-request-1',
        mode: 'preview',
        sketchImageBase64: 'dGVzdA==',
      },
    });

    expect(response.statusCode).toBe(200);
    const body = JSON.parse(response.body);
    expect(body.requestId).toBe('test-request-1');
    expect(body.status).toBe('completed');
    expect(body.provider).toBe('fal-mock');
  });
});

describe('POST /v1/cancel', () => {
  it('acknowledges cancel request', async () => {
    const app = buildApp();

    const response = await app.inject({
      method: 'POST',
      url: '/v1/cancel',
      payload: {
        sessionId: 'test-session',
        requestId: 'test-request-1',
      },
    });

    expect(response.statusCode).toBe(200);
    const body = JSON.parse(response.body);
    expect(body.acknowledged).toBe(true);
  });
});
