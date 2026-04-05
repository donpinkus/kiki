import type { FastifyPluginAsync } from 'fastify';
import { config } from '../config/index.js';
import { StreamDiffusionRelay } from '../modules/providers/streamdiffusion.js';

export const streamRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/stream', { websocket: true }, (socket, request) => {
    const clientId = Math.random().toString(36).slice(2, 8);
    request.log.info({ clientId }, 'Stream client connected');

    if (!config.STREAMDIFFUSION_URL) {
      request.log.error('STREAMDIFFUSION_URL not configured');
      socket.send(JSON.stringify({
        type: 'error',
        message: 'StreamDiffusion server not configured',
      }));
      socket.close(1011, 'Server not configured');
      return;
    }

    const relay = new StreamDiffusionRelay(config.STREAMDIFFUSION_URL);

    // Register handlers BEFORE connect to avoid race conditions
    // (upstream could close between connect resolving and handler registration)
    relay.onMessage((data) => {
      if (socket.readyState === socket.OPEN) {
        socket.send(data);
      }
    });

    relay.onClose((code, reason) => {
      request.log.info({ clientId, code, reason }, 'Upstream closed');
      if (socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify({
          type: 'error',
          message: 'Upstream connection lost',
        }));
        socket.close(1001, 'Upstream closed');
      }
    });

    relay.onError((err) => {
      request.log.error({ clientId, err }, 'Upstream error');
    });

    relay.connect()
      .then(() => {
        request.log.info({ clientId }, 'Upstream connected');

        // Forward client messages to upstream
        socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
          const buf = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);

          if (isBinary) {
            relay.sendFrame(buf);
          } else {
            const text = buf.toString('utf-8');
            try {
              const parsed = JSON.parse(text);
              if (parsed.type === 'config') {
                relay.sendConfig(parsed);
              }
            } catch {
              request.log.warn({ clientId }, 'Invalid JSON from client');
            }
          }
        });
      })
      .catch((err: unknown) => {
        request.log.error({ clientId, err }, 'Failed to connect to upstream');
        socket.send(JSON.stringify({
          type: 'error',
          message: `Cannot connect to StreamDiffusion server: ${err instanceof Error ? err.message : String(err)}`,
        }));
        socket.close(1011, 'Upstream unavailable');
      });

    // Clean up when client disconnects
    socket.on('close', () => {
      request.log.info({ clientId }, 'Stream client disconnected');
      relay.close();
    });

    socket.on('error', (err: Error) => {
      request.log.error({ clientId, err }, 'Client socket error');
      relay.close();
    });
  });
};
