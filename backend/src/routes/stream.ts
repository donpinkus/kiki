import type { FastifyPluginAsync } from 'fastify';
import type { WebSocket } from 'ws';
import { config } from '../config/index.js';
import { StreamDiffusionRelay } from '../modules/providers/streamdiffusion.js';

/**
 * Sets up a WebSocket relay between the client and an upstream generation server.
 * Used by both StreamDiffusion and FLUX.2-klein stream routes.
 */
function setupRelay(
  socket: WebSocket,
  request: { log: { info: Function; warn: Function; error: Function } },
  upstreamUrl: string,
  engineName: string,
) {
  const clientId = Math.random().toString(36).slice(2, 8);
  request.log.info({ clientId, engine: engineName }, 'Stream client connected');

  const relay = new StreamDiffusionRelay(upstreamUrl);

  // Register handlers BEFORE connect to avoid race conditions
  relay.onMessage((data, isBinary) => {
    if (socket.readyState === socket.OPEN) {
      if (isBinary) {
        const base64 = (data as Buffer).toString('base64');
        socket.send(JSON.stringify({ type: 'frame', data: base64 }));
      } else {
        socket.send(data);
      }
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
        message: `Cannot connect to ${engineName} server: ${err instanceof Error ? err.message : String(err)}`,
      }));
      socket.close(1011, 'Upstream unavailable');
    });

  socket.on('close', () => {
    request.log.info({ clientId }, 'Stream client disconnected');
    relay.close();
  });

  socket.on('error', (err: Error) => {
    request.log.error({ clientId, err }, 'Client socket error');
    relay.close();
  });
}

export const streamRoute: FastifyPluginAsync = async (fastify) => {
  // StreamDiffusion (SD 1.5) — original stream engine
  // /v1/stream is kept as alias for backward compatibility
  const sdHandler = (socket: WebSocket, request: any) => {
    if (!config.STREAMDIFFUSION_URL) {
      request.log.error('STREAMDIFFUSION_URL not configured');
      socket.send(JSON.stringify({
        type: 'error',
        message: 'StreamDiffusion server not configured',
      }));
      socket.close(1011, 'Server not configured');
      return;
    }
    setupRelay(socket, request, config.STREAMDIFFUSION_URL, 'StreamDiffusion');
  };

  fastify.get('/v1/stream', { websocket: true }, sdHandler);
  fastify.get('/v1/stream/sd', { websocket: true }, sdHandler);

  // FLUX.2-klein — high-quality stream engine
  fastify.get('/v1/stream/flux', { websocket: true }, (socket, request) => {
    if (!config.FLUX_KLEIN_URL) {
      request.log.error('FLUX_KLEIN_URL not configured');
      socket.send(JSON.stringify({
        type: 'error',
        message: 'FLUX.2-klein server not configured',
      }));
      socket.close(1011, 'Server not configured');
      return;
    }
    setupRelay(socket, request, config.FLUX_KLEIN_URL, 'FLUX.2-klein');
  });
};
