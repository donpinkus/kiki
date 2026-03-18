export const STYLE_PRESETS = [
  'photoreal',
  'anime',
  'watercolor',
  'storybook',
  'fantasy',
  'ink',
  'neon',
] as const;

export const STYLE_PROMPTS: Record<string, string> = {
  photoreal: 'photorealistic, high detail, professional photography',
  anime: 'anime style, cel shaded, vibrant colors',
  watercolor: 'watercolor painting, soft edges, artistic',
  storybook: "children's storybook illustration, whimsical, colorful",
  fantasy: 'fantasy art, epic, magical, detailed',
  ink: 'ink drawing, black and white, detailed linework',
  neon: 'neon glow, cyberpunk, vibrant neon colors, dark background',
};

export const DEFAULT_NEGATIVE_PROMPT =
  'blurry, low quality, distorted, deformed, ugly, bad anatomy';

export function buildPrompt(
  userPrompt: string | null,
  stylePreset: string,
): string {
  const styleModifier = STYLE_PROMPTS[stylePreset] ?? '';
  const base = userPrompt?.trim() || 'A detailed illustration';
  return styleModifier ? `${base}, ${styleModifier}` : base;
}
