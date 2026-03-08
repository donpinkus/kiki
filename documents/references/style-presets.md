# Style Presets

7 presets for v1. Each has a prompt template where `{caption}` is replaced with either the user's prompt or the auto-generated VLM caption.

## Preset Definitions

### Photoreal
- **ID:** `photoreal`
- **Display Name:** Photoreal
- **Template:** `{caption}, photorealistic, highly detailed photograph, professional lighting, sharp focus, 8k resolution`
- **Tier:** Free

### Anime
- **ID:** `anime`
- **Display Name:** Anime
- **Template:** `{caption}, anime style, cel shading, vibrant colors, Studio Ghibli inspired, detailed illustration`
- **Tier:** Free

### Watercolor
- **ID:** `watercolor`
- **Display Name:** Watercolor
- **Template:** `{caption}, watercolor painting, soft washes, visible brushstrokes, wet-on-wet technique, artistic, beautiful`
- **Tier:** Free

### Storybook
- **ID:** `storybook`
- **Display Name:** Storybook
- **Template:** `{caption}, children's book illustration, whimsical, soft colors, storybook art, gentle, charming`
- **Tier:** Plus

### Fantasy
- **ID:** `fantasy`
- **Display Name:** Fantasy
- **Template:** `{caption}, fantasy art, epic, dramatic lighting, detailed, concept art, magical atmosphere`
- **Tier:** Plus

### Ink
- **ID:** `ink`
- **Display Name:** Ink
- **Template:** `{caption}, ink drawing, black and white, detailed linework, pen and ink illustration, cross-hatching`
- **Tier:** Plus

### Neon
- **ID:** `neon`
- **Display Name:** Neon
- **Template:** `{caption}, neon lights, cyberpunk aesthetic, glowing, dark background, vibrant neon colors, futuristic`
- **Tier:** Plus

## Free Tier Access
Free users get 3 presets: Photoreal, Anime, Watercolor. Other presets show a lock icon with upgrade prompt.

## Implementation Notes
- Store preset definitions in `ios/Kiki/Resources/StylePresets.json` and parse at launch
- Backend also needs preset definitions for prompt template assembly (in `backend/src/config/`)
- Keep presets in sync between client and server — consider a shared JSON file or API endpoint
- Default preset: Photoreal (used if none selected)
- Changing preset triggers immediate generation (no debounce wait)

## Negative Prompts (Applied Globally)
All presets include a shared negative prompt to improve quality:
```
blurry, low quality, distorted, deformed, ugly, bad anatomy, bad proportions, watermark, text, signature
```

## Future Presets (v2+)
- Custom user presets
- Community-shared presets
- Seasonal/themed presets
