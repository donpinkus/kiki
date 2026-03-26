import type { FastifyPluginAsync } from 'fastify';
import { ComfyUIAdapter } from '../modules/providers/comfyui.js';
import type { AdvancedParameters, ProviderAdapter, ProviderRequest } from '../modules/providers/types.js';

const generateBodySchema = {
  type: 'object',
  required: ['sessionId', 'requestId', 'mode', 'sketchImageBase64'],
  properties: {
    sessionId: { type: 'string', format: 'uuid' },
    requestId: { type: 'string', format: 'uuid' },
    mode: { type: 'string', enum: ['preview', 'refine'] },
    prompt: { type: ['string', 'null'], maxLength: 1000 },
    sketchImageBase64: { type: 'string', minLength: 1 },
    compareWithoutControlNet: { type: 'boolean', nullable: true },
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
  sketchImageBase64: string;
  advancedParameters?: AdvancedParameters | null;
  compareWithoutControlNet?: boolean | null;
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
        sketchImageBase64,
        advancedParameters = null,
        compareWithoutControlNet = null,
      } = request.body;

      const startTime = Date.now();

      request.log.info(
        { sessionId, requestId, mode, hasAdvancedParams: !!advancedParameters, advancedParameters },
        'Received generate request',
      );

      const providerRequest: ProviderRequest = {
        sketchImageBase64,
        prompt: prompt?.trim() || 'A detailed illustration',
        mode,
        advancedParameters: advancedParameters ?? undefined,
        compareWithoutControlNet: compareWithoutControlNet ?? undefined,
      };

      try {
        const result = await provider.generate(providerRequest);
        const latencyMs = Date.now() - startTime;

        // Debug: log what the client sent vs what was applied to the workflow
        const wf = result.workflow as Record<string, { inputs: Record<string, unknown> }> | undefined;
        request.log.info(
          {
            sessionId,
            requestId,
            mode,
            provider: provider.name,
            latencyMs,
            debug: {
              clientParams: advancedParameters,
              appliedWorkflow: wf ? {
                ksampler: wf['111:3']?.inputs ? {
                  seed: wf['111:3'].inputs['seed'],
                  cfg: wf['111:3'].inputs['cfg'],
                  steps: wf['111:3'].inputs['steps'],
                  denoise: wf['111:3'].inputs['denoise'],
                } : 'NODE MISSING',
                controlnet: wf['111:85']?.inputs ? {
                  strength: wf['111:85'].inputs['strength'],
                  end_percent: wf['111:85'].inputs['end_percent'],
                } : 'NODE MISSING',
                auraflow: wf['111:66']?.inputs ? {
                  shift: wf['111:66'].inputs['shift'],
                } : 'NODE MISSING',
                lora: wf['111:80']?.inputs ? {
                  strength_model: wf['111:80'].inputs['strength_model'],
                } : 'NODE MISSING',
              } : 'NO WORKFLOW RETURNED',
            },
          },
          'Generation completed',
        );

        return reply.status(200).send({
          requestId,
          status: 'completed',
          imageUrl: result.imageUrl,
          inputImageUrl: result.inputImageUrl ?? null,
          lineartImageUrl: result.lineartImageUrl ?? null,
          generatedLineartImageUrl: result.generatedLineartImageUrl ?? null,
          comparisonImageUrl: result.comparisonImageUrl ?? null,
          comparisonError: result.comparisonError ?? null,
          seed: result.seed,
          provider: provider.name,
          latencyMs,
          mode,
          workflow: result.workflow ?? null,
        });
      } catch (err: unknown) {
        const latencyMs = Date.now() - startTime;
        const errorMessage = err instanceof Error ? err.message : String(err);

        request.log.error(
          { sessionId, requestId, mode, provider: provider.name, latencyMs, err },
          'Generation failed',
        );

        return reply.status(200).send({
          requestId,
          status: 'error',
          error: errorMessage,
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
