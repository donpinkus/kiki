# Product Requirements Document — iPad Sketch-to-Image Application

> **⚠️ PARTIALLY STALE.** Written before the switch from fal.ai to ComfyUI/Qwen-Image. Provider references, latency numbers, and cost models are outdated. Product vision, UX spec, and App Store requirements remain valid. For current implementation, read the code and `CLAUDE.md`.

> **Version 2.0 — March 2026** | Status: Final Draft for Engineering Review | Confidential — Internal Use Only

| **Field**      | **Value**                                     |
|----------------|-----------------------------------------------|
| Document Owner | Product & Engineering Leadership              |
| Audience       | Engineering, Design, Data Science, Leadership |
| Last Updated   | March 8, 2026                                 |
| Review Cycle   | Bi-weekly with eng leads                      |

## 1. Executive Summary

This document defines the product requirements for an iPad-native application that transforms user sketches into AI-generated images in near real time. The user draws on the left half of the screen with Apple Pencil and sees an AI interpretation of their drawing appear on the right half, updating progressively as they work. An optional text prompt and style presets provide additional creative control.

The app targets hobbyist artists, casual creatives, and design professionals who want fast visual exploration without prompt engineering expertise. The core differentiator is that drawing is the primary control surface, not text. The interaction should feel like a creative conversation between the artist and the AI.

**Key strategic decisions in this revision:** (1) We specify fal.ai as the primary inference provider for v1 based on their sub-second LCM latency and ControlNet support, with Replicate as fallback. (2) We introduce a concrete business model with tiered subscription pricing anchored to per-session inference cost modeling. (3) We add a full content safety and App Store compliance section reflecting Apple’s November 2025 guideline update requiring explicit disclosure of third-party AI data sharing. (4) We address the no-prompt experience gap by specifying a lightweight auto-captioning pipeline using a vision-language model.

## 2. Product Vision & Principles

### 2.1 Vision Statement

Make AI image generation feel like a creative superpower that responds to your hand, not your keyboard. The drawing is the interface. The AI is the co-pilot.

### 2.2 Product Principles

- **Drawing comes first.** The canvas must feel fast, fluid, and independent of generation latency. A single dropped frame or input lag event on the drawing surface is a critical bug.

- **The AI should feel responsive, not blocking.** Show fast previews and progressively refine them. Never leave the user staring at a spinner.

- **The sketch should matter.** The generated image must follow the structure, silhouette, and spatial composition of the user’s drawing. If it doesn’t, the product has failed its core promise.

- **Prompting is optional, not required.** The app must produce useful, visually coherent results with zero text input. The no-prompt experience is the default onboarding path.

- **Keep the interaction simple.** A new user should understand the split-screen interaction model within 5 seconds of opening the app. Progressive disclosure for advanced controls.

- **Respect the user’s data and trust.** Be transparent about what is sent to the server. Comply with Apple’s App Store guidelines on third-party AI data disclosure (guideline 5.1.2(i), updated November 2025).

## 3. Target Users & Market Context

### 3.1 Primary Users

- Hobbyist and amateur artists on iPad who want to see their rough sketches transformed into polished visuals.

- Casual creatives who enjoy drawing but lack the skill or patience for full digital painting workflows.

- Users seeking rapid visual exploration, ideation, and mood-boarding without switching between drawing and generation tools.

### 3.2 Secondary Users

- Concept artists and industrial designers creating fast variations (competitors: Vizcom, NewArc.ai).

- Storyboard artists and game developers doing worldbuilding.

- Kids and families experimenting with creative tools (requires age-appropriate content safeguards).

### 3.3 Competitive Landscape

The sketch-to-image space has matured significantly. Key competitors and reference points include:

| **Product**             | **Model**               | **Approach**                              | **Pricing**              |
|-------------------------|-------------------------|-------------------------------------------|--------------------------|
| Freepik Sketch to Image | Proprietary (real-time) | Web-based, real-time canvas               | Freemium, credits/day    |
| Vizcom                  | Proprietary             | Industrial design focus, sketch to render | Subscription, free tier  |
| Playform Sketch         | Consistency model       | Web-based, sub-second generation          | Subscription             |
| Canva Sketch to Life    | Proprietary             | Integrated into Canva platform            | Freemium (7 credits/day) |
| Procreate               | None (anti-AI stance)   | Best-in-class drawing, no AI generation   | \$12.99 one-time         |
| Adobe Fresco            | Firefly (limited)       | Drawing + limited AI features             | Free (2025)              |

**Key insight:** Procreate’s August 2024 announcement that it will not incorporate generative AI creates a clear market gap. Procreate owns the iPad drawing experience; we can own the iPad AI drawing experience. Our product should feel like “What if Procreate and Midjourney had a baby?”

### 3.4 User Stories

- As a casual artist, I want to sketch a rough scene and quickly see a polished image inspired by it, so I can explore ideas I couldn’t render on my own.

- As a concept artist, I want my composition to stay recognizable while exploring different visual styles, so I can use this as a fast ideation tool.

- As a beginner, I want to draw without needing to know how to write complex prompts, so the AI just figures out what I mean.

- As an Apple Pencil user, I want drawing to stay perfectly smooth even when generation is happening in the background.

- As a parent, I want to know that the AI won’t generate inappropriate content when my child is using the app.

## 4. Core Experience

### 4.1 Primary Interaction Loop

The app presents a split-screen layout in landscape orientation. The left pane is a PencilKit drawing canvas. The right pane displays the AI-generated interpretation. The interaction loop is:

1.  User opens the app. Left pane shows a blank canvas. Right pane shows the empty state: “Start drawing to see your image come to life.”

2.  User begins drawing with Apple Pencil or finger.

3.  After approximately 300ms of drawing inactivity, the app captures a canvas snapshot, preprocesses it, and sends it to the backend for a fast preview generation.

4.  The right pane displays the preview result within 1–2 seconds (target: under 1 second).

5.  If the user pauses longer (approximately 1200ms of inactivity), the app triggers a higher-quality refine pass.

6.  The refined image replaces the preview on the right pane via a smooth crossfade.

7.  If the user resumes drawing at any point, in-flight requests are cancelled. Only the most recent request updates the UI.

8.  User can optionally type a prompt, select a style preset, or adjust the sketch adherence slider to steer the output.

### 4.2 Mental Model

- **Left side =** intent input (your sketch)

- **Right side =** AI interpretation (generated image)

- **Prompt =** optional steering signal

- **Style preset =** optional visual direction

- **No prompt needed:** When the prompt is empty, the app uses a lightweight vision-language model to auto-caption the sketch, then feeds that caption as the hidden prompt. This ensures coherent results even with zero user text input.

### 4.3 The No-Prompt Experience (Critical Gap Addressed)

The original spec identified “prompting should be optional” as a principle but did not define how the app handles ambiguous sketches. A rough blob could be a cat, a rock, or a bush. Without any prompt, the model will hallucinate unpredictably, and the user’s first experience becomes confusion rather than magic.

**Solution: Auto-captioning pipeline.** Before submitting a sketch for generation, the client (or a lightweight backend endpoint) runs the sketch through a small vision-language model (e.g., a distilled BLIP-2 or Apple’s on-device VLM via Core ML) to produce a 5–15 word caption describing what the sketch appears to depict. This caption is used as the hidden prompt, combined with the style preset’s template. The user never sees this caption unless they opt into an “AI guess” tooltip for transparency.

If the auto-caption confidence is low, the app can display a gentle nudge: “Add a few words to help the AI understand your sketch.” This progressive disclosure keeps the default path frictionless while gracefully handling edge cases.

## 5. MVP Feature Set

### 5.1 Required for v1

| **Feature**                 | **Priority** | **Notes**                                                                 |
|-----------------------------|--------------|---------------------------------------------------------------------------|
| Split-screen layout         | P0           | Drawing left, generation right. Landscape only for v1.                    |
| PencilKit drawing canvas    | P0           | Apple Pencil + finger support. Must never lag.                            |
| Auto-generate on idle       | P0           | Debounce: 300ms preview, 1200ms refine.                                   |
| Preview generation pass     | P0           | Low-res, fast. Target <1s via fal.ai LCM endpoint.                       |
| Refined generation pass     | P0           | Higher quality. Target 2–5s.                                              |
| Latest-request-wins         | P0           | Cancel stale requests. Only newest updates UI.                            |
| Auto-captioning (no prompt) | P0           | VLM-based sketch captioning for zero-prompt UX.                           |
| Optional prompt input       | P0           | Text field below canvas, not required.                                    |
| Style presets               | P1           | 5–7 presets: Photoreal, Anime, Watercolor, Storybook, Fantasy, Ink, Neon. |
| Sketch adherence slider     | P1           | Maps to ControlNet conditioning scale (0.3–1.0).                          |
| Save to gallery             | P1           | Local storage with metadata (prompt, style, seed, thumbnail).             |
| Undo/redo                   | P0           | PencilKit native.                                                         |
| Clear canvas                | P0           | Single tap + confirmation.                                                |
| Content safety filter       | P0           | NSFW filter on generated output. Required for App Store.                  |
| AI data disclosure          | P0           | First-launch consent screen per Apple guideline 5.1.2(i).                 |
| Age gate                    | P0           | Declared age range per Apple guideline 1.2.1(a).                          |

### 5.2 Nice-to-Have for v1

- Seed lock for reproducibility.

- Variation button (“Show me another take on this”).

- Crossfade animation between generations.

- Pin result before continuing to draw.

- Simple gallery of prior outputs.

- Resizable divider between canvas and result pane.

### 5.3 Explicitly Deferred to v2+

- Layer support and region-specific editing.

- Inpainting / outpainting / mask painting.

- Portrait orientation (vertical stack layout).

- Animation or video generation.

- Collaborative/shared sessions.

- On-device inference as default (revisit when Apple Silicon neural engine supports SD 3.5-class models).

- Custom model picker UI.

## 6. UX Specification

### 6.1 Layout

**Left pane (Drawing Canvas):** Occupies approximately 55% of screen width in landscape (biased slightly toward the drawing side for comfort). PencilKit canvas with a minimal floating toolbar: brush, eraser, undo, redo, clear. Toolbar is semi-transparent and auto-hides after 3 seconds of inactivity. Canvas background defaults to white.

**Right pane (AI Result):** Occupies approximately 45% of screen width. Displays generation states: empty state, generating preview (subtle shimmer overlay), preview result, refining (subtle progress indicator), refined result, error state. Always keeps the last successful image visible; never shows a blank pane after the first successful generation.

**Bottom control strip:** Prompt input field (placeholder: “Describe what you’re drawing, or leave blank”), style preset chips (horizontally scrollable), generate mode toggle (Auto/Manual). An expandable tray reveals advanced controls: sketch adherence slider, creativity slider, seed lock toggle.

**Resizable divider:** A draggable divider between panes allows users to adjust the split from 40/60 to 70/30. This addresses the concern that a fixed 50/50 split feels cramped on iPad Mini and standard iPad models. The divider position persists across sessions.

### 6.2 Orientation & Device Support

v1 targets landscape orientation exclusively. Portrait mode is deferred to v2 (vertical stack layout). The app must function well on all iPad models running iPadOS 17+, including iPad Mini (8.3” display). On smaller screens, the default split biases further toward the drawing pane (60/40), and the bottom control strip collapses to a single-line prompt field with a settings gear icon.

### 6.3 Drawing Behavior

- Pencil strokes must render immediately with zero dependency on network or model calls.

- Default brush: medium-weight, high-contrast black ink to maximize ControlNet edge detection quality.

- Brush presets: fine pen, marker, soft pencil, flat brush. Keep it minimal; this is not Procreate.

- Canvas background: white by default, with an option for light gray (improves visibility of white-highlight strokes).

- Palm rejection via PencilKit native support.

### 6.4 Generation Behavior

- **Idle debounce:** Preview request fires after 300ms of no new strokes. Refine request fires after 1200ms.

- **Active drawing:** While the user is actively drawing, do not send any generation requests. Cancel or ignore all in-flight requests when new strokes begin.

- **Latest-request-wins:** At most 1 active preview and 1 active refine request per session. New input obsoletes prior jobs.

- **Result display:** Keep the most recent successful image visible until a newer one is ready. Crossfade transition (200ms) between old and new images.

- **Prompt changes:** Changing the prompt or style preset triggers a new generation immediately (no idle wait required).

### 6.5 States

| **State**          | **Right Pane Behavior**                                          | **Indicator**                    |
|--------------------|------------------------------------------------------------------|----------------------------------|
| Empty              | Message: “Start drawing to see your image come to life.”         | None                             |
| Generating Preview | Show previous image (or placeholder) with subtle shimmer overlay | “Creating preview…” label        |
| Preview Displayed  | Show preview image                                               | None                             |
| Refining           | Keep preview visible, subtle progress ring in corner             | “Refining…” label                |
| Refined Displayed  | Show refined image (crossfade from preview)                      | None                             |
| Error              | Keep last successful image. Small non-blocking toast.            | “Couldn’t update. Tap to retry.” |

## 7. Model Strategy & Provider Selection

### 7.1 Requirements for the Generation Model

The generation model must support sketch/scribble-conditioned image generation via ControlNet or an equivalent structural conditioning mechanism. It must accept an optional text prompt, support adjustable conditioning strength (sketch adherence), and deliver preview-quality results in under 2 seconds with refined results in under 5 seconds.

### 7.2 Recommended v1 Model Stack

Based on current benchmarks and API availability, the recommended stack for v1 is:

| **Component**           | **Recommendation**                                                                       | **Rationale**                                                                                                                                                                                                            |
|-------------------------|------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Preview Generation      | SD 1.5 + LCM-LoRA via fal.ai real-time endpoint                                          | fal.ai demonstrated 150ms generation with LCM at 4 inference steps. SD 1.5 produces superior results to SDXL for hand-drawn sketch inputs at low step counts. WebSocket support enables 3–5 fps for near-real-time feel. |
| Refined Generation      | SDXL + ControlNet Scribble (xinsir/controlnet-scribble-sdxl-1.0) via fal.ai or Replicate | SDXL at 20–30 steps with ControlNet Scribble produces high-quality, aesthetically strong images from sketches. The xinsir model was trained on 10M+ images with high aesthetic scores.                                   |
| Structural Conditioning | ControlNet Scribble mode                                                                 | Scribble mode is purpose-built for hand-drawn input. Supports variable line thickness: thick lines give loose guidance (more creative freedom), thin lines give stronger structural control.                             |
| Auto-captioning         | BLIP-2 (distilled) or on-device Apple VLM via Core ML                                    | Generates 5–15 word caption from sketch for the no-prompt experience. Can run on-device to avoid additional API latency.                                                                                                 |
| Fallback Provider       | Replicate (jagilley/controlnet-scribble or black-forest-labs/flux-canny-pro)             | Replicate offers ControlNet Scribble at ~0.6s per image with LCM. FLUX Canny Pro provides professional-grade edge-conditioned generation for the refine pass.                                                            |

### 7.3 Provider Abstraction

The backend must implement a provider adapter layer that abstracts the differences between inference providers. This is non-negotiable for v1. The model landscape is moving fast; fal.ai is the current best option, but FLUX ControlNet models from Black Forest Labs are improving rapidly and may become the preferred provider within 6 months.

The provider interface accepts: sketch image (base64 or URL), prompt (string), style preset (enum), conditioning strength (float 0.0–1.0), seed (optional int), mode (preview or refine). It returns: image (URL or bytes), seed used, latency in milliseconds, and provider job ID.

### 7.4 Why Not On-Device for v1?

- Current iPad Neural Engine performance is insufficient for continuous real-time ControlNet inference at acceptable quality. SD 1.5 via Core ML can generate an image in 10–15 seconds on M2 iPad Pro, far too slow for the preview-first UX.

- Memory constraints: SDXL + ControlNet requires 6–8 GB of model weights in memory, which competes with PencilKit and the app’s own UI for the iPad’s unified memory pool.

- Server-side inference allows iteration on model quality, prompt strategy, and provider selection without app updates.

- On-device generation should be revisited for v2+ as Apple Silicon and model distillation techniques improve. A hybrid mode (on-device preview, server-side refine) is a plausible v2 target.

### 7.5 Inference Cost Modeling

This is the critical business viability question the original spec omitted. Server-side GPU inference for continuous generation is expensive. Below is a cost model based on current provider pricing:

| **Metric**                         | **Preview (LCM)** | **Refine (SDXL ControlNet)** | **Notes**                                         |
|------------------------------------|-------------------|------------------------------|---------------------------------------------------|
| Provider                           | fal.ai            | fal.ai / Replicate           |                                                   |
| Cost per image                     | ~\$0.003          | ~\$0.02                      | Based on fal.ai GPU-second pricing (~\$0.001/sec) |
| Latency                            | 150–500ms         | 2–5 seconds                  |                                                   |
| Generations per session (avg)      | 30 previews       | 8 refines                    | Assumes 15-min session with moderate drawing      |
| Cost per session                   | \$0.09 previews   | \$0.16 refines               | Total: ~\$0.25/session                            |
| Power user session                 | 80 previews       | 20 refines                   | Total: ~\$0.64/session                            |
| Monthly cost (casual, 10 sessions) |                   |                              | \$2.50/month                                      |
| Monthly cost (power, 30 sessions)  |                   |                              | \$19.20/month                                     |

**Implication:** A \$9.99/month subscription supports casual users with comfortable margins. Power users at 30+ sessions/month approach breakeven at \$9.99 and require the \$19.99 tier. See Section 8 for pricing tiers.

## 8. Business Model & Pricing

### 8.1 Pricing Strategy

The app uses a freemium subscription model, distributed exclusively through the Apple App Store (30% revenue share, 15% after year 1 for subscribers). Apple’s November 2025 guideline updates do not fundamentally change the business model, but the AI data disclosure requirements must be front-and-center in onboarding.

| **Tier**       | **Price**     | **Generations/Day** | **Features**                                                                                    |
|----------------|---------------|---------------------|-------------------------------------------------------------------------------------------------|
| Free (Explore) | \$0           | 10 generations      | Preview quality only. Watermark on saved images. 3 style presets.                               |
| Plus           | \$9.99/month  | 150 generations     | Preview + refine. No watermark. All style presets. Gallery/history. Seed lock.                  |
| Pro            | \$19.99/month | Unlimited           | Everything in Plus. Priority queue. Bulk export. Higher resolution output. API access (future). |

Annual pricing at 2 months free (\$99.99/year for Plus, \$199.99/year for Pro). Family sharing support deferred to v2.

### 8.2 Unit Economics

At the Plus tier (\$9.99/month), after Apple’s 30% cut, net revenue is \$7.00/month. With average inference costs of \$2.50–\$5.00/month per casual-to-moderate user, gross margin is 29–64%. At the Pro tier (\$19.99/month), net revenue is \$14.00/month, supporting power users whose inference costs may reach \$10–19/month. The Pro tier is designed to be roughly breakeven-to-profitable for the heaviest users, with the Plus tier carrying higher margins to subsidize the free tier.

The free tier serves as acquisition. At 10 generations/day, daily cost per free user is approximately \$0.05 (assuming 60% of free users generate on any given day). With a target 5% free-to-paid conversion rate, the customer acquisition cost via the free tier is approximately \$30 (assuming a 60-day average conversion window).

## 9. Content Safety & App Store Compliance

This section was absent from the original spec and is non-negotiable for an App Store submission. Any app that sends user-generated content (sketches, prompts) to a server and returns AI-generated images must address content safety at multiple levels.

### 9.1 Apple App Store Requirements

- **Guideline 5.1.2(i) — Third-party AI disclosure:** As of November 2025, apps must clearly disclose where personal data will be shared with third-party AI and obtain explicit permission before doing so. The app must present a clear, specific consent screen at first launch identifying the AI inference provider(s) and what data is transmitted (sketch images, prompts). A generic privacy policy link is insufficient.

- **Guideline 1.2.1(a) — Age restrictions for creator apps:** Creator apps must implement age restriction mechanisms based on verified or declared user age. The app should use Apple’s Declared Age Range API (available late 2025) to restrict access for underage users to content that exceeds the app’s stated age rating.

- **User-generated content requirements:** Apps with UGC must include a method for filtering objectionable material, a mechanism to report offensive content, the ability to block abusive users, and published contact information.

### 9.2 Content Moderation Pipeline

- **Input filtering:** Prompt text is screened against a blocklist and a lightweight text classifier before submission to the model. Rejected prompts receive a gentle error: “We couldn’t process that prompt. Try describing your drawing differently.”

- **Output filtering:** All generated images pass through an NSFW classifier before display. Images flagged as potentially objectionable are replaced with a blurred placeholder and a notice. Stability AI’s API includes built-in NSFW filtering; fal.ai requires client-side or backend-side classification.

- **Logging and review:** Flagged content (both input prompts and output images) is logged for periodic human review. No user sketch data is retained beyond the generation request lifecycle unless the user explicitly saves to their gallery.

- **User reporting:** A “Report this image” button on every generated output allows users to flag content for review.

### 9.3 Privacy Design

- Sketch images and prompts are transmitted to the server encrypted via TLS 1.3.

- Sketch data is ephemeral: deleted from server memory after the generation response is returned. Not stored, not used for training, not shared.

- Generated images are cached on the server for up to 7 days (per fal.ai’s standard policy) to enable re-download. Users are informed of this in the consent screen.

- No analytics data is collected beyond anonymized usage metrics (session length, generation count, style preset usage). No PII is transmitted to analytics providers.

- The privacy policy and consent screen are available in the app’s Settings at all times, not just during onboarding.

## 10. Generation Pipeline Design

### 10.1 Input Pipeline

9.  Capture current drawing snapshot from PencilKit as a raster image.

10. Flatten to high-contrast monochrome (maximize edge signal for ControlNet).

11. Crop to content bounds with 10% padding to preserve composition context.

12. Resize to model-friendly resolution: 512x512 for preview (SD 1.5), 1024x1024 for refine (SDXL).

13. If no user prompt: run auto-captioning to generate a hidden prompt from the sketch.

14. Combine prompt (user or auto-generated) with style preset template. Example template for “Watercolor”: “{caption}, watercolor painting, soft washes, visible brushstrokes, wet-on-wet technique, artistic, beautiful”.

15. Package as JSON payload with session ID, request ID, mode, and generation parameters.

### 10.2 Preview vs. Refine

| **Attribute**   | **Preview Mode**                 | **Refine Mode**              |
|-----------------|----------------------------------|------------------------------|
| Purpose         | Fast early feedback              | High-quality final output    |
| Model           | SD 1.5 + LCM-LoRA                | SDXL + ControlNet Scribble   |
| Resolution      | 512x512                          | 1024x1024                    |
| Inference steps | 4–6                              | 20–30                        |
| Target latency  | <1 second                       | 2–5 seconds                  |
| Cost per image  | ~\$0.003                         | ~\$0.02                      |
| Quality         | Noisy but compositionally useful | Clean, detailed, publishable |

### 10.3 Request Scheduling Rules

- At most 1 active preview and 1 active refine request per session at any time.

- When new input arrives: obsolete preview and refine jobs are cancelled via the /cancel endpoint or ignored on the client side.

- Only the newest successful result is allowed to update the UI.

- A request is considered stale if a newer request ID has been issued since it was dispatched.

### 10.4 Latency Targets & Fallback UX

These are product targets. If they cannot be met, the following fallback behaviors apply:

| **Metric**             | **Target**          | **Acceptable** | **Fallback UX if Exceeded**                                                                    |
|------------------------|---------------------|----------------|------------------------------------------------------------------------------------------------|
| Canvas stroke response | Instant (<16ms)    | N/A            | Critical bug. Stop ship.                                                                       |
| Preview generation     | <1 second          | <2 seconds    | If consistently >2s, switch to lower-step LCM (2 steps) or reduce resolution to 384x384.      |
| Refined generation     | 2–5 seconds         | <8 seconds    | If consistently >5s, show a subtle progress bar. If >8s, notify user and offer manual retry. |
| Auto-caption           | <200ms (on-device) | <500ms        | If on-device VLM too slow, use server-side caption with the generation request.                |

## 11. API Design

### 11.1 Generate Endpoint

**POST /v1/generate**

Request body includes: sessionId (string), requestId (string, UUID), mode (“preview” or “refine”), prompt (string, optional), autoCaption (string, auto-generated if prompt is empty), stylePreset (enum), adherence (float 0.0–1.0, default 0.7), creativity (float 0.0–1.0, default 0.5), seed (int, optional), aspectRatio (string, default “1:1”), sketchImageBase64 (string), and metadata (canvasWidth, canvasHeight, appVersion, deviceModel).

Response body includes: requestId, status (“completed”, “filtered”, “error”), imageUrl (signed URL, 7-day expiry), seed, provider, latencyMs, mode, and contentFilterResult (object with flagged boolean and categories).

### 11.2 Cancel Endpoint

**POST /v1/cancel**

Accepts sessionId and requestId. Returns acknowledgment. Backend forwards cancellation to provider if the job is still in-flight.

### 11.3 History Endpoint

**GET /v1/history?sessionId=...&limit=50&offset=0**

Returns paginated list of generated images with metadata. Optional for v1 if history is local-only. Required for v2 if we add cloud-synced gallery.

### 11.4 WebSocket Endpoint (Preview Fast Path)

**WSS /v1/generate/stream**

For sub-second preview generation, a WebSocket connection to fal.ai’s real-time LCM endpoint avoids HTTP overhead. The client maintains a persistent WebSocket connection during active drawing sessions. Sketch snapshots are sent as binary frames, and generated preview images are returned as binary frames. This path can achieve 3–5 fps for near-real-time generation. Falls back to the REST endpoint if WebSocket connection drops.

## 12. Error Handling

| **Failure Mode**         | **UX Behavior**                                                                          | **Engineering Behavior**                                                                        |
|--------------------------|------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| Network timeout          | Keep last successful image. Show inline toast: “Connection lost. Retrying…”              | Retry up to 3x with exponential backoff. Log latency and failure.                               |
| Provider failure (5xx)   | Same as timeout                                                                          | Failover to secondary provider (Replicate) if primary (fal.ai) returns errors for >30 seconds. |
| Rate limit exceeded      | Show toast: “You’ve hit your generation limit. Upgrade for more.”                        | Enforce rate limits client-side before hitting backend. Track daily generation count.           |
| Content filter triggered | Replace image with blur + message: “This result was filtered. Try a different prompt.”   | Log event. Do not display the filtered image. Do not count against user’s generation quota.     |
| Invalid prompt           | Inline validation: “Please use a shorter prompt (max 500 characters).”                   | Reject at API gateway before forwarding to provider.                                            |
| Memory pressure (client) | Reduce snapshot resolution. If persistent, show “Close other apps for best performance.” | Monitor memory usage. Flush image cache proactively.                                            |

**Critical rule:** Never clear the last successful image because of a new failure. The right pane should always show something useful.

## 13. Metrics & Success Criteria

### 13.1 North Star Metric

**Weekly active creators who save at least one generation.** This measures both engagement (they opened the app and drew) and satisfaction (they liked the result enough to save it).

### 13.2 Product Metrics

| **Metric**                       | **Target (3 months post-launch)** | **Measurement**        |
|----------------------------------|-----------------------------------|------------------------|
| DAU / MAU ratio                  | >15%                             | Analytics              |
| Sessions per user per week       | >3                               | Analytics              |
| Average session length           | >8 minutes                       | Analytics              |
| Saves per session                | >2                               | Client events          |
| Free-to-paid conversion (30-day) | >5%                              | Subscription analytics |
| Day 7 retention                  | >30%                             | Cohort analysis        |
| Day 30 retention                 | >15%                             | Cohort analysis        |
| App Store rating                 | >4.5 stars                       | App Store Connect      |

### 13.3 Performance Metrics (SLIs)

| **Metric**                              | **p50 Target** | **p95 Target** |
|-----------------------------------------|----------------|----------------|
| Time from first stroke to first preview | <2 seconds    | <4 seconds    |
| Preview latency                         | <800ms        | <2 seconds    |
| Refine latency                          | <3 seconds    | <6 seconds    |
| Canvas stroke input latency             | <8ms          | <16ms         |
| Stale generation discard rate           | <30%          | N/A            |

### 13.4 Quality Metrics

- Perceived sketch adherence (user survey, 1–5 scale, target >3.8).

- Prompt relevance (user survey, 1–5 scale, target >4.0).

- Save/share rate as a proxy for output quality satisfaction.

- Content filter false positive rate (target <2% of generations flagged incorrectly).

## 14. Rollout Plan

| **Phase**              | **Duration** | **Goal**                                                | **Key Deliverables**                                                                                                                                                     |
|------------------------|--------------|---------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1: Prototype           | Weeks 1–4    | Validate core interaction loop and provider integration | PencilKit canvas + fal.ai LCM integration. Split-screen layout. Preview-only generation. Internal dogfood.                                                               |
| 2: MVP                 | Weeks 5–10   | Ship a cohesive creative experience to TestFlight       | Preview + refine pipeline. Auto-captioning. Prompt + style presets. Content safety filters. Gallery/history. Error handling. Basic analytics. App Store consent screens. |
| 3: Launch              | Weeks 11–13  | Public App Store release                                | Performance tuning. App Store review preparation. Privacy policy finalization. Marketing assets. Press outreach.                                                         |
| 4: Quality & Retention | Weeks 14–20  | Improve creative outcomes and repeat use                | Seed lock. Pinned results. Crossfade animations. Better style tuning. Gallery improvements. Subscription paywall optimization.                                           |
| 5: Advanced (v2)       | Months 6–12  | Expand creative capabilities                            | Region editing. Inpainting. Portrait mode. On-device preview. Family sharing. Cloud-synced gallery.                                                                      |

## 15. Open Questions & Decision Log

| **Question**                                                     | **Status**                    | **Current Position**                                                                    | **Owner**           |
|------------------------------------------------------------------|-------------------------------|-----------------------------------------------------------------------------------------|---------------------|
| Default sketch adherence strength?                               | Needs testing                 | Start at 0.7, A/B test 0.5–0.9 range during beta                                        | Product + Design    |
| Should preview prioritize composition fidelity or visual beauty? | Needs testing                 | Lean toward composition (that’s the product promise), validate with user testing        | Product             |
| How many style presets before choice overload?                   | Needs testing                 | Start with 5–7, add more based on usage data                                            | Design              |
| Is manual mode needed for v1?                                    | Decision: Yes                 | Include as a toggle. Some users want explicit control over when generation fires.       | Product             |
| Should history be session-scoped or account-scoped?              | Decision: Session for v1      | Local session history in v1. Account-scoped cloud history in v2.                        | Engineering         |
| Which VLM for auto-captioning?                                   | Needs spike                   | Test Apple’s on-device VLM (if available in iPadOS 18) vs. distilled BLIP-2 via Core ML | Engineering         |
| WebSocket vs. REST for preview?                                  | Decision: WebSocket preferred | Use fal.ai WebSocket endpoint for preview. REST fallback.                               | Engineering         |
| How to handle the free tier abuse vector?                        | Open                          | Rate limiting + device fingerprinting + Apple’s account system                          | Engineering + Trust |

## 16. Suggested Next Artifacts

16. Screen-by-screen wireframes (Figma) with interaction annotations.

17. SwiftUI view hierarchy specification and component library.

18. Backend service architecture diagram with request lifecycle and provider failover logic.

19. API contract document (OpenAPI 3.0 spec).

20. Engineering milestone plan for the first 13 weeks (Phases 1–3).

21. Model/provider evaluation spike: benchmark fal.ai LCM, fal.ai SDXL ControlNet, Replicate ControlNet Scribble, and FLUX Canny Pro on a standardized set of 50 sketch inputs across 5 style presets. Measure latency, cost, sketch adherence, and aesthetic quality.

22. Content safety test plan: adversarial prompt testing, edge-case sketch testing, NSFW classifier false positive/negative analysis.

23. App Store submission checklist including privacy policy, consent screen copy, and age rating justification.

*End of document. This PRD is a living document and will be updated as decisions are made and validated through user testing, engineering spikes, and market feedback.*
