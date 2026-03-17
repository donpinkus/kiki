export interface AdvancedParameters {
  controlNetStrength?: number | null;
  controlNetEndPercent?: number | null;
  cfgScale?: number | null;
  steps?: number | null;
  denoise?: number | null;
  seed?: number | null;
}

export interface ProviderRequest {
  sketchImageBase64: string;
  prompt: string;
  negativePrompt: string;
  mode: 'preview' | 'refine';
  adherence: number;
  creativity: number;
  seed?: number;
  width: number;
  height: number;
  advancedParameters?: AdvancedParameters;
}

export interface ProviderResponse {
  imageUrl: string;
  seed: number;
  latencyMs: number;
  jobId?: string;
}

export interface ProviderAdapter {
  readonly name: string;
  generate(request: ProviderRequest): Promise<ProviderResponse>;
  cancel(jobId: string): Promise<void>;
  healthCheck(): Promise<boolean>;
}
