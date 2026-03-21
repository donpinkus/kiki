export interface AdvancedParameters {
  controlNetStrength?: number | null;
  controlNetEndPercent?: number | null;
  cfgScale?: number | null;
  steps?: number | null;
  denoise?: number | null;
  auraFlowShift?: number | null;
  loraStrength?: number | null;
  negativePrompt?: string | null;
  seed?: number | null;
}

export interface ProviderRequest {
  sketchImageBase64: string;
  prompt: string;
  negativePrompt: string;
  mode: 'preview' | 'refine';
  creativity: number;
  seed?: number;
  width: number;
  height: number;
  advancedParameters?: AdvancedParameters;
}

export interface ProviderResponse {
  imageUrl: string;
  inputImageUrl?: string;
  lineartImageUrl?: string;
  seed: number;
  latencyMs: number;
  jobId?: string;
  workflow?: Record<string, unknown>;
}

export interface ProviderAdapter {
  readonly name: string;
  generate(request: ProviderRequest): Promise<ProviderResponse>;
  cancel(jobId: string): Promise<void>;
  healthCheck(): Promise<boolean>;
}
