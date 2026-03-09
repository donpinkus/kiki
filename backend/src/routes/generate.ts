import { FastifyPluginAsync } from 'fastify';
import { generateImage } from '../modules/orchestrator/index.js';

interface GenerateBody {
  sessionId: string;
  requestId: string;
  mode: 'preview' | 'refine';
  prompt?: string;
  autoCaption?: string;
  stylePreset?: string;
  adherence?: number;
  creativity?: number;
  seed?: number;
  aspectRatio?: string;
  sketchImageBase64: string;
}

const generateSchema = {
  body: {
    type: 'object',
    required: ['sessionId', 'requestId', 'mode', 'sketchImageBase64'],
    properties: {
      sessionId: { type: 'string', minLength: 1, maxLength: 256 },
      requestId: { type: 'string', minLength: 1, maxLength: 256 },
      mode: { type: 'string', enum: ['preview', 'refine'] },
      prompt: { type: 'string', maxLength: 2000 },
      autoCaption: { type: 'string', maxLength: 1000 },
      stylePreset: { type: 'string', maxLength: 100 },
      adherence: { type: 'number', minimum: 0, maximum: 1 },
      creativity: { type: 'number', minimum: 0, maximum: 1 },
      seed: { type: 'integer' },
      aspectRatio: { type: 'string', maxLength: 20 },
      sketchImageBase64: { type: 'string', minLength: 1, maxLength: 10485760 },
    },
  },
};

export const generateRoute: FastifyPluginAsync = async (app) => {
  app.post<{ Body: GenerateBody }>(
    '/v1/generate',
    { schema: generateSchema },
    async (request, reply) => {
      const { sessionId, requestId, mode, prompt, stylePreset, adherence, sketchImageBase64 } =
        request.body;

      request.log.info({ requestId, sessionId, mode }, 'Generation request received');

      const startTime = Date.now();

      const result = await generateImage({
        sessionId,
        requestId,
        mode,
        prompt: prompt ?? '',
        stylePreset: stylePreset ?? 'photoreal',
        adherence: adherence ?? 0.5,
        sketchImageBase64,
      });

      const latencyMs = Date.now() - startTime;
      request.log.info({ requestId, latencyMs, provider: result.provider }, 'Generation complete');

      return reply.send({
        requestId,
        status: result.status,
        imageUrl: result.imageUrl,
        seed: result.seed,
        provider: result.provider,
        latencyMs,
      });
    },
  );

  app.post<{ Body: { sessionId: string; requestId: string } }>(
    '/v1/cancel',
    {
      schema: {
        body: {
          type: 'object',
          required: ['sessionId', 'requestId'],
          properties: {
            sessionId: { type: 'string', minLength: 1, maxLength: 256 },
            requestId: { type: 'string', minLength: 1, maxLength: 256 },
          },
        },
      },
    },
    async (request, reply) => {
      const { sessionId, requestId } = request.body;
      request.log.info({ requestId, sessionId }, 'Cancel request received');
      // TODO: Implement Redis-backed stale job tracking in Week 3
      return reply.send({ acknowledged: true });
    },
  );
};
