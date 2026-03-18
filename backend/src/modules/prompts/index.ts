export const DEFAULT_NEGATIVE_PROMPT =
  'blurry, low quality, distorted, deformed, ugly, bad anatomy';

export function buildPrompt(userPrompt: string | null): string {
  return userPrompt?.trim() || 'A detailed illustration';
}
