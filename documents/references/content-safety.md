# Content Safety

Content safety is infrastructure, not a feature. Must be operational before any external testing.

## Apple App Store Requirements

### Guideline 5.1.2(i) — Third-Party AI Disclosure (Nov 2025)
- First-launch consent screen required
- Must specifically identify: inference provider(s), what data is transmitted (sketch images, prompts)
- Generic privacy policy link is insufficient — must be explicit
- Consent screen accessible anytime via Settings

### Guideline 1.2.1(a) — Age Restrictions
- Implement age restriction based on declared user age
- Use Apple's Declared Age Range API (available late 2025)

### UGC Requirements
- Method for filtering objectionable material
- Mechanism to report offensive content
- Ability to block abusive users
- Published contact information

## Design Decisions

- **Two-layer input filtering**: regex blocklist (JSON config, hot-deployable) + text classifier for evasion
- **Output filtering**: NSFW classifier on every generated image, server-side, <50ms budget
- **Filtered responses**: return 200 with `status: "filtered"` — do NOT count against quota
- **ComfyUI has no built-in content filter** — our server filter is the primary safety layer
- **User reporting**: "Report this image" button on every output → Slack channel (v1), proper moderation tool (v2)

## Privacy Commitments (must be in consent screen)

1. Sketches and prompts are sent to our server for AI processing
2. Our server forwards them to ComfyUI (on RunPod) for image generation
3. Sketch data is deleted after processing — not stored or used for training
4. Generated images cached for up to 7 days for re-download
5. Link to full privacy policy
