import type { FastifyPluginAsync } from 'fastify';
import { ComfyUIAdapter } from '../modules/providers/comfyui.js';
import type { ProviderAdapter, ProviderRequest } from '../modules/providers/types.js';
import { DEFAULT_NEGATIVE_PROMPT, buildPrompt } from '../modules/prompts/index.js';

const generateBodySchema = {
  type: 'object',
  required: ['sessionId', 'requestId', 'mode', 'sketchImageBase64'],
  properties: {
    sessionId: { type: 'string', format: 'uuid' },
    requestId: { type: 'string', format: 'uuid' },
    mode: { type: 'string', enum: ['preview', 'refine'] },
    prompt: { type: ['string', 'null'], maxLength: 500 },
    adherence: { type: 'number', minimum: 0, maximum: 1, default: 0.7 },
    sketchImageBase64: { type: 'string', minLength: 1 },
  },
  additionalProperties: false,
} as const;

interface GenerateBody {
  sessionId: string;
  requestId: string;
  mode: 'preview' | 'refine';
  prompt?: string | null;
  adherence?: number;
  sketchImageBase64: string;
}

const provider: ProviderAdapter = new ComfyUIAdapter();

export const generateRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: GenerateBody }>('/v1/generate', {
    schema: { body: generateBodySchema },
    handler: async (request, reply) => {
      const {
        sessionId,
        requestId,
        mode,
        prompt = null,
        adherence = 0.7,
        sketchImageBase64,
      } = request.body;

      const startTime = Date.now();

      request.log.info(
        { sessionId, requestId, mode },
        'Received generate request',
      );

      const providerRequest: ProviderRequest = {
        sketchImageBase64,
        prompt: buildPrompt(prompt),
        negativePrompt: DEFAULT_NEGATIVE_PROMPT,
        mode,
        adherence,
        creativity: 0.85,
        width: mode === 'preview' ? 512 : 1024,
        height: mode === 'preview' ? 512 : 1024,
      };

      try {
        const result = await provider.generate(providerRequest);
        const latencyMs = Date.now() - startTime;

        request.log.info(
          { sessionId, requestId, mode, provider: provider.name, latencyMs },
          'Generation completed',
        );

        return reply.status(200).send({
          requestId,
          status: 'completed',
          imageUrl: result.imageUrl,
          inputImageUrl: result.inputImageUrl ?? null,
          lineartImageUrl: result.lineartImageUrl ?? null,
          seed: result.seed,
          provider: provider.name,
          latencyMs,
          mode,
        });
      } catch (err: unknown) {
        const latencyMs = Date.now() - startTime;

        request.log.error(
          { sessionId, requestId, mode, provider: provider.name, latencyMs, err },
          'Generation failed',
        );

        return reply.status(200).send({
          requestId,
          status: 'error',
          imageUrl: null,
          seed: 0,
          provider: provider.name,
          latencyMs,
          mode,
        });
      }
    },
  });
};
