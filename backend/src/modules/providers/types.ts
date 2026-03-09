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
}

export interface ProviderResponse {
  imageUrl: string;
  seed: number;
  latencyMs: number;
  jobId: string;
}

export interface ProviderAdapter {
  readonly name: string;
  generate(request: ProviderRequest): Promise<ProviderResponse>;
  cancel(jobId: string): Promise<void>;
  healthCheck(): Promise<boolean>;
}
