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

## Input Filtering (Prompts)

### Layer 1 — Blocklist
- Curated regex-based blocklist in `backend/src/config/blocklist.json`
- Covers: explicit sexual content, violence, hate speech, CSAM-adjacent terms
- Deployable without code changes (JSON config update + deploy)

### Layer 2 — Text Classifier
- Lightweight text classifier for obfuscation/misspelling evasion
- Options: OpenAI moderation endpoint or self-hosted model
- Runs server-side only

### Behavior on Trigger
- Return 200 with `status: "filtered"` and user-friendly message
- Do NOT send prompt to inference provider
- Do NOT count against user's generation quota
- Log event to `content_filter_log`

## Output Filtering (Generated Images)

### NSFW Image Classifier
- Run on EVERY generated image before returning to client
- Model: Falconsai/nsfw_image_detection (HuggingFace) or comparable
- Must complete in <50ms to stay within latency budget
- Runs server-side (inline in request handler for v1)

### Behavior on Trigger
- Replace image URL with blurred placeholder
- Set `contentFilterResult.flagged = true` with category labels
- Log to `content_filter_log`
- Do NOT display the filtered image to user

### Provider-Side Safety
- ComfyUI does not apply content filters by default
- Our filter is the primary safety layer
- If provider returns an error, propagate as "filtered" or "error" status

## User Reporting
- "Report this image" button on every generated output
- Submits to moderation queue (Slack channel with structured payload for v1)
- Graduate to proper moderation tool in v2

## Privacy
- Sketch images + prompts transmitted via TLS 1.3
- Sketch data ephemeral — deleted from server after generation response
- Generated images stored temporarily on RunPod pod storage — disclosed in consent
- No PII in analytics — anonymized usage metrics only

## Consent Screen Copy (First Launch)
Must disclose:
1. Sketches and prompts are sent to our server for AI processing
2. Our server forwards them to ComfyUI (on RunPod) for image generation
3. Sketch data is deleted after processing — not stored or used for training
4. Generated images cached for up to 7 days for re-download
5. Link to full privacy policy
6. "I Understand" button to proceed (required before app use)
