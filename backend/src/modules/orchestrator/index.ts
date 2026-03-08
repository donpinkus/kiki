import { generateWithFal } from '../providers/fal-adapter.js';

export interface GenerateParams {
  sessionId: string;
  requestId: string;
  mode: 'preview' | 'refine';
  prompt: string;
  stylePreset: string;
  adherence: number;
  sketchImageBase64: string;
}

export interface GenerateResult {
  status: 'completed' | 'filtered' | 'error';
  imageUrl: string | null;
  seed: number | null;
  provider: string;
}

export async function generateImage(params: GenerateParams): Promise<GenerateResult> {
  // For Week 1, route everything through fal.ai preview (LCM)
  return generateWithFal(params);
}
