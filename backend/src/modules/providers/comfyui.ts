import { config } from '../../config/index.js';
import { ProviderError } from '../../errors.js';
import type {
  ProviderAdapter,
  ProviderRequest,
  ProviderResponse,
} from './types.js';
import workflowTemplate from './comfyui-workflow-api.json' with { type: 'json' };

// Node IDs in the API-format workflow (subgraph nodes prefixed with "111:")
const LOAD_IMAGE_NODE_ID = '71';
const POSITIVE_PROMPT_NODE_ID = '111:6';
const NEGATIVE_PROMPT_NODE_ID = '111:7';
const SAVE_IMAGE_NODE_ID = '60';
const KSAMPLER_NODE_ID = '111:3';
const CONTROLNET_APPLY_NODE_ID = '111:85';
const AURAFLOW_NODE_ID = '111:66';
const LORA_LOADER_NODE_ID = '111:80';
const LINEART_PREVIEW_NODE_ID = '117';

const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 120_000;

type WorkflowNode = {
  inputs: Record<string, unknown>;
  class_type: string;
  _meta?: Record<string, unknown>;
};
type Workflow = Record<string, WorkflowNode>;

function getWorkflow(): Workflow {
  return structuredClone(workflowTemplate) as Workflow;
}

export class ComfyUIAdapter implements ProviderAdapter {
  readonly name = 'comfyui';

  async generate(request: ProviderRequest): Promise<ProviderResponse> {
    const startTime = Date.now();
    const baseUrl = config.COMFYUI_URL;

    if (!baseUrl) {
      throw new ProviderError('comfyui', 'COMFYUI_URL is not configured');
    }

    // 1. Upload sketch image to ComfyUI
    const sketchFilename = await this.uploadImage(baseUrl, request.sketchImageBase64);

    // 2. Build workflow from template
    const workflow = getWorkflow();

    // 3. Set the input image filename
    if (workflow[LOAD_IMAGE_NODE_ID]) {
      workflow[LOAD_IMAGE_NODE_ID].inputs['image'] = sketchFilename;
    } else {
      throw new ProviderError('comfyui', `LoadImage node ${LOAD_IMAGE_NODE_ID} not found in workflow`);
    }

    // 4. Set the prompt text
    if (workflow[POSITIVE_PROMPT_NODE_ID]) {
      workflow[POSITIVE_PROMPT_NODE_ID].inputs['text'] = request.prompt;
    } else {
      throw new ProviderError('comfyui', `CLIPTextEncode node ${POSITIVE_PROMPT_NODE_ID} not found in workflow`);
    }

    // 5. Apply advanced parameters (seed, CFG, steps, ControlNet, etc.)
    this.applyAdvancedParameters(workflow, request);

    // 6. Submit to ComfyUI queue
    const promptId = await this.submitPrompt(baseUrl, workflow);

    // 7. Poll for completion
    const outputs = await this.pollForResult(baseUrl, promptId);

    // 8. Construct image URLs
    const saveOutput = outputs[SAVE_IMAGE_NODE_ID]?.images?.[0];
    if (!saveOutput) {
      throw new ProviderError('comfyui', 'Generation completed but no images in SaveImage output');
    }
    const imageUrl = `${baseUrl}/view?filename=${encodeURIComponent(saveOutput.filename)}&subfolder=${encodeURIComponent(saveOutput.subfolder)}&type=${encodeURIComponent(saveOutput.type)}`;

    // Input sketch URL
    const inputImageUrl = `${baseUrl}/view?filename=${encodeURIComponent(sketchFilename)}&type=input`;

    // Lineart preview URL (node 117)
    const lineartOutput = outputs[LINEART_PREVIEW_NODE_ID]?.images?.[0];
    const lineartImageUrl = lineartOutput
      ? `${baseUrl}/view?filename=${encodeURIComponent(lineartOutput.filename)}&subfolder=${encodeURIComponent(lineartOutput.subfolder)}&type=${encodeURIComponent(lineartOutput.type)}`
      : undefined;

    const actualSeed = Number(workflow[KSAMPLER_NODE_ID]?.inputs['seed'] ?? 0);

    return {
      imageUrl,
      inputImageUrl,
      lineartImageUrl,
      seed: actualSeed,
      latencyMs: Date.now() - startTime,
      jobId: promptId,
    };
  }

  async cancel(jobId: string): Promise<void> {
    const baseUrl = config.COMFYUI_URL;
    if (!baseUrl) return;

    try {
      const response = await fetch(`${baseUrl}/queue`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ delete: [jobId] }),
      });

      if (!response.ok) {
        const body = await response.text();
        console.warn(`Failed to cancel ComfyUI job ${jobId}: ${response.status} ${body}`);
      }
    } catch (err) {
      console.warn(`Failed to cancel ComfyUI job ${jobId}:`, err);
    }
  }

  async healthCheck(): Promise<boolean> {
    const baseUrl = config.COMFYUI_URL;
    if (!baseUrl) return false;

    try {
      const response = await fetch(`${baseUrl}/system_stats`);
      return response.ok;
    } catch {
      return false;
    }
  }

  private applyAdvancedParameters(workflow: Workflow, request: ProviderRequest): void {
    const params = request.advancedParameters;

    // KSampler: seed (always set — random if not provided), cfg, steps, denoise
    const ksampler = workflow[KSAMPLER_NODE_ID];
    if (ksampler) {
      ksampler.inputs['seed'] =
        params?.seed ?? Math.floor(Math.random() * Number.MAX_SAFE_INTEGER);
      if (params?.cfgScale != null) ksampler.inputs['cfg'] = params.cfgScale;
      if (params?.steps != null) ksampler.inputs['steps'] = params.steps;
      if (params?.denoise != null) ksampler.inputs['denoise'] = params.denoise;
    }

    // ControlNetApplyAdvanced: strength, end_percent
    const controlnet = workflow[CONTROLNET_APPLY_NODE_ID];
    if (controlnet) {
      if (params?.controlNetStrength != null) controlnet.inputs['strength'] = params.controlNetStrength;
      if (params?.controlNetEndPercent != null) controlnet.inputs['end_percent'] = params.controlNetEndPercent;
    }

    // ModelSamplingAuraFlow: shift
    const auraflow = workflow[AURAFLOW_NODE_ID];
    if (auraflow && params?.auraFlowShift != null) {
      auraflow.inputs['shift'] = params.auraFlowShift;
    }

    // LoraLoaderModelOnly: strength_model
    const lora = workflow[LORA_LOADER_NODE_ID];
    if (lora && params?.loraStrength != null) {
      lora.inputs['strength_model'] = params.loraStrength;
    }

    // Negative prompt override
    const negativeNode = workflow[NEGATIVE_PROMPT_NODE_ID];
    if (negativeNode && params?.negativePrompt != null) {
      negativeNode.inputs['text'] = params.negativePrompt;
    }
  }

  private async uploadImage(baseUrl: string, base64: string): Promise<string> {
    const buffer = Buffer.from(base64, 'base64');
    const blob = new Blob([buffer], { type: 'image/jpeg' });

    const formData = new FormData();
    formData.append('image', blob, `sketch_${Date.now()}.jpg`);
    formData.append('overwrite', 'true');

    const response = await fetch(`${baseUrl}/upload/image`, {
      method: 'POST',
      body: formData,
    });

    if (!response.ok) {
      const body = await response.text();
      throw new ProviderError('comfyui', `Image upload failed ${response.status}: ${body}`);
    }

    const result = (await response.json()) as { name: string; subfolder: string; type: string };
    return result.name;
  }

  private async submitPrompt(baseUrl: string, workflow: Workflow): Promise<string> {
    const response = await fetch(`${baseUrl}/prompt`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        prompt: workflow,
        client_id: 'kiki-backend',
      }),
    });

    if (!response.ok) {
      const body = await response.text();
      throw new ProviderError('comfyui', `Prompt submission failed ${response.status}: ${body}`);
    }

    const result = (await response.json()) as { prompt_id: string };
    return result.prompt_id;
  }

  private async pollForResult(
    baseUrl: string,
    promptId: string,
  ): Promise<Record<string, { images?: Array<{ filename: string; subfolder: string; type: string }> }>> {
    const deadline = Date.now() + POLL_TIMEOUT_MS;

    while (Date.now() < deadline) {
      const response = await fetch(`${baseUrl}/history/${promptId}`);

      if (response.ok) {
        const history = (await response.json()) as Record<
          string,
          {
            outputs?: Record<string, { images?: Array<{ filename: string; subfolder: string; type: string }> }>;
            status?: { status_str: string; completed: boolean };
          }
        >;

        const entry = history[promptId];
        if (entry?.outputs) {
          // Verify at least the SaveImage node produced output
          const saveOutput = entry.outputs[SAVE_IMAGE_NODE_ID];
          if (saveOutput?.images?.[0]) {
            return entry.outputs;
          }

          // Fallback: check if any node has images
          for (const nodeOutput of Object.values(entry.outputs)) {
            if (nodeOutput.images?.[0]) {
              return entry.outputs;
            }
          }

          throw new ProviderError('comfyui', 'Generation completed but no images in output');
        }

        // Check for errors
        if (entry?.status?.status_str === 'error') {
          throw new ProviderError('comfyui', 'Generation failed on ComfyUI server');
        }
      }

      await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
    }

    throw new ProviderError('comfyui', `Generation timed out after ${POLL_TIMEOUT_MS / 1000}s`);
  }
}
