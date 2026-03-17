import type { FastifyPluginAsync } from 'fastify';
import { FalAdapter } from '../providers/fal.js';
import type { ProviderAdapter, ProviderRequest } from '../providers/types.js';

export interface GenerateRequest {
  sessionId: string;
  requestId: string;
  mode: 'preview' | 'refine';
  prompt: string | null;
  stylePreset: string;
  adherence: number;
  sketchImageBase64: string;
}

export interface GenerateResult {
  requestId: string;
  status: 'completed' | 'filtered' | 'error';
  imageUrl: string | null;
  seed: number;
  provider: string;
  latencyMs: number;
  mode: 'preview' | 'refine';
}

const DEFAULT_NEGATIVE_PROMPT =
  'blurry, low quality, distorted, deformed, ugly, bad anatomy';

function buildPrompt(
  userPrompt: string | null,
  stylePreset: string,
): string {
  const stylePrompts: Record<string, string> = {
    photoreal: 'photorealistic, high detail, professional photography',
    anime: 'anime style, cel shaded, vibrant colors',
    watercolor: 'watercolor painting, soft edges, artistic',
    storybook: 'children\'s storybook illustration, whimsical, colorful',
    fantasy: 'fantasy art, epic, magical, detailed',
    ink: 'ink drawing, black and white, detailed linework',
    neon: 'neon glow, cyberpunk, vibrant neon colors, dark background',
  };

  const styleModifier = stylePrompts[stylePreset] ?? '';
  const base = userPrompt?.trim() || 'A detailed illustration';

  return styleModifier ? `${base}, ${styleModifier}` : base;
}

export const orchestratorPlugin: FastifyPluginAsync = async (fastify) => {
  const provider: ProviderAdapter = new FalAdapter();

  fastify.decorate('orchestrator', {
    async generate(request: GenerateRequest): Promise<GenerateResult> {
      const startTime = Date.now();
      const { sessionId, requestId, mode, prompt, stylePreset, sketchImageBase64 } = request;

      fastify.log.info(
        { sessionId, requestId, mode, stylePreset },
        'Starting generation',
      );

      const providerRequest: ProviderRequest = {
        sketchImageBase64,
        prompt: buildPrompt(prompt, stylePreset),
        negativePrompt: DEFAULT_NEGATIVE_PROMPT,
        mode,
        width: mode === 'preview' ? 512 : 1024,
        height: mode === 'preview' ? 512 : 1024,
      };

      try {
        const result = await provider.generate(providerRequest);

        const latencyMs = Date.now() - startTime;
        fastify.log.info(
          { sessionId, requestId, mode, provider: provider.name, latencyMs },
          'Generation completed',
        );

        return {
          requestId,
          status: 'completed',
          imageUrl: result.imageUrl,
          seed: result.seed,
          provider: provider.name,
          latencyMs,
          mode,
        };
      } catch (err: unknown) {
        const latencyMs = Date.now() - startTime;

        fastify.log.error(
          { sessionId, requestId, mode, provider: provider.name, latencyMs, err },
          'Generation failed',
        );

        return {
          requestId,
          status: 'error',
          imageUrl: null,
          seed: 0,
          provider: provider.name,
          latencyMs,
          mode,
        };
      }
    },
  });
};

// Extend Fastify type definitions
declare module 'fastify' {
  interface FastifyInstance {
    orchestrator: {
      generate(request: GenerateRequest): Promise<GenerateResult>;
    };
  }
}
