import type { FastifyPluginAsync } from 'fastify';
import type { GenerateRequest } from '../modules/orchestrator/index.js';

const STYLE_PRESETS = [
  'photoreal',
  'anime',
  'watercolor',
  'storybook',
  'fantasy',
  'ink',
  'neon',
] as const;

const generateBodySchema = {
  type: 'object',
  required: ['sessionId', 'requestId', 'mode', 'stylePreset', 'sketchImageBase64'],
  properties: {
    sessionId: {
      type: 'string',
      format: 'uuid',
    },
    requestId: {
      type: 'string',
      format: 'uuid',
    },
    mode: {
      type: 'string',
      enum: ['preview', 'refine'],
    },
    prompt: {
      type: ['string', 'null'],
      maxLength: 500,
    },
    stylePreset: {
      type: 'string',
      enum: [...STYLE_PRESETS],
    },
    adherence: {
      type: 'number',
      minimum: 0,
      maximum: 1,
      default: 0.7,
    },
    sketchImageBase64: {
      type: 'string',
      minLength: 1,
    },
  },
  additionalProperties: false,
} as const;

const generateResponseSchema = {
  type: 'object',
  properties: {
    requestId: { type: 'string' },
    status: { type: 'string', enum: ['completed', 'filtered', 'error'] },
    imageUrl: { type: ['string', 'null'] },
    seed: { type: 'number' },
    provider: { type: 'string' },
    latencyMs: { type: 'number' },
    mode: { type: 'string', enum: ['preview', 'refine'] },
  },
} as const;

interface GenerateBody {
  sessionId: string;
  requestId: string;
  mode: 'preview' | 'refine';
  prompt?: string | null;
  stylePreset: (typeof STYLE_PRESETS)[number];
  adherence?: number;
  sketchImageBase64: string;
}

export const generateRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: GenerateBody }>('/v1/generate', {
    schema: {
      body: generateBodySchema,
      response: {
        200: generateResponseSchema,
      },
    },
    handler: async (request, reply) => {
      const {
        sessionId,
        requestId,
        mode,
        prompt = null,
        stylePreset,
        adherence = 0.7,
        sketchImageBase64,
      } = request.body;

      request.log.info(
        { sessionId, requestId, mode, stylePreset },
        'Received generate request',
      );

      const orchestratorRequest: GenerateRequest = {
        sessionId,
        requestId,
        mode,
        prompt: prompt ?? null,
        stylePreset,
        adherence,
        sketchImageBase64,
      };

      const result = await fastify.orchestrator.generate(orchestratorRequest);

      return reply.status(200).send(result);
    },
  });
};
