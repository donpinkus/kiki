# Plan: Evaluate semantic-draw for Kiki

## Context

Kiki currently has two generation backends:

1. **Standard mode** — REST request/response to ComfyUI on RunPod, running Qwen-Image 20B FP8 + InstantX ControlNet Union + AnyLine lineart preprocessor + Lightning LoRA. Single prompt, single full-image generation, ~6–8s latency. (`backend/src/modules/providers/comfyui.ts`, workflow at `backend/src/modules/providers/comfyui-workflow-api.json`.)
2. **Stream mode** — WebSocket relay to a Python StreamDiffusion server on the same RunPod pod, running SD 1.5 (Lykon/dreamshaper-8) + LCM-LoRA. Real-time img2img at ~7 FPS, single prompt, no region/mask support. (`backend/src/modules/providers/streamdiffusion.ts`, `backend/src/routes/stream.ts`, iOS side at `ios/Kiki/App/StreamSession.swift` and `ios/Packages/NetworkModule/Sources/NetworkModule/StreamWebSocketClient.swift`.)

We are exploring whether to add **semantic-draw** (CVPR 2025, by Jaerin Lee — formerly StreamMultiDiffusion) as a third backend. Semantic-draw is a real-time interactive text-to-image framework that lets the user assign different prompts to different *regions* of the canvas via masks ("painting with meanings"), and was authored by the same lab that made StreamDiffusion.

**Product direction (confirmed with the user):** Kiki is moving toward a Photoshop/Procreate-style **layered** drawing model. Each layer has both ink and a semantic text label. A "background" layer is the collapsed view of all non-semantic drawings; the remaining layers each represent one semantic region (e.g. "buildings", "sky", "trees"). This maps cleanly onto semantic-draw's primitive: background image + N (mask, prompt) layers. The drawing engine may no longer be PencilKit — the integration should be drawing-engine-agnostic on the iOS side.

**Goal of this document:** *Not* a detailed integration plan — we want to understand semantic-draw's architecture, surface the key engineering questions, and identify what we'd need to decide before committing to a spike. The user is comfortable with slow startup and warm-up for the first spike — the goal is to **learn what's slow**, not to optimize.

---

## What semantic-draw is

- **Paper:** *SemanticDraw* (CVPR 2025), Jaerin Lee et al. — formerly StreamMultiDiffusion. Real-time interactive text-to-image with per-region prompts. Combines three ideas: **StreamDiffusion** (real-time batched denoising), **MultiDiffusion** (region-based semantic control), and **LCM/Lightning** (distilled fast inference).
- **Repo:** https://github.com/ironjr/semantic-draw — **MIT license**.
- **Supported model variants:** SD 1.5 + LCM-LoRA, SDXL + Lightning LoRA, SD3 + Flash Diffusion, Kolors. Default resolutions: 512² (SD 1.5), 1024² (SDXL), 2560×1024 (panorama). Custom `.safetensors` and HF keys supported.
- **No ComfyUI nodes** exist; no FastAPI; no REST. Every shipped interface is Gradio.
- **Hardware:** ≥8 GB VRAM at 512×512, ≥11 GB for 1024×1024. Tested on a 1080 Ti at ~500 ms/frame. Comfortable on Kiki's H100.
- **Special dependency wrinkle:** `requirement.txt` pins **a custom diffusers fork** — `diffusers @ git+https://github.com/initml/diffusers.git@clement/feature/flash_sd3` — plus `xformers`, `peft`, `transformers`, `gradio`. This will be its own dependency-resolution puzzle on the pod.

### Demo surface area

- `demo/stream/app.py` — Gradio "Semantic Drawpad" with 60-second streaming sessions, up to 3 layers + background. Key functions: `register()` (initialize), `run()` (streaming loop), `draw()` (live mask updates). Likely the closest match for our use case. **Important: this demo is SD 1.5** (`from model import SemanticDraw` — the `SemanticDrawSDXL` import directly below it is commented out), with `has_i2t=False` (BLIP-2 not loaded) and default model `ironjr/BlazingDriveV11m`. Default port 8000, no `server_name` → binds 127.0.0.1.
- `demo/canvas/`, `demo/canvas_sdxl/`, `demo/canvas_sd3/` — full canvas editors with up to 5 semantic layers, palette import/export, prompt/strength sliders.
- `notebooks/demo_simple*.ipynb`, `demo_stream.ipynb`, `demo_inpaint*.ipynb`, `demo_panorama.ipynb` — minimal API examples per model.

### Pipeline classes (in `src/model/`)

- `SemanticDrawPipeline` — SD 1.5
- `SemanticDrawSDXLPipeline` — SDXL (most likely target for us)
- `SemanticDraw3Pipeline` — SD3
- Each is paired with a lower-level core class (`SemanticDraw`, `SemanticDrawSDXL`, `SemanticDraw3`) that owns the long-lived state for streaming.

**Constructor (SDXL):** `device, dtype=fp16, hf_key, lora_key, lora_weight, default_mask_std, default_mask_strength, default_prompt_strength, default_bootstrap_steps, t_index_list=[0,4,12,25,37], mask_type='discrete'|'semi-continuous'|'continuous', has_i2t=True, ...`

**Public methods (the "register-then-stream" pattern):**
- `update_background(image, prompt, negative_prompt)` — set the background image (the sketch). With `has_i2t=True`, BLIP-2 auto-captions if prompt omitted.
- `update_layers(prompts, negative_prompts, masks, ...)` — register all foreground layers at once.
- `update_single_layer(idx, prompt, mask, ...)` — incremental edit / append for a single layer.
- `process_mask(mask, std, strength)` — preprocess one mask through the pipeline (resize → order → blur → quantize).
- `__call__(...)` — run one denoising pass and return the latest frame (PIL Image, or latent with `no_decode=True`).
- `flush()` — drain the streaming buffer.

### Algorithm in one sentence

Each timestep does one batched UNet step per region, composites by summing `mask[i] * denoised[i]` and normalizing by overlap counts, blends the background latent into the unmasked area, and uses **mask quantization** (stronger early, softer late) plus a **bootstrap** step to avoid hard seams — all made interactive by LCM/Lightning distillation.

## How it maps onto Kiki

The mapping from the user's intended layered UX to semantic-draw's primitives is direct:

| Kiki layered UX | semantic-draw primitive |
|---|---|
| Collapsed non-semantic drawings | `update_background(image, prompt)` |
| Each semantic layer's filled area | one entry in `update_layers(masks=...)` |
| Each semantic layer's text label | one entry in `update_layers(prompts=...)` |
| Adding a stroke to a semantic layer | `update_single_layer(idx, mask, prompt)` |

**Kiki's existing stream mode is the closest cousin in the codebase.** StreamDiffusion and SemanticDraw share authorship, the `t_index_list` parameter, the warm-up frame model, and the LCM/Lightning real-time philosophy. The Kiki stack already has:

- A WebSocket relay route in the backend (`backend/src/routes/stream.ts`) that forwards JPEGs and a JSON config message to a long-lived Python server.
- An iOS `StreamSession` (`ios/Kiki/App/StreamSession.swift`) that captures the canvas at ~7 FPS, resizes to 512² JPEG, and sends with `{prompt, tIndexList}` config.
- A Python server pattern (FastAPI + WebSocket on port 8765, deployed via the "Deploy StreamDiffusion" GH Action, isolated venv on the same RunPod pod) — see `documents/references/streamdiffusion.md`.

**The integration effort is dominated by the Python side**, swapping the StreamDiffusion pipeline for `SemanticDraw*` and extending the WebSocket protocol to carry per-region masks and prompts. The TypeScript relay passes config JSON through verbatim (`relay.sendConfig(parsed)` in `backend/src/routes/stream.ts:67`), so new keys like `layers: [{maskBase64, prompt}, ...]` ride along for free *as long as masks travel inside the JSON config*. If layer masks are large enough to want their own binary frames, the relay's binary path currently assumes one channel (JPEG → `sendFrame`) and would need a small framing tag. The iOS side needs a new layer-aware capture loop, but the existing `StreamWebSocketClient` reconnect/receive plumbing is reusable.

---

## What's already decided (after user clarification)

- **Semantic-draw is for the new layered UX only.** It's not a replacement for ComfyUI + Qwen-Image in standard mode and not a replacement for the existing single-prompt stream mode. It's a *third* engine.
- **Sketch-as-img2img is out of scope for the first spike.** The user wants to *reproduce semantic-draw's demo behavior first*, not extend it with ControlNet or any new conditioning. The mental model is: each semantic layer's filled area is its mask, the layer's label is its prompt, and the collapsed non-semantic drawing is the background image.
- **Performance optimization is out of scope for the first spike.** Slow startup is fine. The goal is to *measure* latency, warm-up cost, and per-stroke update cost, not to optimize them.
- **Dep isolation strategy is "whichever is easiest"** — could be a third venv on the existing pod or an entirely separate pod. We'll decide based on what the requirement.txt actually does on first install.
- **Drawing-engine-agnostic on iOS.** Kiki may have already moved off PencilKit. The integration should not assume PencilKit specifically — it just needs each layer to expose `(alpha mask, text label)`.

## High-level engineering questions

### 1. What exactly is the per-layer "mask"?
The product UX gives us a layer with ink on it. Semantic-draw expects a region mask that defines *where the prompt should generate content*. Three plausible interpretations:
- **Raw alpha:** the literal pixels covered by ink. Probably too thin — a building outline becomes a skinny silhouette, and the model gets a sliver to work with.
- **Filled / flood-filled alpha:** close any open shapes and fill them. Closer to "this region of the canvas is buildings."
- **Bounding shape (convex hull / dilated alpha):** generous region that covers the user's intent without requiring closed shapes.

The semantic-draw demo has the user paint solid blobs with a brush, so its masks are filled by construction. We need to replicate that, which means *post-processing the layer's ink alpha into a filled region* before sending it to the backend. The right algorithm (dilation? flood fill? hull?) is an open question, and the answer affects both client-side image work and how the user perceives the system's responsiveness to small strokes. **First spike answer: dilate-then-blur the alpha and see how it looks.**

### 2. What goes in the "background" image?
The user's plan: collapse all non-semantic drawings into one background layer. Open questions:
- Does `update_background()` accept a real image, or does it require something specific (e.g. an already-generated one)? The notebooks should answer this in 5 minutes.
- If the user has *no* non-semantic drawings, do we send pure noise, a blank canvas, a neutral color, or skip background registration entirely? Each option may produce different results.
- Should we run BLIP-2 auto-captioning (`has_i2t=True`) on the background, or always pass an empty/user-supplied prompt? Auto-captioning costs latency on every background change.

### 3. Does the streaming loop tolerate per-stroke layer updates?
This is the biggest performance unknown and could be disqualifying. When the user adds one stroke to one layer:
- Best case: `update_single_layer(idx, mask, prompt)` is cheap (just re-uploads the mask) and the next `__call__` produces a result within ~150 ms. Real-time works.
- Worst case: `update_single_layer` triggers re-encoding all layers / recomputes BLIP-2 / drains and re-fills the streaming buffer / re-warms. Then "live" sketching feels like a button press, not a brush.
- Middle case: the per-frame `__call__` is fast but `update_single_layer` is slow enough that we need to debounce.

Need to read `semantic_draw_sdxl.py`'s `update_single_layer` and `__call__` to find out where state lives and what's incremental. **Measuring this should be the highest-priority task in the spike** — it determines whether the product idea is viable as "live" or only as "tap to regenerate."

### 4. Which model variant?
SD 1.5 + LCM, SDXL + Lightning, SD3 + Flash, or Kolors?
- **SD 1.5 + LCM is what the `demo/stream/app.py` reference ships with** — and since our guiding principle is "reproduce the demo first, don't extend," this is the right path for spike #1. It also has the smallest VRAM footprint and the most mature dep set.
- SDXL + Lightning is the aspirational target for quality, but the stream demo's SDXL import is commented out. Moving to SDXL requires editing the demo or switching to `demo/canvas_sdxl/app.py` (different UX). Defer to phase 2.
- SD3 needs Flash Diffusion through the custom diffusers fork and is a riskier first install.
- Kolors is a less-trodden code path in the repo (`semantic_draw_kolors.py` was 404 in the agent's exploration).

### 5. Cold-start, warm-up, and per-stroke latency *(measure, don't optimize)*
StreamDiffusion has a noticeable warm-up (first few frames gray). Semantic-draw with N regions and possibly BLIP-2 captioning could be much worse. The user explicitly does not want to optimize this yet — but we should *report* the numbers from the spike:
- Pipeline init time (cold start, no weights cached).
- Warm-up cost on first `__call__` after construct.
- Time per frame at steady state with 1 / 2 / 4 semantic layers.
- Cost of `update_single_layer` and `update_background`.
- Whether changing a layer prompt requires re-warming.

### 6. Backend deployment shape
Two plausible shapes for the Python server:
- **A. Third venv on the existing kiki-comfyui pod**, alongside ComfyUI and StreamDiffusion. Mirrors the current StreamDiffusion deploy pattern (`--system-site-packages` venv at `/workspace/streamdiffusion-venv/`, weights cached under `/workspace/kiki-models/`, nohup launch, GH Action SCPs a setup script and SSHes in to run it). The pod currently has no third-venv-shaped hole but there's plenty of disk and VRAM for one.
- **B. Separate RunPod pod** dedicated to semantic-draw. Cleanest dependency isolation; used as a fallback only if option A's dep resolution proves impossible.
- (Docker on the same pod is a non-option: nothing else on the pod runs under Docker — ComfyUI and StreamDiffusion are plain venvs — and the base image isn't Docker-in-Docker friendly.)
**Recommendation: start with A via a manual first run (see Gradio demo section below); fall back to B only if `requirement.txt` can't be resolved alongside the existing venvs.**

### 7. Protocol & relay extensions
- **Config message:** extend `StreamConfig` to carry `layers: [{maskBase64, prompt, negativePrompt}]` plus an optional `background: {imageBase64, prompt}`. The TypeScript relay (`backend/src/routes/stream.ts:67`) forwards JSON config verbatim, so this is essentially free server-side.
- **Mask size:** at 512² a single-channel PNG is small enough to fit comfortably in JSON. At 1024² with 4 layers we should think about whether to break out a binary multipart format — but not for the first spike.
- **Frame loop:** today's `sendFrame` sends one canvas JPEG. With layers, we may not need a per-frame full-canvas JPEG at all — only the per-layer masks change. The `__call__` produces frames continuously on the server; the client mostly sends `update_single_layer` events. **The streaming pattern is fundamentally different from current stream mode**, and worth sketching out before implementation.

### 8. iOS layer model — drawing-engine agnostic
Kiki may be moving off PencilKit to a custom drawing engine. The integration should depend only on a generic interface like `protocol DrawingLayer { var alphaMask: CGImage { get }; var label: String { get }; var isSemanticLayer: Bool { get } }`. Any custom-engine work that exposes layers as alpha masks and labels would be reusable directly. This is more of a note than a question, but worth flagging because it means the iOS spike work should be deferred until the layered drawing engine has settled.

### 9. Content safety
Existing NSFW output filter still applies unchanged. The new wrinkle: the prompt input filter must run on **every per-layer label**, not just one. Easy code change, easy to forget.

---

## Suggested next concrete steps (after this plan is approved)

1. **Get the reference Gradio demo running** — see the dedicated "Gradio demo" section below for the full playbook. Uses `demo/stream/app.py` (SD 1.5 by default) on the existing RunPod pod in a new venv at `/workspace/semantic-draw-venv/`. Unblocks Q4, Q5, Q6 in one sitting.
2. **Read `semantic_draw.py` and `pipeline_semantic_draw.py` end-to-end** (SD 1.5 variants — matching what the stream demo actually uses) with two specific questions in mind:
   - What does `update_single_layer` cost? (Q3)
   - What does `update_background` accept and require? (Q2)
3. **Run a Python-only benchmark script** that mimics the Kiki layered UX — see Phase 3 of the Gradio demo section below.
4. **Only then** sketch out the WebSocket protocol extension and a minimal FastAPI wrapper around `SemanticDraw`. The spike doesn't need iOS work — we can validate the model and the perf shape entirely from a Python test client first.

---

## Gradio demo: concrete deployment plan

**Context:** This section is the executable playbook for step 1 above — get the reference `demo/stream/app.py` Gradio demo from `ironjr/semantic-draw` running on the existing `kiki-comfyui` RunPod pod so the user can interact with semantic-draw hands-on. Success for this phase is a URL the user can open in a browser, paint masks + type per-region prompts, and watch streaming output. Nothing else — no backend integration, no iOS work, no protocol design. The output of this phase is either (a) a working demo + empirical answers to Q2/Q3/Q5/Q6, or (b) a red-flag report that `requirement.txt` can't resolve, which makes us reconsider option B (separate pod) from Q6.

### Facts that shape the plan

From the research:

- **Demo is SD 1.5**, not SDXL. `demo/stream/app.py` does `from model import SemanticDraw`; the `SemanticDrawSDXL` line underneath is commented out. Default model `ironjr/BlazingDriveV11m` (public, no HF token). Smaller footprint and faster warm-up than SDXL would be — a *good* thing for the spike.
- **`has_i2t=False`** in the stream demo → BLIP-2 auto-captioning is not loaded. Neutralizes half of Q2.
- **Port 8000** (not 7860). `demo.launch(server_port=opt.port)` does *not* set `server_name`, so by default it binds 127.0.0.1.
- **File is `requirement.txt`** (singular). The README's `pip install -r requirements.txt` is wrong.
- **No `pyproject.toml`, no `setup.py`.** Imports use a runtime `sys.path.append('../../src')` hack — `python app.py` **must** run from `demo/stream/` as cwd.
- **`requirement.txt` is fully unpinned** (no version constraints on torch, xformers, transformers, peft, …) but includes a custom diffusers fork `git+https://github.com/initml/diffusers.git@clement/feature/flash_sd3`. Resolution will be fragile until we pin downstream ourselves.
- **MIT license**, confirmed.

Pod today:
- SSH: `ssh -i ~/.ssh/runpod_key -p <SSH_PORT> root@<SSH_IP>` (host/port extractable via RunPod API or the web UI).
- `/workspace` network volume survives pod restarts. ComfyUI at `/workspace/runpod-slim/ComfyUI/` (port 8188), StreamDiffusion at `/workspace/streamdiffusion-server/` with venv `/workspace/streamdiffusion-venv/` (`--system-site-packages`), shared model cache at `/workspace/kiki-models/`.
- Ports exposed: 8188, 8765, 22. **Port 8000 is NOT currently exposed.**
- External URL pattern: `https://<POD_ID>-<PORT>.proxy.runpod.net` (RunPod HTTPS proxy; handles WebSockets; no ngrok / no `share=True` needed for the long-term deploy).

### Pod model: existing pod, not a new one

**The Gradio demo uses the already-running `kiki-comfyui` pod. No new pod is created.** We SSH in, create a third venv alongside the existing two, clone the repo, install deps, launch Gradio. This mirrors what `scripts/setup-streamdiffusion.sh` did when StreamDiffusion was added — that script runs *on* the existing pod, it doesn't provision one.

- **Why not a dedicated pod?** Cost (second H100 in parallel) and redundancy — the existing pod has plenty of disk and VRAM for a third venv.
- **Pod *creation*** is owned by a separate workflow (`.github/workflows/deploy-pod.yml`). The Gradio spike does **not** touch that workflow in Phase 1. It touches it in Phase 2 only to add `8000/http` to the exposed ports list, which requires a pod rebuild — schedule at a time the user can afford ComfyUI/StreamDiffusion downtime.
- **Fallback (option B from Q6, not planned, only invoked if Phase 1 fails badly):** if `requirement.txt` cannot be resolved alongside the existing venvs — most likely failure mode is the diffusers fork conflicting irreparably with the base image's diffusers — we'd consider provisioning a *separate* dedicated semantic-draw pod with a clean base image. We are not writing scripts for that path until we know it's needed.

### Target on-pod layout

Mirroring the streamdiffusion pattern:
- `/workspace/semantic-draw/` — `git clone` of the repo.
- `/workspace/semantic-draw-venv/` — isolated venv with `--system-site-packages`.
- `/workspace/kiki-models/semantic-draw/huggingface/` — HF cache (`HF_HOME`).
- `/workspace/semantic-draw.log` — nohup log.
- Gradio served on port 8000, bound to `0.0.0.0`.
- (Phase 2) External URL: `https://<POD_ID>-8000.proxy.runpod.net`.

### Phase 1 — manual first run (no scripts, no automation)

The goal of Phase 1 is to find out what breaks, not to produce reusable automation. Do everything by hand in an SSH session. Write down each error and each fix. The output is either a working demo + a list of exactly which `pip install` commands it took, or a red-flag.

**Step 1. Open an SSH session with port 8000 forwarded.**
Port 8000 is not in the pod's `ports` config. The "correct" fix is to edit `.github/workflows/deploy-pod.yml` and recreate the pod, but that destroys transient state and forces a full ComfyUI + StreamDiffusion re-initialization — unacceptable for a spike. Instead, use SSH port-forward for the manual run:
```bash
ssh -L 8000:localhost:8000 -i ~/.ssh/runpod_key -p <SSH_PORT> root@<SSH_IP>
```
The user opens `http://localhost:8000` on their laptop; traffic rides the SSH tunnel. Zero pod mutation.

**This SSH session must stay alive for the entire test session** — closing it kills the tunnel and the laptop-side port-forward. The Gradio process itself will keep running (we'll launch it with `nohup`), but you'll need to re-open the tunnel to reconnect. A `tmux` or `screen` session inside SSH is the safer pattern for the manual run.

**Caveat:** iPad/mobile testing is blocked on the Phase 2 port config update — the manual run is laptop-only.

**Step 2. Clone the repo.**
```bash
cd /workspace
git clone https://github.com/ironjr/semantic-draw.git
cd semantic-draw
```

**Step 3. Create the isolated venv.** Mirror `scripts/setup-streamdiffusion.sh:26`.
```bash
python -m venv /workspace/semantic-draw-venv --system-site-packages
source /workspace/semantic-draw-venv/bin/activate
pip install --upgrade pip
```
`--system-site-packages` reuses torch/CUDA from the base image. If we discover a hard incompatibility (the diffusers fork needs a torch version the base can't provide), fall back to `--no-system-site-packages` and reinstall torch in the venv — budget 10-20 min for that.

**Step 4. Install deps — the file-name-correct way.**
```bash
pip install -r requirement.txt    # singular — README is wrong
```
This will *probably* not work cleanly on the first try. Expected failures and fixes, ranked by likelihood:
- **`xformers` wheel missing for the pod's torch version.** Check torch version first: `python -c "import torch; print(torch.__version__)"`, then `pip install xformers==<matching>`.
- **diffusers fork fails to build** against whatever `transformers` / `huggingface_hub` resolves. Apply the same pins streamdiffusion uses as a starting point (`transformers<4.43`, `huggingface_hub<0.25`) and retry.
- **`peft` version conflict.** Pin to a known-compatible older version.
- **`gradio` too new.** The HF Space metadata pins `sdk_version: 4.27.0` — use that as a known-good.
- **`accelerate` missing** (not in `requirement.txt` but required by diffusers) → `pip install accelerate`.
- **`sentencepiece` / `protobuf` version clash** with the base image's transformers — pin both to the versions `requirement.txt` implies.

Record every `pip install <foo>==<bar>` that was actually required, verbatim. This list is the source of truth for `setup-semantic-draw.sh` in Phase 2.

**Sanity check after install** — confirm the diffusers fork actually loaded (rather than the system-site-packages copy):
```bash
python -c "import diffusers; print(diffusers.__file__, diffusers.__version__)"
```
The path must be inside `/workspace/semantic-draw-venv/`. If it points at the base image's site-packages, the venv isn't shadowing it correctly and the rest of the run will silently use the wrong diffusers — investigate before proceeding.

**Step 5. Pre-download model weights to the shared cache.**
```bash
export HF_HOME=/workspace/kiki-models/semantic-draw/huggingface
mkdir -p $HF_HOME
python -c "from huggingface_hub import snapshot_download; snapshot_download('ironjr/BlazingDriveV11m')"
python -c "from huggingface_hub import snapshot_download; snapshot_download('latent-consistency/lcm-lora-sdv1-5')"
```
The stream demo's `SemanticDraw` loads LCM-LoRA internally; pre-pulling avoids a surprise download on first launch. The list may expand once we read `semantic_draw.py` to see every HF call the constructor makes (e.g. VAE, tokenizer) — if the first launch stalls on a download, tail the log, snapshot_download that key, retry.

**Step 6. Launch the Gradio demo.** The `sys.path.append('../../src')` hack forces `demo/stream/` as the cwd.
```bash
cd /workspace/semantic-draw/demo/stream
GRADIO_SERVER_NAME=0.0.0.0 \
HF_HOME=/workspace/kiki-models/semantic-draw/huggingface \
nohup /workspace/semantic-draw-venv/bin/python app.py \
  > /workspace/semantic-draw.log 2>&1 &
```
If `GRADIO_SERVER_NAME=0.0.0.0` isn't honored (it depends on the Gradio version), apply a one-line patch to `demo/stream/app.py` — change `demo.launch(server_port=opt.port)` to `demo.launch(server_port=opt.port, server_name="0.0.0.0")`. Record the patch if we make it.

**Step 7. Watch the log, wait for "Running on".**
```bash
tail -f /workspace/semantic-draw.log
```
Expect 30-120 s of weight-loading and pipeline init on first run.

**Step 8. Access from laptop** via the tunnel from step 1 → `http://localhost:8000`.

**Step 9. Exercise the demo manually:**
- Paint a background, paint 2-3 foreground regions, set per-region prompts, start a 60-second streaming session.
- Add a stroke to an existing layer *while streaming* — does it update live? (Hands-on preview of Q3.)
- Change one layer's prompt mid-stream — does it update live?
- Stopwatch (even roughly): (a) launch → first Gradio frame, (b) paint → new output frame, (c) prompt edit → new output frame.

**Step 10. Record findings** in this plan file under a new "Findings" section: exactly which `pip install`s were required, what broke, what felt fast, what felt slow, screenshots if useful, and whether the UX feels promising enough to justify Phase 2.

### Phase 2 — codify what worked (only if Phase 1 succeeds)

Only if the user, after hands-on time with the demo, wants to move forward. Output:

- **`scripts/setup-semantic-draw.sh`** — mirror `scripts/setup-streamdiffusion.sh` structure. Create venv, clone repo, install **exactly** the pinned deps recorded during Phase 1 (no reliance on unpinned `requirement.txt`), set `HF_HOME`, pre-download weights, apply the `server_name="0.0.0.0"` patch if needed, launch via `nohup`, poll a health endpoint (`curl -f http://localhost:8000/` — the Gradio page itself).
- **`.github/workflows/deploy-semantic-draw.yml`** — mirror `deploy-streamdiffusion.yml`. Find the running pod, SCP the setup script + any patch files, SSH execute, poll `https://<POD_ID>-8000.proxy.runpod.net/` for readiness. Does *not* update a Railway env var yet (the demo isn't wired into the Kiki app).
- **Pod port config update** — edit `.github/workflows/deploy-pod.yml` to change `ports: "8188/http,8765/http,22/tcp"` → `ports: "8188/http,8765/http,8000/http,22/tcp"`. Schedule the pod rebuild at a time the user can afford ComfyUI + StreamDiffusion downtime. After the rebuild, `scripts/setup-pod.sh` and `scripts/setup-streamdiffusion.sh` and (new) `scripts/setup-semantic-draw.sh` all re-run against the fresh pod.

### Phase 3 — benchmark the pipeline directly (answers Q3 / Q5)

Once the Gradio UI works, the remaining unknowns for Q3 and Q5 are best answered by a **Python-only** benchmark script that imports `SemanticDraw` directly, bypassing Gradio (Gradio adds its own latency and obscures what's model vs framework). Write `/workspace/semantic-draw/benchmark_kiki.py`:

1. Instantiate `SemanticDraw(device='cuda:0', dtype=torch.float16, hf_key='ironjr/BlazingDriveV11m', has_i2t=False, ...)`. Time `t_init`.
2. Call `update_background(bg_image, prompt="a street scene")`. Time `t_bg`.
3. Call `update_layers(prompts=[...], masks=[...])` with 1 / 2 / 3 / 4 synthetic blob masks + per-layer prompts. Time each.
4. Warm up with one `__call__`. Time `t_warmup`.
5. Run `__call__` N=100 times in a loop. Record per-frame wall-clock time → derive steady-state FPS.
6. Call `update_single_layer(idx=1, mask=new_mask, prompt=new_prompt)` mid-loop. Record the cost.
7. Call `update_single_layer(idx=1, mask=same_mask, prompt=different_prompt)` (prompt-only change). Record the cost.
8. Print a summary table: init / background / layer setup / warm-up / steady FPS / mask update / prompt update.

The output of this script is **the** data we owe Q3 and Q5. The Gradio demo tells us "does it work"; this tells us "is it fast enough for the product." Paste the numbers into the Findings section.

### How to verify this phase

| What | How to verify |
|---|---|
| Demo process is running | `tail -f /workspace/semantic-draw.log` shows "Running on" |
| UI reachable | `curl -f http://localhost:8000/` via the SSH tunnel returns 200 |
| Core features work | Manually: paint, prompt, stream — screenshot the output |
| Deps reproducible | Exact list of pinned `pip install` commands captured in Findings |
| Perf numbers | Phase 3 benchmark output captured in Findings |
| Go/no-go verdict | User decision: "yes, proceed to WebSocket protocol design" or "no, kill it" |

### Out of scope for the Gradio phase

- SDXL (defer — `demo/stream/app.py`'s SDXL import is commented out; switching to `demo/canvas_sdxl/app.py` is a different UX).
- Any Kiki backend or iOS integration work.
- The WebSocket protocol extension (`StreamConfig`, `layers`, masks-over-wire).
- GH Action automation (Phase 2).
- Permanent exposure of port 8000 via the RunPod proxy (Phase 2).
- Dep-pinning *cleanup* — we only pin what's required to reach green.
- Content safety wiring — the Gradio demo has no filter; acceptable because the phase is internal-only and laptop-tunneled.
- Any edits to `semantic_draw.py` itself. If we need to instrument anything, do it in the benchmark script, not by patching the library.

---

## Files / references

**semantic-draw upstream:**
- Repo: https://github.com/ironjr/semantic-draw (MIT)
- `demo/stream/app.py` — the canonical demo we're deploying. SD 1.5, port 8000, binds 127.0.0.1, requires `cd demo/stream && python app.py`.
- `requirement.txt` (singular) — fully unpinned, includes the custom diffusers fork.
- `src/model/semantic_draw.py` — SD 1.5 pipeline class (the one the stream demo actually uses).
- `src/model/pipeline_semantic_draw.py` — lower-level SD 1.5 pipeline.
- `src/model/semantic_draw_sdxl.py` / `pipeline_semantic_draw_sdxl.py` — SDXL variants (deferred to phase 2).

**Kiki templates to mirror for the deploy:**
- `documents/references/streamdiffusion.md` — narrative reference for the streaming-server-on-pod pattern.
- `scripts/setup-streamdiffusion.sh` — the on-pod setup script template (venv creation, dep install, weight pre-download, nohup launch, health-check loop).
- `.github/workflows/deploy-streamdiffusion.yml` — the GH Action template (find pod via RunPod API, SCP setup script + server files, SSH execute, poll proxy URL, update Railway env var).
- `scripts/setup-pod.sh` — pod initialization for ComfyUI; reference for `kiki-models` cache layout.
- `documents/references/provider-config.md` — pod creation, volume mounts, RunPod proxy URL pattern.
- `.github/workflows/deploy-pod.yml` — the file that owns the `ports` list we'll need to amend in Phase 2.

**Kiki integration touch points (for later phases, not the Gradio spike):**
- `backend/src/modules/providers/{streamdiffusion.ts,comfyui.ts,types.ts}`
- `backend/src/routes/stream.ts`
- `ios/Kiki/App/StreamSession.swift`
- `ios/Packages/NetworkModule/Sources/NetworkModule/{StreamWebSocketClient.swift,StreamConfig.swift}`
- `ios/Kiki/App/GenerationEngine.swift`

**On-pod paths (after Phase 1):**
- `/workspace/semantic-draw/` — git clone
- `/workspace/semantic-draw-venv/` — isolated venv (`--system-site-packages`)
- `/workspace/kiki-models/semantic-draw/huggingface/` — `HF_HOME`
- `/workspace/semantic-draw.log` — nohup output
