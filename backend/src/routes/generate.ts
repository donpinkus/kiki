import type { FastifyPluginAsync } from 'fastify';
import { ComfyUIAdapter } from '../modules/providers/comfyui.js';
import type { AdvancedParameters, ProviderAdapter, ProviderRequest } from '../modules/providers/types.js';

const STYLE_PRESETS = [
  'photoreal',
  'anime',
  'watercolor',
  'storybook',
  'fantasy',
  'ink',
  'neon',
] as const;

const STYLE_PROMPTS: Record<string, string> = {
  photoreal: 'photorealistic, high detail, professional photography',
  anime: 'anime style, cel shaded, vibrant colors',
  watercolor: 'watercolor painting, soft edges, artistic',
  storybook: "children's storybook illustration, whimsical, colorful",
  fantasy: 'fantasy art, epic, magical, detailed',
  ink: 'ink drawing, black and white, detailed linework',
  neon: 'neon glow, cyberpunk, vibrant neon colors, dark background',
};

const DEFAULT_NEGATIVE_PROMPT =
  'blurry, low quality, distorted, deformed, ugly, bad anatomy';

function buildPrompt(userPrompt: string | null, stylePreset: string): string {
  const styleModifier = STYLE_PROMPTS[stylePreset] ?? '';
  const base = userPrompt?.trim() || 'A detailed illustration';
  return styleModifier ? `${base}, ${styleModifier}` : base;
}

const generateBodySchema = {
  type: 'object',
  required: ['sessionId', 'requestId', 'mode', 'stylePreset', 'sketchImageBase64'],
  properties: {
    sessionId: { type: 'string', format: 'uuid' },
    requestId: { type: 'string', format: 'uuid' },
    mode: { type: 'string', enum: ['preview', 'refine'] },
    prompt: { type: ['string', 'null'], maxLength: 500 },
    stylePreset: { type: 'string', enum: [...STYLE_PRESETS] },
    adherence: { type: 'number', minimum: 0, maximum: 1, default: 0.7 },
    sketchImageBase64: { type: 'string', minLength: 1 },
    advancedParameters: {
      type: 'object',
      nullable: true,
      properties: {
        controlNetStrength: { type: 'number', minimum: 0, maximum: 1, nullable: true },
        controlNetEndPercent: { type: 'number', minimum: 0, maximum: 1, nullable: true },
        cfgScale: { type: 'number', minimum: 0, maximum: 5, nullable: true },
        steps: { type: 'integer', minimum: 1, maximum: 20, nullable: true },
        denoise: { type: 'number', minimum: 0, maximum: 1, nullable: true },
        auraFlowShift: { type: 'number', minimum: 0, maximum: 5, nullable: true },
        loraStrength: { type: 'number', minimum: 0, maximum: 2, nullable: true },
        negativePrompt: { type: ['string', 'null'], maxLength: 500, nullable: true },
        seed: { type: 'integer', minimum: 0, maximum: 9007199254740991, nullable: true },
      },
      additionalProperties: false,
    },
  },
  additionalProperties: false,
} as const;

interface GenerateBody {
  sessionId: string;
  requestId: string;
  mode: 'preview' | 'refine';
  prompt?: string | null;
  stylePreset: (typeof STYLE_PRESETS)[number];
  adherence?: number;
  sketchImageBase64: string;
  advancedParameters?: AdvancedParameters | null;
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
        stylePreset,
        adherence = 0.7,
        sketchImageBase64,
        advancedParameters = null,
      } = request.body;

      const startTime = Date.now();

      request.log.info(
        { sessionId, requestId, mode, stylePreset, hasAdvancedParams: !!advancedParameters },
        'Received generate request',
      );

      const providerRequest: ProviderRequest = {
        sketchImageBase64,
        prompt: buildPrompt(prompt, stylePreset),
        negativePrompt: DEFAULT_NEGATIVE_PROMPT,
        mode,
        adherence,
        creativity: 0.85,
        width: mode === 'preview' ? 512 : 1024,
        height: mode === 'preview' ? 512 : 1024,
        advancedParameters: advancedParameters ?? undefined,
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
