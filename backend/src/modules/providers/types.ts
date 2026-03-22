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
  mode: 'preview' | 'refine';
  advancedParameters?: AdvancedParameters;
  compareWithoutControlNet?: boolean;
}

export interface ProviderResponse {
  imageUrl: string;
  inputImageUrl?: string;
  lineartImageUrl?: string;
  seed: number;
  latencyMs: number;
  jobId?: string;
  workflow?: Record<string, unknown>;
  comparisonImageUrl?: string;
  comparisonError?: string;
}

export interface ProviderAdapter {
  readonly name: string;
  generate(request: ProviderRequest): Promise<ProviderResponse>;
  cancel(jobId: string): Promise<void>;
  healthCheck(): Promise<boolean>;
}
