import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer } from 'ws';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { StreamRelay } from './streamRelay.js';

/** Spin up a tiny HTTP server that rejects every WS upgrade with 404.
 * Mirrors the incident pattern where the pod's /ws briefly 404'd. */
function startRejectingServer(): Promise<{ url: string; close: () => Promise<void> }> {
  return new Promise((resolve) => {
    const server = createServer();
    server.on('upgrade', (_req, socket) => {
      socket.write('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n');
      socket.destroy();
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      resolve({
        url: `ws://127.0.0.1:${port}/ws`,
        close: () => new Promise<void>((res) => server.close(() => res())),
      });
    });
  });
}

/** Server that accepts WS, optionally sends a message, then closes. */
function startAcceptingServer(opts: { closeAfterMs?: number } = {}): Promise<{
  url: string;
  close: () => Promise<void>;
  server: Server;
}> {
  return new Promise((resolve) => {
    const server = createServer();
    const wss = new WebSocketServer({ server });
    wss.on('connection', (ws) => {
      if (opts.closeAfterMs !== undefined) {
        setTimeout(() => ws.close(4000, 'test bye'), opts.closeAfterMs);
      }
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      resolve({
        url: `ws://127.0.0.1:${port}/ws`,
        server,
        close: () =>
          new Promise<void>((res) => {
            wss.close();
            server.close(() => res());
          }),
      });
    });
  });
}

describe('StreamRelay pre-open gating (Bug 1 regression)', () => {
  const cleanups: Array<() => Promise<void>> = [];

  afterEach(async () => {
    while (cleanups.length) {
      const fn = cleanups.pop();
      if (fn) await fn().catch(() => {});
    }
  });

  it('rejects connect() and does NOT invoke onClose when upstream 404s the upgrade', async () => {
    const srv = await startRejectingServer();
    cleanups.push(srv.close);

    const relay = new StreamRelay(srv.url);
    const onClose = vi.fn();
    const onMessage = vi.fn();
    relay.onClose(onClose);
    relay.onMessage(onMessage);

    await expect(relay.connect()).rejects.toThrow();

    // Give any stray 'close' events a tick to arrive
    await new Promise((r) => setTimeout(r, 50));

    expect(onClose).not.toHaveBeenCalled();
    expect(onMessage).not.toHaveBeenCalled();
  });

  it('invokes onClose when the upstream closes AFTER a successful open', async () => {
    const srv = await startAcceptingServer({ closeAfterMs: 20 });
    cleanups.push(srv.close);

    const relay = new StreamRelay(srv.url);
    const onClose = vi.fn();
    relay.onClose(onClose);

    await relay.connect();

    await new Promise((r) => setTimeout(r, 100));
    expect(onClose).toHaveBeenCalledTimes(1);
    const call = onClose.mock.calls[0];
    if (!call) throw new Error('expected onClose to have been called');
    expect(call[0]).toBe(4000);
    expect(call[1]).toBe('test bye');
  });
});
