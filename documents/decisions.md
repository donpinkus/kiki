# Decision Log

Record implementation decisions here as they are made. Newest first. This prevents re-debating the same choices across sessions.

## Format

```
### YYYY-MM-DD — Decision Title
**Context:** Why this decision was needed
**Decision:** What was decided
**Alternatives considered:** What else was evaluated
**Consequences:** What this means for the codebase
```

---

### 2026-09-14 — Model-server code rolls out through the backend (fleet bundle + boot-time self-refresh)

**Context:** Getting new `model-servers/` code onto the ten region filesystems meant running `sync-fs.mts` from a laptop per (region × pool) — each run launches a throwaway instance, and regions with no capacity of any type can't be synced at all. The CUDA-preflight rollout sat half-done for hours with a retry loop on Donald's Mac that the OS killed twice. Owner: "I'm going to forget to do this. This should not live locally on my laptop but be some process the backend runs."

**Decision:** No sync process at all — every boot self-updates. `npm run deploy` packs `model-servers/` (minus `dev/`, caches) into `backend/fleet/{manifest.json,model-servers.tgz}` with a CONTENT hash (unchanged code = same manifest = no re-downloads); `fleet/` exists only during the upload (built by the deploy script, deleted after; `railway up` applies `.gitignore` even alongside a `.railwayignore`, so a gitignored bundle never ships); the backend serves it at `GET /v1/fleet/{manifest,bundle}` behind a bearer derived from `LAMBDA_API_KEY` (`modules/lambda/fleet.ts`). `instancePool.userData` now writes `/usr/local/bin/kiki-bootstrap` into every pool instance: fetch manifest → compare `$FS/kiki/app/.manifest` → under `flock $FS/kiki/.app.lock`, download + extract beside the old tree and `mv` it into the same `$FS/kiki/app` path (inductor cache keys are path-sensitive) → `pip install` only if the pool's requirements file hash changed → `exec $APP/<pool>/boot.sh`. Fetch/extract failure keeps the existing app; no `BACKEND_PUBLIC_URL` (defaults from `RAILWAY_PUBLIC_DOMAIN`) = boot what's there. `image/boot.sh` and `video/boot.sh` moved INTO the repo (they used to be heredocs in the setup scripts); the setup scripts now write a one-line shim at `$FS/kiki/boot.sh` for the manual launch/bench scripts. `/health` reports `app_manifest`/`app_git_sha` (`shared/app_version.py`, repointed from the RunPod-era path) and the `ready` pool event detail carries `app`, so Insights → Boots shows which code every boot ran.

**Alternatives considered:** a backend cron that launches sync instances per region (same capacity problem, plus a fleet of throwaway VMs); SSH from Railway into running pool instances (needs the private key in Railway env, and doesn't cover regions with nothing running); shipping the code in cloud-init user_data itself (too big — Lambda's user_data is KB-scale; a 170 KiB tarball isn't).

**Consequences:** rollout = deploy; the next boot per region picks it up; already-running instances keep old code until reaped (force by terminating). A bare `railway up` without the deploy script ships no bundle (manifest 404 → instances boot whatever they hold) — use `npm run deploy`. Concurrent boots in one region serialise on the lock (15-min wait cap). `sync-fs.mts` stays as an escape hatch.

---

### 2026-09-13 — Posable 3D figure as a reference layer

**Context:** Artists pose a mannequin for anatomy/foreshortening reference. Donald asked for a person button that places a posable 3D armature on the canvas, on a layer flagged as *reference* — visible while drawing, never sent to the AI. Owner answers (2026-09-13): realistic rigged body mesh (not a procedural capsule dummy, not a stick figure); IK for end effectors, swing for mid joints, orbit on empty space, two-finger whole-body transform, modal Done/Cancel; excluded from the AI capture ONLY (exports/thumbnails/selection still see it); re-editable and non-paintable.

**Decision:** Bundle Quaternius "Universal Base Characters" (CC0, direct download, 14k tris, T-pose, UE5-mannequin joint names) as slim textureless GLBs (0.8/1.1 MB, male/female) rendered with one matte gray material; GLTFKit2 already builds `SCNSkinner`s from glTF skins with joint nodes named verbatim. The pose editor is a canvas-space overlay (`setInteractiveOverlay` slot in `RotatableCanvasContainer`) with an orthographic camera at document scale so joint projection is affine; all IK/swing math runs in world space on `simdWorldOrientation` (analytic two-bone IK with a per-chain pole for the straight case). Done bakes with `SCNRenderer` at 2048² into a `LayerInfo.isReference` layer carrying the pose JSON; only the AI capture path skips reference layers (`flattenedOpaqueCGImage(excludeReference:)`), and `refusesPainting` unifies the lock + reference refusal at every write site.

**Alternatives considered:** Mixamo X/Y-Bot — the ideal mannequin look but Adobe's FAQ forbids redistributing raw character files and download needs an Adobe login (rejected); Microsoft Rocketbox (MIT, clothed realistic avatars, FBX only, no neutral body — kept as an option); Quaternius Mannequin GLB via Poly Pizza (licence label mismatch CC-BY vs CC0 — skipped); SceneKit `SCNIKConstraint` (render-loop driven, harder to bake deterministically — own analytic solver instead); a live SceneKit "layer" composited above everything (breaks layer ordering; a baked raster layer + editable pose payload keeps the compositor untouched); keeping one loaded scene and cloning per figure (`SCNNode.clone` shares skinner bones — reload the 0.8 MB asset per session instead).

**Consequences:** New `ios/Kiki/Figure/` + `FigureController`; CanvasModule gains `isReference`/`referenceData` on layers (persisted, undo-carried — `.layer` undo entries now carry the payload so a re-pose is a single-layer undo), `addReferenceLayer` (inserts below the active paint layer, which stays active) / `setLayerImage` / `setLayerDisplaySuppressed` / `setInteractiveOverlay`, and a distinct `onReferenceLayerStrokeRefused` callback. Review pass (same day) extended the exclusion rule to every model-bound image (AI Edit source, Animate keyframes) while user-facing images keep figures; joint values are bind-relative deltas so the body swap doesn't distort; pose mode is gated against paste/Move floats + AI Edit preview and disables layer panel/undo while active; the container stands down all recognizers under the overlay; sign-out cancels the session; GLB assets are cached per body; the live SCNView renders change-driven, not continuously. Fixture replay now honors layer refusal (it used to paint on locked layers). The speed-paint recorder consumes the AI capture frames, so replays omit figures (acceptable; split the capture if that ever matters). Known v1 limit: the Edit Pose overlay draws above all layers regardless of the figure layer's depth. **Pose presets (same day):** Donald asked for default poses; Mixamo was ruled out again (redistribution + login), and the Quaternius Universal Animation Library (CC0, free itch download, `Unreal-Godot/UAL1_Standard.glb`) turned out to carry 43 clips on the *identical* 65-joint skeleton, so 38 poses were sampled from clip frames with a Blender script (`ios/scripts/figure-poses/`) into bind-relative deltas — the same encoding the app uses, so they transfer to both bodies despite per-joint rest-rotation differences of up to 17°. Thumbnails are rendered on device rather than shipped as assets. Second review pass: the pose-mode modal gate is now two-directional (Paste / object insert / AI Edit / selection Move refuse while posing), cutouts exclude reference layers (Pin-as-reference leak), handles are zoom-compensated, hidden layers can't be pose-edited, an empty joints map is honoured as a real (T-)pose, Done keeps the session on recoverable failures, and the body preference is only persisted from a live picker change. **Chrome redesign (same day, Donald: "it looks like a prototype… poses visible… panel on the left… we don't need the drawing UI"):** pose mode now replaces the drawing chrome entirely — `FigurePoseTopBar` (Cancel / Place) + a 300 pt left `FigurePosePanel` (Body, View row with canonical yaws, always-visible scrollable pose grid, Reset) with the canvas shrunk to the remaining width; the bottom bar + Poses popover were removed. Library grown to 75 poses the same day (denser frame sampling of the same clips); Donald preferred a **Mirror button** over baked mirrored variants, so mirroring is done in-app (`FigurePose.mirrored`, exact on this rig — verified numerically, double-mirror is the identity) and the 17 `(L)` presets were dropped. **Body types = proportion morphs (same day):** Donald wanted children and stylized bodies; the Quaternius Source pack's six bodies barely differ, other rigged sources are on different skeletons (each would need a joint map + pose retarget), so body types are per-bone scale morphs of the existing rig with child-compensating nodes (no shear when bending, IK exact). Presets Adult/Teen/Child/Toddler/Chibi/Fashion/Heavy/Slim + six sliders; sim-verified: all presets render cleanly, poses/Mirror unchanged, proportions persist through Place → Edit Pose. Quality is "posing dummy" (adult musculature scaled), not sculpted anatomy — a real child mesh on this skeleton would still be an upgrade if one ever turns up. Joint limits, limb twist, and depth (z) placement of a joint are not controllable in v1 — orbit the figure to pose in depth. Sim-verified 2026-09-13: default stance, IK/swing drags, bake, layer badge, capture exclusion (dumpCapture), persistence across relaunch, Edit Pose restore, body swap, Cancel.

---

### 2026-09-12 — Mid-session fal → H100 upgrade

**Context:** Under `IMAGE_PROVIDER=auto` a drawing session resolves its provider once, at WS open: H100 pool if it has an assignable instance, else fal. The downgrade direction existed (an auto lambda session whose instance dies swaps to fal in place), but not the reverse — a session that opened during a pool boot stayed on fal for its whole life. 30-day `stream.provider_session` readback: 10 of 35 fal-served auto sessions closed with `pool_status_at_close='ready'` and never switched, i.e. users sat on the fallback while a paid-for H100 idled.

**Decision:** `routes/stream.ts` `maybeUpgradeToLambda`, run on the existing 15 s availability tick (the same tick that samples `h100_ready_after_ms`). Eligibility mirrors the downgrade exactly: only `providerResolvedFromAuto` sessions currently on fal; explicit `?imageProvider=fal|lambda` overrides never switch (A/B purity). Sequence: acquire a pool slot → open a lambda `StreamRelay` while the fal relay keeps serving every canvas JPEG (no `connecting` state, nothing blanked) → once connected, flush the fal open-span into `monthly_usage`, hand the metering flag to the lambda per-frame path, adopt the lambda relay (lastConfig resent first), then close the fal relay. A failed wire marks the instance suspect, releases the slot, stays on fal silently and retries no sooner than 60 s later. To make this safe the wiring was split into `openRelay(provider, url)` (build + connect, provider explicit) and `adoptRelay`, the relay message handler is bound to its own provider and drops events from any non-adopted relay, and fal metering is bound to the relay instance it was set up on. Telemetry: `relay_upgrade_start` / `relay_upgraded` / `relay_upgrade_failed` Pino events; `stream.provider_session` gains `lambda_upgraded` + `upgraded_after_ms`, and `provider` is the final provider.

**Alternatives considered:** Rewiring through the existing `wireRelay` (rejected — it closes the live relay before connecting, which is a visible gap and a blank-pane risk); a dedicated poll timer (rejected — the 15 s tick already exists and its granularity is fine); upgrading on the next stroke instead of a timer (rejected — the connect would sit in the stroke's critical path).

**Consequences:** An auto session lands on the H100 within ~15 s + connect time of the pool reporting ready, so `pool_status_at_close='ready'` on a fal session now means the wire failed / was backing off / the client left inside the tick, not "auto never upgrades" (the `poolStatusAtClose` doc comment says so). Sessions can bounce fal→lambda→fal→lambda if the pool flaps; `upgraded_after_ms` records the first swap. Insights dashboards (`analytics/src/routes/admin.ts`) do not yet read `lambda_upgraded` — follow-up. Route test: `backend/src/routes/stream.test.ts` (mock lambda image server, fake fal relay, fake pool; `streamTuning` is the exported test seam for the two cadences).

---

### 2026-09-12 — GPU hunt v2: capacity-aware sweep, cell circuit breaker, boot-relative hedges, no hunt cliff, two more regions

**Context (measured, Insights data — 14 d of 2-min advertised-capacity samples, 30 d of `lambda_pool_events`):** our 3-region H100 grid had capacity in only 68% of ticks vs 90% for "any 1x H100 in any Lambda region"; the H100 PCIe cell in us-west-3 was the single most available H100 anywhere (77%) and PCIe never once appeared in our own regions; us-south-3 SXM added 37%. Droughts in our grid ran to 5.5 h. Hunts walked dry cells at the 13 s launch spacing (image search p90 3.8 min) while an open cell sat further down the static type-major list. Boot p50 for the same H100 SKU: 2.5 min in us-southeast-1 vs 15.8 min in us-south-2; A100 in us-east-1 10.4 min. The flat 8-min hedge trigger fired just before normal ~10-min boots finished: hedges won 2 of 15 races. The 15-min hunt window ended 7 video hunts while users still waited. And two consecutive dead-on-arrival VMs came from the same cell within 40 min.

**Decision:**
- **Regions:** `LAMBDA_REGIONS` = us-southeast-1, us-south-2, us-east-1, **us-west-3, us-south-3** (both pools; `kiki-image-*` + `kiki-video-*` filesystems populated 2026-09-12). `gpu_1x_a100` (PCIe A100) dropped from `LAMBDA_INSTANCE_TYPES` — never advertised anywhere in 14 d.
- **Capacity-aware sweep (`planSweep`)**: every pass re-orders the grid — cells the capacity monitor saw advertised in the last 10 min first (type preference kept: an advertised A100 still ranks below an advertised H100; within a type, fastest measured boot p50 first), then non-advertised cells in static order, then penalized cells, then (for a hedge) the cell it is racing. Nothing is skipped — Lambda's flag is shallow, the launch call stays the authority. `capacityMonitor.latest()` exposes the in-memory snapshot; per-cell boot p50 comes from a 30-day join of `launched`/`ready` events, cached 10 min. `lambda_pool_sweep_plan` logs the order once per hunt.
- **Cell circuit breaker:** a `boot_load_error` or `boot_stalled` demotes that cell for 45 min (`cell_penalized` event + log). Demoted, never removed.
- **Hedge trigger:** per instance, `max(hedgeAfterMs, 1.3 × cell boot p50)`; a hedge sweep avoids the original's cell. `hedge_resolved` is now a durable pool event with `winner=original|hedge` so Insights can show the win rate.
- **No hunt cliff:** the sweep continues while demand persists (interest window / active streams already bound it); the old window now only emits one `hunt_long` marker. A pass-boundary yield (`POLL_MS`) keeps a dry grid from starving timers.

**Alternatives considered:** skipping non-advertised cells outright (rejected: the flag is stale by seconds and has no depth — ordering gets the win without trusting it); ranking purely by boot time across types (rejected: A100 gen is ~2× slower per frame, quality tier stays first); a size floor for filesystem readiness (rejected earlier today — `bytes_used` lags by ages).

**Not changed (owner call, cost policy):** the 30-min idle reap / a peak-hours pool floor — 43 reaps in 30 d each followed by a 3–16 min re-hunt; a warm H100 8 h/day ≈ $1,030/mo.

**Setup-script fix (same day):** `setup-lambda*.ts` used to create the region filesystem up front and then sit in a capacity-retry loop for up to an hour — an empty, unattached filesystem, which the sweep guard reads as "populated" (the video plan in production listed us-south-3 while its setup was still waiting for an H100). `launchSetupWithFilesystem` (client.ts) now creates the filesystem only when the cell advertises capacity, immediately before the launch, and deletes it again on a miss (`DELETE /filesystems/{id}` verified). Residual: a setup run killed mid-populate leaves its box attached (safe) — terminate the box and the empty filesystem becomes a trap until re-run; delete it or re-run promptly.

**Consequences:** widening `LAMBDA_REGIONS` needs the region's filesystems populated first (the sweep skips missing/busy ones); Insights Capacity/Boots gained joint-availability, drought, per-cell boot and hedge-outcome views; mid-session fal→H100 upgrade landed the same day (separate entry).

---

### 2026-09-12 — Video pool sweeps the image pool's capacity grid

**Context:** App open showed image "Warming up" while video sat in "Finding a GPU…". Sentry `lambda_pool_launch_retry` rows: the image pool swept 3 regions × 4 types (Railway `LAMBDA_REGIONS`/`LAMBDA_INSTANCE_TYPES`) and won an A100 in us-east-1; the video pool had no env override, so `config` collapsed it to the single cell us-south-2 × H100 SXM5 — which Lambda had zero of at the time. Same shared `instancePool.ts` sweep loop, different inputs; the video pool's search was simply never widened when the image pool's was (2026-07-25 multi-region sweep).

**Decision:** One search strategy for both pools. `LAMBDA_VIDEO_REGIONS` defaults to `LAMBDA_REGIONS`; `LAMBDA_VIDEO_INSTANCE_TYPES` defaults to `LAMBDA_INSTANCE_TYPES` filtered to the 80 GB single-GPU SKUs (`gpu_1x_h100_sxm5`, `gpu_1x_h100_pcie`) because LTX-2.5 + Gemma ≈ 48 GiB resident can't fit the image pool's 40 GB A100 fallbacks. Explicit video env vars are still honored verbatim. `instancePool` now pre-filters the region list to regions whose `spec.fsName(region)` filesystem exists AND has no foreign (non-pool-prefix) instance attached (`lambda_pool_region_no_fs` / `lambda_pool_region_fs_busy` warns; listing failure = sweep everything) — a region with no filesystem fails the launch non-retryably and would have ended the whole sweep, and an existing-but-empty one is worse: `setup-lambda-video.ts` creates the filesystem at the start of a 20-40 min populate, and the first deploy of this change (existence-only check) launched a video H100 into the half-filled `kiki-video-us-southeast-1` within 60 s — its server came up with `load_error` (transformer weights not downloaded yet) and would have sat "booting" until the 25-min timeout. The setup/sync scripts hold their own instance on the filesystem for the whole populate, so "someone else is attached" is the exact signal. Tried and rejected: a `bytes_used` floor — Lambda's API reported 0 GB for a filesystem with 68 GB on disk (lag of at least several minutes, likely much longer), which would have blocked a ready region instead. `kiki-video-us-southeast-1` + `kiki-video-us-east-1` populated via `setup-lambda-video.ts` so the video pool actually has three regions to hunt in. `LAMBDA_VIDEO_REGION` (singular) removed — unused.

**Alternatives considered:** Set `LAMBDA_VIDEO_REGIONS`/`_INSTANCE_TYPES` on Railway by hand to mirror the image vars — drifts again the next time the image list changes; the owner's ask was consistency, and the Insights Boots/Fleet analytics compare the two pools' hunts, which only means something if they search the same grid.

**Also shipped (found while verifying):** the pool now fails fast on a terminal server load error. The first launch into the populated `kiki-video-us-southeast-1` landed on a Lambda H100 SXM VM whose GPU the host had never fabric-initialized (`cudaGetDeviceCount` → CUDA error 802 "system not yet initialized"; `nvidia-fabricmanager` can't run in the pass-through guest — "no NVSwitch"; `nvidia-smi` works, `torch.cuda.is_available()` is False). torch fell back to CPU: the 3-shape warmup crawled for 12 min, then died in the audio vocoder (`Input type (float) and bias type (c10::BFloat16)` — the CUDA branch relies on `torch.autocast(cuda, float32)`, which is a no-op on CPU). The video server keeps FastAPI alive and reports `/health {status:'error', load_error}`; `watchBoot` used to ignore that and hold the VM until the 25-min boot timeout. Now `status:'error'` terminates + replaces immediately (`lambda_pool_boot_load_error` log + `boot_load_error` pool event carrying the last traceback line). Per-VM luck, like the provisioning lottery — a fresh draw is the fix. (The setup smoke test in the same region passed on a different VM in 82 s, which is how this was isolated to the VM.)

**CUDA preflight (2026-09-13 — the cheap fix for the dead-VM class):** the same load error recurred four times in a row on `gpu_1x_h100_sxm5@us-southeast-1` (identical message, identical ~11-min CPU-crawl timing) while the same code booted fine in us-south-2 and us-west-3. Both servers now run `shared/cuda_preflight.check_cuda()` BEFORE loading any weights (`torch.cuda.is_available` + context init + a real 1-element kernel, 3 tries 10 s apart — a fresh VM's GPU can lag a few seconds, the broken case persists for 25+ min); failure short-circuits to `/health {status:'error', load_error:'cuda_preflight_failed … | nvidia-smi: …'}` so the pool's fail-fast fires in seconds instead of after the crawl. The image server gained the same `status:'error'` health path (it used to crash out and sit as 'loading' until the boot timeout). Verified: preflight passes on a live us-south-2 H100; the failure sequence is exactly what raised error 802 on 2026-09-12's bad VM. Rolled onto all ten region filesystems with `sync-fs.mts` — running instances keep the old code until reaped. Owner declined periodic spin-up probes for now (≈$160/mo at 4-hourly light probes); the escalating persistent cell penalty is still open.

**Consequences:** Adding a region to `LAMBDA_REGIONS` now widens BOTH pools; the video pool only benefits once `setup-lambda-video.ts --region <r>` has run (until then the region is skipped with a log, not an error). Video-capable SKU list lives in `config/index.ts` (`VIDEO_CAPABLE_INSTANCE_TYPES`).

---

### 2026-09-10 — One drawing layout; drawing-engine review fixes
**Context:** A two-round review of the Metal drawing engine (4 + 3 reviewer passes) found the three-layout switch (split-screen / fullscreen / overlay) multiplying code paths for modes nobody used, plus a set of correctness and memory defects (undo-to-blank never persisted; paste-only drawings deleted on exit; leaving mid-Move persisting a cut-out layer; selection state leaking across drawings; O(n²) per-stroke stamp regen; ~1 GB worst-case undo; autosave/capture stalls on the main thread; walk constants in view points).
**Decision:** Kiki has exactly ONE drawing layout: the canvas fills the pane and the generated image floats as `FloatingResultPanel`. Split-screen and overlay are deleted (not flagged). Stroke walks are stateful/incremental (`DryStrokeWalker`, `EraserStrokeWalker`, `WetStrokeWalker`) with document-pixel constants (`StrokeWalkUnits`, old view-point literals × 2 to preserve the 12.9" reference feel); finalization reuses the same walker so preview == committed (offline-asserted). Undo snapshots are LZ4-compressed off-main under a 256 MB budget with memory-warning eviction, and record the stroke count per entry. Saves settle floating content first; autosave encodes only changed layers, off-main; the app saves on background.
**Alternatives considered:** Keeping overlay behind a flag (rejected — "doesn't work well enough yet" and it's the branch that multiplied every canvas path); keeping view-point walk constants (rejected — feel differed per iPad size and the harness could not reproduce device strokes); bbox-cropped undo snapshots (deferred — LZ4 + budget covers the sketch case; dense photo layers fall back to the budget).
**Consequences:** `AppCoordinator.drawingLayout`, Settings → Display, `ResultView`/`PromptTitleBar`/"Send to Canvas", the overlay stroke surface and `setLassoPreviewHost` are gone; SAM always segments the sketch; `ResultState.provisioning/.error/.idleTimeout` have no dedicated visual (they only rendered inside the split pane) — status dot + banners remain. Two test mains (`OfflineTests/main.swift`, `OfflineTests/walkers/main.swift`) plus the harness are the regression net. On-device feel of Fall Off / Charge / Speed-driven brushes shifts by ≈ 2.16/2 (≈8%) on the 12.9" iPad and by more on other sizes (now consistent across sizes). Shaped-tip vertical mirroring and linear-light blend modes are documented conventions, not changed.

---

### 2026-09-13 — Video: 1024² output, quality-first decoder policy (owner: "do whatever gives higher quality")

**Context:** With the speed pass making DFR 768² clips 5.8–8.4 s, the owner asked for the highest single-H100 quality instead: higher resolution, the best decoder that fits, distilled (DFR) stays — no interest in the full "dev" transformer path, no interest in audio.

**Measured (1x H100 SXM, DFR 1024², FP8-cast, torch.compile, FA3, steady state after warming all presets):**

| Preset | Decoder | Total | denoise / decode | Peak GiB |
|---|---|---|---|---|
| 2 s (49 f) | DiffVAE keyframe-anchored | 11.9 s | 4.8 / 7.2 | 66.8 |
| 4 s (97 f) | DiffVAE keyframe-anchored | 29.6 s | 7.7 / 21.9 | 68.5 |
| 4 s (97 f) | DiffVAE plain (natten) | 21.6 s | 7.7 / 13.9 | 68.5 |
| 6 s (145 f) | DiffVAE keyframe-anchored | does not fit (decode tile budget) | — | — |
| 6 s (145 f) | DiffVAE plain (natten) | 43.9 s | 12.2 / 31.7 | 70.5 |
| 6 s (145 f) | conv VAE | 14.9 s | 12.2 / 2.7 | 71.2 |

**Decision:** Defaults are now `LTX_WIDTH/HEIGHT=1024`, `LTX_VIDEO_VAE=diff`, and a per-request decoder policy in `video/pipeline.py`: the keyframe-anchored DiffVAE up to `LTX_DIFFVAE_KEYFRAME_MAX_FRAMES=97`, and `LTX_FALLBACK_DECODE=plain` (the same DiffVAE without anchoring, natten path) above it. Three decoders stay resident (keyframe, plain proxy, conv — the conv VAE costs 1.35 GB) and are swapped under the pipeline lock per request; warmup runs every preset so both decode paths are compiled/autotuned at boot (boot is now ~6 min on a warm filesystem: 145 f warmup alone ~90–200 s). Through the real server (`video.server`, all presets twice, no recompiles): **14 s / 33 s / 50 s** generation for 2 s / 4 s / 6 s (the 6 s decode ran 37 s in-server vs 32 s in the bench). The fast profile is one env away: `LTX_FALLBACK_DECODE=conv` gives 15 s for 6 s clips; `LTX_VIDEO_VAE=conv` gives the 2026-09-12 speeds at 1024² (≈6 / 9.4 / 15 s).

**Alternatives considered:** Cosmos 3 Super (top open-weight i2v, but 64B BF16-only → 4–8 H100s), MAGI-2 (8 Hopper GPUs), MiniMax H3 (license excludes US deployment), the LTX "dev" transformer with guided sampling (owner declined; arena Pro < Fast anyway).

**Consequences:** iOS `expectedWaitSeconds` for LTX = 18 / 38 / 55. Bench-box gotcha recorded: a Lambda H100 SXM can come up with the NVSwitch fabric stuck "In Progress" (fabric manager fails, CUDA error 802 "system not yet initialized"); torch then silently runs on CPU and the DiffVAE budget reads `usable_bytes=0`. The bench driver now gates on a real CUDA allocation; the pool's health probes would have struck such a box anyway.

---

### 2026-09-12 — Video speed pass: torch.compile + conv VAE decoder (DFR 768² clips 2.2–2.6× faster)

**Context:** After the LTX-2.5 upgrade, a 4 s / 6 s Animate clip took 12.8 s / 21.5 s of H100 time at DFR 768². Owner ask: make our own-H100 generation faster, $20 budget. Public numbers (decisions 2026-09-10 discussion) put us at eager-baseline speed; Lightricks' own docs list four levers: FlashAttention 3, `torch.compile`, natten for the DiffVAE decoder, and the DiffVAE decode preset.

**Measured (2× H100 SXM bench box `kiki-vidbench-*`, DFR 768², FP8-cast, steady state, same seed/prompt/keyframe; `model-servers/dev/bench_ltx25.py`):**

| Config | 4 s (97 f) total | denoise / decode | 6 s (145 f) total | denoise / decode | Peak GiB |
|---|---|---|---|---|---|
| baseline (eager, SDPA, DiffVAE keyframe decode) | 12.8 | 6.4 / 6.4 | 21.5 | 9.2 / 12.4 | 68.7 |
| + FlashAttention 3 | 12.7 | 6.2 / 6.4 | 20.9 | 8.7 / 12.2 | 68.7 |
| + torch.compile (transformer) | 11.2 | 4.8 / 6.4 | 20.7 | 6.9 / 13.7 | 68.0 |
| + compile, DiffVAE **plain** decode + natten (chunked_eager) | 9.3 | 4.8 / 4.5 | 15.9 | 7.0 / 8.9 | 68.0 |
| + compile, DiffVAE plain decode, `combined_compile` + natten | crash | dynamo ConstraintViolation in the compiled DiffVAE | — | — | — |
| **+ compile, conv VAE decoder** | **5.8** | 4.8 / 1.0 | **8.4** | 6.9 / 1.5 | 68.0 |
| + compile, conv VAE, **1024²** | 9.4 | 7.7 / 1.7 | 15.2 | 12.3 / 2.9 | 70.5 |

Stage timeline (compile, 145 f): stage 1 (8 steps, 384²) 1.9 s → upsampler 0.35 s → stage 2 LoRA fuse + 3 steps at 768² 4.0 s → **keyframe DiffVAE decode 13.5 s (4 tiles × 3.4 s)**. Under DFR the final decode is keyframe-anchored, which upstream runs eager and uncompiled regardless of `LTX_DIFFVAE_MODE`, and natten does not apply to that path (their docs' mode×keyframes grid) — measured: natten + keyframe decode = no change.

**Decision:** Defaults are now `LTX_TORCH_COMPILE=1` and `LTX_VIDEO_VAE=conv` at DFR 768² → **5.8 s / 8.4 s** for the 4 s / 6 s presets (2 s preset ≈ 4 s). Warmup runs every Animate preset (`LTX_WARMUP_FRAMES=145,97,49`) so the compile and per-shape guards are paid at boot (+~100 s), never on a user's first clip. FA3 stays installed (free 3%). Quality check on the same latent: conv-decoded frames measure slightly sharper (gradient 1.32 vs 1.16) with ~12% more frame-to-frame change and visibly harder edge aliasing on panel seams; DiffVAE keyframe decode is smoother. Judged an acceptable trade for a 2.2–2.6× wait reduction; `LTX_VIDEO_VAE=diff` is the one-env rollback, and `diff` + `LTX_DFR_PLAIN_DECODE=1` (natten) is the middle option at 9.3 s / 15.9 s. 1024² conv (9.4 s / 15.2 s, 70.5 GiB peak) now fits the 6 s preset and is the knob if sharper output is wanted at roughly the old wait.

**Alternatives considered:** fp8_scaled_mm (needs an FP8 checkpoint with scales — none shipped); CUDA-graph compile modes (single-GPU needs block streaming = slower); caching the LoRA-fused detailing transformer in the registry (fuse is only ~0.25 s/call — not worth +VRAM); fewer sigmas (quality).

**Consequences:** `requirements-video.txt` now lists `flash_attn_3` and `natten` with their wheel indexes (installed into the live NFS venv 2026-09-12). Boot is ~100 s longer (compile at warmup). iOS `expectedWaitSeconds` for LTX drops to 8 / 10 / 13 s. The DiffVAE `combined_compile` + natten crash is upstream (dynamo dynamic-shape guard) — don't retry without a newer ltx pin. Bench-box lesson: a bash variable holding `ssh` options with spaces silently failed under zsh (`$SSH` treated as one word) — the first kickoff died and billed an idle hour; use `${=VAR}` or spell the command out.

---

### 2026-09-10 — Video: LTX-2.3 → LTX-2.5 (registry-resident official pipelines) + hosted fal engines toggle on the Animate screen

**Context:** Animate-screen output quality was poor. The self-hosted video model (LTX-2.3 22B distilled, integrated 2026-07-19) sits near the bottom of the current image-to-video field (Artificial Analysis i2v arena, 2026-09: LTX-2.3 Fast Elo 954 vs Wan 3.0 1176 / MiniMax H3 Max 1200 with audio; Wan 3.0 is #2 overall without audio at 1358). Lightricks released LTX-2.5 on 2026-08-11 (Elo 1044 Fast; their own artifact score 0.74 → 0.28 vs 2.3) — same license family, same `ltx-pipelines` package. The frontier models are hosted-only (Wan 3.0 has no open weights; MiniMax H3's weights exclude US deployment) and cost $0.08–0.10 per generated second, i.e. ~$1.20 per 12 s clip vs ~$0.05 for our own H100 — too expensive as the default, worth a side-by-side. Owner ask: "best quality possible while still self-hosted" + a per-request toggle to try fal's best model.

**Decision:**
1. **Upgrade the video server to LTX-2.5** (`model-servers/video/pipeline.py` rewritten as `Ltx25VideoPipeline`; `requirements-video.txt` pins LTX-2 monorepo `a95ab856` + transformers 5.14.1 for the Gemma 4 encoder; `setup-lambda-video.ts` populates the split per-component checkpoints). Two upstream changes made the port SIMPLER than 2.3's: (a) split checkpoints (`ModelPaths.from_split`) with the Gemma 4 12B text encoder **bundled** in the LTX repo (config + tokenizer embedded in the safetensors → no Google gate, fully offline); (b) **registry-backed residency**: `ModelRegistry(cache_weights=True, cache_models=True)` keeps every FP8-cast state dict ON THE GPU and re-attaches it to a cached shell with `load_state_dict(assign=True)` on each block build, so the official `pipeline(...)` call runs at steady-state speed after warmup (~48 GiB resident) and we no longer replicate `DistilledPipeline.__call__` to hold a transformer open. `alloc_trim_strategy=DEFER` skips the per-block sync + empty_cache. That also makes **DFR** (Diffusion Fidelity Rendering — same distilled transformer + generated keyframe slots + IC-LoRA spatial detailing pass, Lightricks' "production quality" path) a config switch (`LTX_PIPELINE=distilled|dfr`) instead of a second port. Keyframe conditioning (`--image PATH FRAME_IDX STRENGTH`, our `position → frame_idx` snap) is unchanged; `crf=0` is still passed so linework isn't re-compressed. FP8 is `fp8_cast` only: 2.5 ships no FP8 checkpoint, and `fp8_scaled_mm` needs one (the 2.3-era "random noise" mismatch).
2. **Hosted engines on the same wire contract**: `animate_request.engine` = `ltx` (default) | `wan3` (`alibaba/wan-3.0/image-to-video`, 720p, $0.10/s, start+end frame, audio toggle) | `h3max` (`minimax/h3-max/image-to-video`, 768P, $0.08/s list, start+end frame, always audio). `backend/src/modules/video/falAnimate.ts` runs fal's QUEUE API (submit → poll → download; cancel PUTs the job's cancel_url) and the route answers `video_started` → `video_complete_data` (no preview frames) so iOS parsing is engine-agnostic. Mid-video keyframes are dropped for hosted engines (only LTX conditions on arbitrary positions). Cost is metered **pass-through** (price/s × seconds) into `monthly_usage`; Insights `stream.video_generation` now carries `engine` + `cost_usd`. iOS: segmented **Engine** picker on the Animate screen (persisted; `AnimationClip.engine` records which engine made each clip and the caption shows it); hosted engines don't gate on the video pool's warm-up (`canGenerate` needs only the socket) and hide the warm-up box.
3. **The HF repos are auto-gated**: Lightricks/LTX-2.5 and the IC-LoRA repo require one click-through of the LTX-2.x Community License per HF account (403 on `.safetensors` = not accepted). Accepted for Donald's account 2026-09-10 (`POST https://huggingface.co/<repo>/ask-access` with the token — the `/api/...` form 404s).

**Alternatives considered:**
- Keep 2.3's hand-rolled persistent transformer (`stage.model_context()` + `stage.run(...)`) — `DiffusionStage.run` no longer exists in the 2.5 package; replicating `__call__` would have to be redone for DFR too. Registry residency is the supported path.
- `fp8_scaled_mm` (native Hopper FP8 matmul, ~10-30% faster) — needs an FP8 checkpoint with per-tensor scales; none published for 2.5.
- Self-hosting a frontier model instead — Wan 3.0: no weights; MiniMax H3: license excludes US/EU/UK/KR deployment.
- `natten` extra for the DiffVAE decoder — pinned to torch 2.13/cu132; our venv is torch 2.9.1 cu128. Triton fallback used instead.
- `LTX_OFFLOAD_MODE=cpu` block streaming — keeps GPU-resident weight slots (what CUDA-graph compile wants) but streams 44 GB per forward pass; only a debugging knob.

**Consequences:**
- Video venv + filesystem: re-populated `kiki-video-us-south-2` (2.3 assets left in place for rollback; ~66 GB added). Any region added later needs the gated-accept token.
- Boot: same prefetch + boot-decomposition telemetry; warmup is one full generation at the config shape (builds the registry caches + Triton kernels).
- The **Sound toggle** does not apply to H3 Max (always generates audio) — surfaced inline in the picker.
- Free tier: ~$10 buys ~25 six-second Wan clips vs ~200 LTX clips; the toggle exists to compare, not as the default.
- Measurements (H100 SXM, 2026-09-10 bench via `model-servers/dev/bench_ltx25.py`): see the "Measurements" addendum at the end of this entry.

**Measurements (H100 SXM, us-south-2, FP8-cast, DiffVAE decoder, real Kiki keyframes, steady state after warmup — `model-servers/dev/bench_ltx25.py`):**

| Pipeline | Size | Frames | Gen (s) | Peak VRAM (GiB) |
|---|---|---|---|---|
| distilled | 512² | 97 | 6.1 | 56.3 |
| distilled | 768² | 97 | 9.4 | 60.4 |
| distilled | 1024² | 97 | 16.0 | 61.2 |
| dfr | 512² | 97 | 7.1 | 65.9 |
| dfr | 768² | 97 | 12.9 | 67.3 |
| dfr | 1024² | 97 | 29.5 | 69.3 |
| dfr | 768² | 145 | 29.6 | 68.9 |
| dfr | 1024² | 145 | **fails** — DiffVAE keyframe-decode can't fit a tile under the memory budget | — |
| dfr | 1024², start+end | 49 | 17.0 | 67.5 |

- Serving-path steady state (through `video.server`, distilled 512² × 145 frames): **7.6 s** gen (vs 9.5 s on 2.3). Boot on a warm NFS: 252 s load (prefetch 84 s of 66 GB, warmup 163 s incl. first-time weight loads + Triton compiles), 52.7 GiB resident.
- **Pick: `LTX_PIPELINE=dfr` at 768²** — the production-quality path, 1.5× the old output size, and every duration preset fits with ~11 GiB headroom (2 s ≈ 7 s, 4 s ≈ 13 s, 6 s ≈ 30 s generation). 1024² DFR is visibly the sharpest but only safe for ≤97 frames; distilled 1024² (16 s) is the fallback if 6-second waits prove too long — flip via env on the serving instance's boot.sh, no code change.
- Per-request audio off (`enableAudio:false`): the official `__call__` always decodes the audio latent and downstream dereferences it — stubbing `pipe.audio_decoder` to `None` crashed (`'NoneType' object has no attribute 'waveform'`, caught by validate-animate phase 5 on 2026-09-10). The ~0.2 s decode now always runs; the track is just not muxed.
- Hosted engines, same spaceship keyframe, 720p/768P: **Wan 3.0 = 130 s** wall for a 4 s clip ($0.40, 960×960 @30 fps, audio, prompt expansion on); **MiniMax H3 Max = 6.7 s** wall for a 5 s clip ($0.40 list, 768×768 @24 fps, audio; fal rejects durations < 5 s). Both produced coherent, high-detail motion; H3 Max drifted the design more (added blue accents), Wan stayed truest to the keyframe.

---

### 2026-08-23 — Image boot: warm only serving shapes (ready 47s earlier) + prefer us-southeast-1

**Context:** With provisioning decomposed (2026-08-22 entry), the image stack's dominant owned cost was warmup: ~80s even with a warm NFS inductor cache. Dev-box A/B on an SE-1 H100 showed why: warmup ran THREE full 4-step generations — txt2img, 1-ref, 2-ref — each a distinct torch.compile shape family (~25-27s of Dynamo trace + guard replay apiece, cache hits included), and **serving only ever calls generate_reference** — the txt2img shape was pure waste.

**Decision:** (1) Warmup now runs ONLY the 1-ref serving shape on the critical path (`warmup_ref1_ms`); the 2-ref (pinned-object) shape warms in a **background thread post-ready** (`warmup_ref2_ms` + `ref2_warmed` on /health) — strictly no-worse for users: a first frame landing mid-bg-warmup queues on the pipeline lock exactly as long as it would have waited for the old blocking warmup. Measured (dev box, warm cache): ready 106.1s → **59.1s**; warmup on the ready path 80.5s → 34.7s. (2) **`LAMBDA_REGIONS=us-southeast-1,us-south-2,us-east-1`** (Railway) — SE-1 first: it advertises H100 capacity MORE often than us-south-2 (86% vs 76% of 2-min polls over 14d) and provisioned in seconds-to-2.5-min in every observation vs us-south-2's 2-14 min lottery. Video pool unchanged (its filesystem exists only in us-south-2).

**Alternatives considered / negative results (measured, don't re-try):** torch.compiler mega-cache (save/load_cache_artifacts): 183 MB blob, 4.7s load, warmup 32.5s → 30.1s — net ~zero, the residual is Dynamo tracing which artifact caching can't skip. Local-disk copy of the inductor cache: no better than NFS (the 80s was never NFS latency). **Gotcha for future sessions: compile-cache keys are app-PATH-sensitive** — running the same code from a copied directory recompiled from scratch (361s); always deploy to `$FS/kiki/app`, and expect a one-time full recompile if that path ever changes.

**Consequences:** Expected real-boot image stack ~85-95s (from 135-180s); typical total boot in SE-1 ~2.5-4 min. First pinned-object frame within ~35s of ready pays the 2-ref queue wait (rare; bounded). `warmup_inference_ms` now equals `warmup_ref1_ms` for dashboard continuity. New ops tool: `scripts/lambda/sync-fs.mts --region X` (cheapest-instance filesystem sync without a full setup-lambda run).

---

### 2026-08-22 — Pool boot-time attack: decomposed telemetry + hedged launches + video weight prefetch

**Context:** August pool boots degraded from ~5 min to 15-25 min (one video boot hit the 25-min stall timeout). The `ready` event's single opaque duration hid where the time went. Side-by-side autopsy of the two live 2026-08-22 instances (same region, same hour) proved the variance is **Lambda's VM provisioning** — capacity-granted → kernel-boot was 2.5 min (video) vs 14 min (image) while our stack was a consistent ~3 min on both; a probe instance measured 4 min. NFS was fast (1.3 GB/s prefetch) and the compile cache hit — the old "NFS/compile regression" hypotheses were wrong. Advertised H100 capacity in us-south-2 also sagged (100% of 2-min polls Aug 8-9 → 44-53% Aug 19-21), correlating with (not proven causing) slow provisioning.

**Decision:** Three-part response. (1) **Decomposed boot telemetry**: both servers report `booted_at_epoch_s` (kernel, from /proc/uptime) + `started_at_epoch_s` (process) + `phase_timings_ms` on /health; the pool records an `ip_assigned` event (IP shows ~23s after grant — a progress marker, NOT provisioning-done) and enriches the `ready` event's detail with JSON `{provision_s, os_s, stack_s, phases_ms}` — every future boot self-diagnoses. (2) **Hedged launch** (`instancePool.ts`, env `LAMBDA_POOL_HEDGE_AFTER_MS` / `LAMBDA_VIDEO_POOL_HEDGE_AFTER_MS`, default 8 min, 0=off): when nothing is ready and the oldest boot exceeds the threshold, launch ONE racing instance; first healthy wins, still-booting loser terminated (`hedge_launched`/`hedge_loser_terminate` events). Provisioning slowness is per-VM luck, so a fresh draw usually wins; a hedge may transiently exceed poolMax by one (deliberate — the video pool's max is 1). One pair at a time; a hedge whose partner resolves mid-capacity-sweep abandons the sweep. (3) **Video weight prefetch** (`video/pipeline.py`): paths resolve before the slow ltx imports, then ~50 GB (checkpoint + Gemma + upscaler) streams into page cache with 8 parallel readers overlapping the imports — the builds previously read at mmap speed (97.5 s transformer / 50 s Gemma). Diagnostic tools: `scripts/lambda/boot-probe.mts` (provisioning-time distribution), `scripts/lambda/validate-boot.mts` (cold-boot a server off a filesystem, print decomposition, terminate).

**Alternatives considered:** Fixing provisioning itself (impossible — Lambda-side); always-race-two launches (rejected — doubles capacity pressure in an already-flapping region for boots that are usually fine); longer idle window / always-warm floor (orthogonal cost-policy question, not taken here); trimming the image warmup's 2-ref compile shape (~40 s, deferred — small vs the provisioning term and risks a first-pin stall).

**Consequences:** Our-stack boot is now the minority term (~3 min); worst-case boots should collapse from 15-25 min toward ~(hedge threshold + 6 min). Insights hunt timeline recognizes `hedge_loser_terminate` as an end event. The `ready` p50/p90 in `lambda_pool_events` now measures Lambda's provisioning lottery plus a small constant — regressions in OUR stack show up in the detail JSON's `stack_s`, not the headline number.

**Context:** Owner decision: the 3s-idle auto-animation on the drawing page was "too confusing / shocking to users," and the Animate modal was too thin a surface for real control (prompt only, no keyframes, no history, no export).

**Decision:** A dedicated **Animate screen** (`AppScreen.animate`) replaces the entire in-drawing video UX. Entry: from a drawing (floating Animate button — result/canvas becomes the start keyframe) or from the gallery (≥1 drawing). The screen owns its own JWT-authed WS **`/v1/animate`** (`routes/animate.ts` + `modules/video/animateSession.ts` — on-demand `animate_request`/`animate_cancel`, no idle machinery); the drawing stream keeps only the `system_availability` push. The LTX server + pipeline accept **`keyframes[]`** (`{image_b64, position 0..1, strength}`, up to 4, positions snapped to the latent temporal grid via multi-image `ImageConditioningInput`) with `image_b64` back-compat, enabling start→end-frame morphs. iOS: `AnimateController` (own WS session, reconnect, generation state) + `AnimateView` (keyframe slots, motion prompt + example chips, 2s/4s/6s duration presets, streamed-frame progress preview, cancel) + SwiftData **`AnimationClip`** (every delivered MP4 saved with its inputs; history strip, replay, reuse-setup, ShareSheet export). Clips generated from a drawing also mirror into `RecordingStore` so the per-drawing "Animation (MP4)" share and speed-paint replay tail keep working. Removed: `VideoSession` (idle trigger) + `VIDEO_IDLE_TRIGGER_MS` + `{type:'animate'}` handling (legacy clients get a synthesized `video_cancelled(video_disabled)` so their button resets) + iOS `AnimateModalView`/`isAnimating`/result-pane video states. Metering moved to the animate route ($0.05/delivered video, same ledger). `resolveIdentity` extracted to `modules/auth/wsIdentity.ts` (shared by both WS routes); WS `maxPayload` raised to 64 MiB for keyframe uploads (client downscales to ≤1024px JPEG; 8 MB/keyframe server cap).

**Alternatives considered:** Keeping the idle auto-trigger behind a setting (rejected — owner explicitly killed the behavior); riding animate requests over the existing stream WS (rejected — the gallery entry point has no stream, and the screen's lifecycle is independent of drawing); keyframes at arbitrary mid positions in the UI (deferred — protocol supports up to 4, UI ships start+end).

**Consequences:** `validate-video.mts` → `validate-animate.mts` (single-keyframe, multi-keyframe, cancel-mid-flight). The video pool's interest signals are now animate-WS open + drawing-stream open. iOS gains a second SwiftData model (`AnimationClip`) in the container. `Drawing.animationPrompt` persists as the per-drawing motion-prompt prefill for the screen.

---

### 2026-07-18 — Video fleet gets production scaling via a shared pool factory (launch-blocking)

**Context:** The video POC ran one manually-launched static instance. Owner: production scaling is necessary for launch, and the image/video systems are near-identical in orchestration — "just the node being spun up is different."

**Decision:** Factor `devPool.ts`'s orchestration wholesale into `modules/lambda/instancePool.ts` — `createInstancePool(spec)` parameterized by fleet identity (name prefix, per-region filesystem, label) and scaling dials, with injectable Lambda client + health probe + timing dials (making the machinery unit-testable for the first time; 6 tests cover interest-launch, pressure scale-up, idle reap, 3-strike health kill, suspect marking, redeploy adoption). `devPool.ts` re-exports the image instantiation with an unchanged API and unchanged behavior; `videoPool.ts` instantiates the video fleet. **Video's load model drives deliberately slower scaling**: a video "stream" is a connected drawing session that fires one ~15-30s one-shot job per idle pause, so one instance serves more sessions (`LAMBDA_VIDEO_POOL_TARGET_STREAMS=8` vs image's 4) and the ceiling starts at `LAMBDA_VIDEO_POOL_MAX=1` — over-subscription degrades to late/cancelled videos (best-effort by design), never a broken drawing loop. Floor 0; interest = app-open (`/v1/dev/lambda/ensure` side-effect) + stream open; 30-min idle reap. `VideoSession` acquires slots lazily and re-acquires on each fire attempt, so sessions upgrade to video mid-session when the pool warms and fail over to a different instance after an upstream loss (with a synthesized `video_cancelled` so the iPad's Animate button resets). `lambda_pool_events` gained a `pool` column ('image'/'video'); the Insights image waterfall filters on it. Static `LAMBDA_VIDEO_URL` remains as a dev override; `launch-video.ts` instances are pool-adopted on deploy (setup instances renamed `kiki-vidsetup-*` so adoption can't grab one).

**Alternatives considered:** Copy-pasting devPool into a videoPool (rejected — two diverging copies of subtle, battle-tested orchestration); scaling on in-flight generation depth instead of connected sessions (rejected for now — same signal shape as the image pool is simpler, the session count bounds generation demand, and the dials compensate; revisit if trigger→complete latencies show queueing the session count doesn't predict); a fal-hosted video fallback (rejected — image-only IS the graceful fallback for a decorative feature).

**Consequences:** New env vars `LAMBDA_VIDEO_POOL_ENABLED` / `LAMBDA_VIDEO_REGION` / `LAMBDA_VIDEO_POOL_MIN|MAX|TARGET_STREAMS`. Fixed en route: an idle-timer early-fire race in `videoSession.ts` that could silently eat an idle period's video (timer fired ~1ms before the window elapsed, nothing re-armed it — caught by the new tests flaking, real production bug).

---

### 2026-07-18 — Video idle-state animation returns on a DEDICATED Lambda H100, triggered by a backend 3s-idle timer

**Context:** Owner asked to rebuild the video generation feature (removed with RunPod 2026-07-17, archived in `archive/video-ltx/`) on the new Lambda H100 infrastructure, as a proof of concept: image generation always has priority; a video of the user's drawing generates after 3 s of drawing inactivity.

**Decision:** (1) Video runs on its **own** H100 (`kiki-video-*` instances, `kiki-video-<region>` filesystem) — separate venv, separate weights, separate GPU. This is forced by memory (LTX 22B FP8 + Gemma ≈ 46 GiB resident vs the image server's ~37 GiB — they don't fit together on 80 GB) and independently desired for priority isolation: image latency cannot be affected by video work it never shares hardware with. The video fleet will scale much more slowly than the image fleet (one-shot ~15-30 s jobs, many users per instance). (2) The trigger moved from the RunPod-era pod-side `queueEmpty` signal to a **backend-side 3 s idle timer** (`VIDEO_IDLE_TRIGGER_MS`) armed on every incoming sketch frame — provider-agnostic (works over fal AND lambda image paths), animates the newest generated image, waits for the final in-flight generation when the timer beats it, fires once per idle period, cancels on drawing resume. (3) POC topology is one static instance behind `LAMBDA_VIDEO_URL` (env presence = feature gate); pool-ification and metering are deliberately deferred until the POC validates quality/latency.

**Alternatives considered:** Sharing the image-pool H100s under a priority scheduler (rejected — models don't co-fit in VRAM, and even with a smaller video model the tail-latency risk to the sacred drawing loop isn't worth it); keeping the `queueEmpty` trigger (rejected — only exists on our own image server, and 3 s-idle is the actual product semantic); building the pool manager now (rejected — POC first, the devPool pattern ports mechanically).

**Consequences:** New env vars `LAMBDA_VIDEO_URL` (+ optional `VIDEO_IDLE_TRIGGER_MS`); `model-servers/video/` is live code again (token-gated `/ws`, wss via the shared fleet cert — one `LAMBDA_TLS_CA_B64` pin covers both fleets); `model-servers/requirements-video.txt` defines the separate video venv; iOS needed zero changes (the `video_*` message contract is byte-identical). The archived RunPod serving code in `archive/video-ltx/video/` is now superseded by `model-servers/video/`; the archive's docs remain the deep reference. LTX-2 license caveat unchanged. Live H100 validation still pending (`documents/plans/lambda-video-provider.md` runbook).

---

### 2026-07-17 — Remove RunPod orchestration + PostHog; Kiki Insights is the analytics store

**Context:** The production image path moved to fal.ai on 2026-06-06 and the Lambda Cloud H100 path became the in-progress self-hosted alternative; the RunPod image path had been dormant for six weeks and the LTX video idle-state was off. PostHog had been fully shadowed by Kiki Insights (every event dual-written) since 2026-06. Owner asked for a cleanup pass: eliminate RunPod entirely, archive what a future Lambda video port needs, drop PostHog, keep Sentry.

**Decision:** Delete the pod-orchestration system wholesale — `modules/orchestrator/`, the Redis client + session registry + provision rate limiter, the `/v1/ops` cost endpoints, RunPod scripts/workflows, and the video relay path in `stream.ts`. `stream.ts` now serves exactly two providers (fal prod, lambda dev) and emits `connecting`/`ready` state transitions inline on the WS connection — no cross-connection broker, since with no pods there is no out-of-band lifecycle to fan out. Redis is gone entirely (it existed so pod sessions survived backend deploys; Postgres holds all remaining durable state). The LTX video serving code + design docs + perf investigations are archived in `archive/video-ltx/` with porting notes; iOS's video render path stays in place, inert. PostHog removed on both platforms; `Analytics.track` → InsightsSink only.

**Alternatives considered:** Keeping a thin Redis-backed state broker for the fal path (rejected — the broker only mattered when provisioning outlived a single connection); archiving the backend orchestrator too (rejected — it's RunPod-shaped GraphQL code; a Lambda video port will look like the lambda devPool instead, and git history retains it at `d9e3c43`); keeping the provision rate limiter (rejected — it gated pod provisions; fal abuse is bounded by the $10/mo spend cap).

**Consequences:** `IMAGE_PROVIDER` default changed `runpod`→`fal` (Railway already sets `fal` explicitly — no behavior change). `npm run deploy` is now plain `railway up` (no volume sync, no `.flux-app-version`/`.git-sha` stamping). Railway env vars RUNPOD_API_KEY, NETWORK_VOLUMES_BY_DC(_VIDEO), REDIS_URL (+ addon), VIDEO_POD_ENABLED, ONDEMAND_*, PREEMPTION_*, RECONCILE_*, POD_BOOT_*, COST_*, OPS_API_KEY, MAX_CONCURRENT_PROVISIONS, PUBLIC_KEY are unused and can be deleted; the 11 RunPod network volumes (~$49/mo) can be destroyed. iOS `state:'terminated'` handling never fires anymore (no idle reaper); signout no longer aborts server-side session state.

---

### 2026-07-13 — Retraction: `CGColorSpaceCreateDeviceRGB()` is NOT Display P3 on iOS

**Context:** A deep color-pipeline review flagged the two remaining `CGColorSpaceCreateDeviceRGB()` call sites (`EyedropperRing.sampleColor`, `DiskColorPicker.generateSBImage`) as bugs, based on the 2026-06-08 claim that DeviceRGB resolves to Display P3 on iPads. Double-checking that premise empirically overturned it.

**Decision:** Retract the claim. A standalone CG test binary (run on macOS AND in the iPad Pro 13-inch (M4) simulator's iOS 26.5 runtime) shows DeviceRGB bitmap contexts are **byte-identical sRGB pass-throughs** in both directions, while an explicit Display P3 context really converts (sRGB 255,0,0 → 234,51,35). The 2026-06-08 eyedropper drift was fully explained by the *other* fixes in `968a454` (CALayer.render capturing nothing, a Y-flip, the sRGB-vs-linearSRGB re-decode); the DeviceRGB→sRGB switch rode along as a no-op. Also verified: `UIGraphicsImageRendererFormat` defaults to `.standard` (sRGB) in the iOS-runtime simulator, and `.extended` is value-preserving for in-gamut sRGB — the "renderer defaults to P3" claim was likewise unsupported. Docs corrected (root + CanvasModule CLAUDE.md, `UIImage+PixelColor.swift` comment). Convention unchanged: still write explicit `CGColorSpace(name: CGColorSpace.sRGB)!` for intent-auditability; existing DeviceRGB call sites left as-is (behaviorally identical).

**Alternatives considered:** Leaving the docs alone (rejected — the false premise already produced two false-positive "bugs" in one review and would keep doing so). "Fixing" the DeviceRGB call sites anyway (rejected — a no-op code change implies a behavior change that doesn't exist).

**Consequences:** DeviceRGB call sites must not be cited as color-drift root causes. The one *untested* residue: how CoreAnimation composites a DeviceRGB-tagged image on a physical P3 panel (all measured CG paths treat it as sRGB; device compositing very likely the same but unverified). Lesson (per the debugging-rigor rules): the P3 attribution was bundled into a multi-fix commit and never isolated — when several fixes land together, attribute the symptom only to the ones you can isolate.

### 2026-06-08 — Canvas color pipeline: linear at every Metal boundary, sRGB only at image outputs

**Context:** A new eyedropper exposed that colors round-tripped through the canvas were wrong, and a long-standing "gallery thumbnails look darker + more saturated than drawn" bug had the same root. Diagnosis (4 parallel agents + manual adjudication) found **two opposite gamma bugs that had been cancelling each other**, plus the eyedropper's own read bug — so the canvas looked roughly right until the eyedropper made the full loop visible. Our initial intuition ("the texture is `_srgb`, so use sRGB everywhere"; "`brush.color` is the sRGB color I picked, so pack it straight in") was wrong on **both** the read and write sides.

**Decision:** Codify one model: a `.bgra8Unorm_srgb` texture makes **Metal hardware own the sRGB↔linear gamma at every texture boundary** (sampler decodes on read, render target encodes on store). So **texture-side ops must speak linear; standalone image/file outputs must speak sRGB.** Concretely fixed:
- `CanvasRenderer.textureToCIImage` read: `.colorSpace` sRGB → **linearSRGB** (was re-decoding → darkened every snapshot/thumbnail/**save**, compounding to black on each save/reopen).
- `MetalCanvasView.premultipliedColor` write: pack **`s2l(brush.color)`** (sRGB→linear) before the stamp, matching the wet brush (was double-encoding → strokes a shade too light).
- Eyedropper read path: sample a **Metal snapshot** (`opaqueImageSnapshot`) not `CALayer.render` (which captures nothing from a `CAMetalLayer`); sample in explicit **sRGB**; fix a Y-flip in the 1×1 readback. ~~not `CGColorSpaceCreateDeviceRGB()` (= Display P3 on iPads)~~ *(retracted — see 2026-07-13 entry: DeviceRGB is an sRGB pass-through on iOS; that part of this fix was a no-op)*.

**Alternatives considered:** Setting `CAMetalLayer.colorspace = sRGB` (Agent 2's lead theory) — **rejected**, the color-picker swatch already matched the canvas, proving the *display* was correct and the canvas was ground truth; the bugs were in the CPU read/write paths, not presentation. A double-`linearSRGB` "tidy story" blaming only the read path — rejected; the cumulative *lightening* after the read fix proved a second, paint-side bug existed.

**Consequences:** Pick→paint→eyedrop→repaint→save→reopen is now idempotent (no drift). **New strokes are slightly more saturated/correct than before** (they now match the picker exactly); **already-saved drawings keep their baked-in too-light values** (only new paint is corrected). Full rules + the explicit list of wrong intuitions: `ios/Packages/CanvasModule/CLAUDE.md` → "Color pipeline — the one correct mental model". Lesson: a lighten bug and a darken bug cancel until one side moves — always test the **full color round-trip**, never a single hop.

### 2026-06-06 — Auth gate made a real, fail-closed global gate

**Context:** `authPlugin` was a plain `FastifyPluginAsync` registered via `app.register`, so Fastify encapsulated its `preHandler` + `request.userId`/`authClaims` decorators to a child context that owned no routes — the "global auth gate" gated nothing. Every route self-authed (signout/usage/subscription → `verifyAccess`; stream → WS handshake; ops → `X-Ops-Key`), masking it, until `/v1/usage` + `/v1/subscription/verify` relied on `request.userId` and 401'd on valid tokens.

**Decision:** `installAuth(app)` (`backend/src/modules/auth/index.ts`) attaches the preHandler + decorators on the **root** app (global, not encapsulated). Fail-closed: every route requires a valid Bearer token by default; a route opts out with **`config: { public: true }`** declared at its own definition (Fastify v5 `request.routeOptions.config`). Exemptions live next to each route — no central path list to drift. Opted out: `/health`, `/debug-sentry`, `/v1/auth/apple`, `/v1/auth/refresh`, `/v1/app-store/notify` (JWS-auth), the `/v1/ops/*` routes (own `X-Ops-Key` preHandler still runs), and `/v1/stream` (WS self-auth, also url-guarded in the hook). `usage`/`subscription`/`signout` now read `request.userId`.

**Alternatives considered:** Delete the dead plugin + keep per-route self-auth (rejected — fail-OPEN: a future route leaks unless someone remembers to auth it). Central `PUBLIC_PATHS` allowlist (rejected — fails closed but rots silently, lives far from routes). Per-route `config` gives fail-closed + locality.

**Consequences:** A forgotten exemption fails closed (locks out, never leaks). No new deps (root `app.addHook` avoids `fastify-plugin`). Verified end-to-end locally via `app.inject` against a throwaway Postgres (public reachable unauthed; gated 200 with valid token / 401 without; ops skipped by JWT gate but still gated by `X-Ops-Key`) + prod smoke.

### 2026-06-06 — Apple StoreKit 2 subscription flow (Stage 3)

**Context:** Stages 1–2 (Postgres accounts + the $10/mo fal-spend cap) left a non-exempt user who hit the cap with no way out — `subscription_status` was permanently `'none'` because no purchase flow existed. Stage 3 builds the auto-renewable subscription so a capped user can subscribe and keep drawing.

**Decision:** One auto-renewable product `com.don.Kiki.pro.monthly` (~$4/mo → App Store tier $3.99, monthly only, no trial). **Verification uses Apple's official `@apple/app-store-server-library`** (not hand-rolled `jose` x5c logic — payment trust boundary). Two backend routes: JWT-authed `POST /v1/subscription/verify` (iOS posts a verified `Transaction.jwsRepresentation` on purchase, on each launch for `currentEntitlements`, and for Restore) and a public `POST /v1/app-store/notify` (App Store Server Notifications V2; the JWS signature is the auth). **No P8 key / App Store Server API** — we only *verify* signed payloads, which needs only the committed Apple Root CA - G3 (embedded base64 in `modules/appstore/verifier.ts`). Subscription state is **derived from the transaction** — one `applyTransaction(userId, tx)` sets `active` iff `revocationDate==null && expiresDate>now`, replacing a per-notificationType mapping table (more robust as Apple adds types). Ordering/dedup via a `subscription_last_signed_ms` monotonic guard (apply only if incoming `signedDate >= stored`). `original_transaction_id` (partial-unique) binds a sub to one Kiki user so the unauthenticated webhook can resolve it. The fal-cap exemption gained an **expiry check** (`subscription_status='active' AND subscription_expires_at > now()`) so a missed webhook self-heals. iOS: `App/SubscriptionManager.swift` (StoreKit 2, app-lifetime `Transaction.updates` listener) + `Views/PaywallView.swift` (presented as a `fullScreenCover` on the existing `free_limit_reached` error path, now threaded with a machine-readable `code` on `ServerStatus`). `.storekit` test config at `ios/Kiki.storekit`. **No iOS entitlements change** — In-App Purchase needs none (unlike Sign in with Apple).

**Alternatives considered:** Hand-rolled JWS x5c verification with `jose` + `node:crypto` (rejected — re-implements the cert-chain trust logic most likely to be subtly wrong on a payment boundary). Client-verify only / no webhook (rejected — cancellations would only reflect on the client's next launch). A per-notificationType action table (rejected — the derive-from-transaction formula is equivalent and drift-proof). A separate `subscriptions` table (rejected — over-engineering for one product / one sub per user at launch scale; columns on `users` suffice).

**Consequences:** Schema gained `users.original_transaction_id` (partial-unique) + `users.subscription_last_signed_ms` (both idempotent `ALTER … ADD COLUMN IF NOT EXISTS`). New backend dep `@apple/app-store-server-library`. New optional env `APPLE_APP_APPLE_ID` (numeric App Store app id) — **required before *production* StoreKit verification works**; Sandbox/TestFlight verifies without it (the production verifier stays null and rejects prod payloads with a clear error until set). In non-production, XCODE/LOCAL_TESTING StoreKit environments verify (signature-skipped, per Apple's lib) so a local `.storekit` simulator purchase exercises the full backend path; production rejects those environments. Donald-side before live: create the App Store Connect product, set the V2 notification URL (Sandbox + Production) to `/v1/app-store/notify`, and select the `.storekit` config in the Run scheme for simulator testing. Verified: backend integration test against local Postgres (purchase→active, duplicate idempotent, stale-order rejected, renewal advances, refund→expired, expiry self-heal, OTID unique) + iOS build succeeds.

**Follow-up (same day) — in-app usage meter:** a tappable bar on the Gallery + Drawing screens that fills toward the $10 cap and opens the paywall on tap. Backend `GET /v1/usage` (`routes/usage.ts`) + a live `{type:'usage',spendUsd,capUsd}` WS push from the `routes/stream.ts` metering tick (~10s) so it ticks up while drawing; iOS `Views/UsageMeterView.swift` + `AppCoordinator` usage state (`refreshUsage()` on screen appear / after stop; `StreamSession.onUsageUpdate` for the live push). Hidden for exempt users (test accounts / active subscribers).

### 2026-06-06 — Postgres durable accounts + per-user monthly fal-spend cap

**Context:** Approaching launch, identity/subscription state needed a durable system-of-record (Redis is ephemeral), and an unsubscribed user had no cost ceiling on the now-fal image path. Done in two stages.

**Decision (Stage 1 — Postgres + accounts):** Added a managed Postgres (Railway addon → `DATABASE_URL`), raw `pg` + idempotent `schema.sql` + `migrate.ts` run at boot, mirroring the `analytics/` service. New `users` table (`user_id` UUID PK, `apple_sub` UNIQUE, `email`, `is_test_account`, `subscription_status`, `subscription_expires_at`) is the durable account record. `routes/auth.ts` `upsertUserByAppleSub` (atomic `ON CONFLICT (apple_sub)`) + `getUserEmail` now hit Postgres; the Redis `user:`/`apple-sub:` keys are retired. Code: `backend/src/postgres/` (client/schema/migrate/users). Sign-in requests Apple's `.email` scope (`SignInView.swift`) so the email is captured (first-auth only; private-relay possible).

**Decision (Stage 2 — fal-spend cap):** Unsubscribed users get `FREE_TIER_FAL_USD` ($10) of fal drawing spend per calendar month (UTC); test accounts (`is_test_account`) + active subscribers are exempt. Hard mid-session stop on crossing (~$0.20 overshoot tolerance). Spend metered PG-direct into `monthly_usage` (PK `user_id,month`) via atomic `INSERT … ON CONFLICT … RETURNING` — no Redis. `falImageRelay.cumulativeOpenMs()` + an `onUsage` hook (on close + ~10s throttle, no timer) report open-time; `routes/stream.ts` runs a per-connection `checkFalBudget` gate (incl. reconnects, so a 2nd device can't bypass) and a mid-session `enforceCut` (sends `{code:'free_limit_reached'}`, `abortSession` so reconnect re-denies, then closes). Fail-open if the budget DB errors (gate + mid-session). New `backend/src/modules/falBudget/`; the dead in-memory `entitlement` module + `FREE_TIER_SECONDS` removed. Backend-only — the existing failure UI shows the message. **Apple StoreKit/purchase + paywall UI + usage meter deferred** (testers stay unlimited via the test flag until then).

**Consequences:** Postgres is now a required dependency (backend fail-fasts without `DATABASE_URL`). Test/owner accounts are flagged via `UPDATE users SET is_test_account=true`. Tune/disable the cap via `FREE_TIER_FAL_USD` (0 ≈ off). Verified in prod: mid-session cut, gate-deny-on-reconnect, owner-exempt, spend recorded.

**Follow-up (same day):** with Postgres now available, moved **refresh-token revocation** from an in-memory Set (which reset every deploy → silently un-revoked tokens, a replay window up to the 30d refresh TTL) to a durable `revoked_refresh_tokens` table (`backend/src/modules/auth/jwt.ts`). Only the refresh endpoint hits the DB; the hot `verifyAccess` path stays pure-crypto. A doc sweep updated `.env.example` (added `DATABASE_URL`/`FAL_KEY`/`IMAGE_PROVIDER`/`FREE_TIER_FAL_USD`/`FAL_IDLE_CLOSE_MS`), `CLAUDE.md` (accounts/billing section), `README.md`, the WS1/5/8 + scale-to-100 plan banners, and the SignInView caption (removed a false "1 free hour, then $5/month").

### 2026-06-06 — Live image path moved from RunPod FLUX.2-klein to fal.ai hosted realtime

**Context:** The live img2img path ran FLUX.2-klein-4B (NVFP4, reference-mode VAE-concat) on per-session RunPod RTX 5090 spot pods — ~96s cold start (p95 ~157s), recurring spot-capacity fragility across DCs, and full ownership of the serving stack. A spike (`fal-spike/`) measured fal.ai's hosted `fal-ai/flux-2/klein/realtime`: ~1.5s to first frame, ~250ms/frame at 3 steps, 0% drop at 2 FPS, no pod provisioning.

**Decision:** Default the live image path to fal via `IMAGE_PROVIDER=fal` (set on Railway). The backend relays each canvas JPEG over a per-session fal realtime WebSocket — msgpack frames, server-side `Authorization: Key $FAL_KEY` (no secret on the client) — in `backend/src/modules/fal/falImageRelay.ts`, a drop-in for the RunPod `StreamRelay`. fal emits no `queueEmpty`, so the relay synthesizes a `frame_meta{queueEmpty}` (mirroring `model-servers/image/server.py`) to keep the video idle-state trigger working unchanged.

**Alternatives considered:** Deploy our own klein pipeline on fal Serverless (blocked on serverless access; more ops). Stay on RunPod (cold start + capacity). Direct iPad→fal (breaks the backend-computed video trigger and "no secrets on client" — needs the relay anyway).

**Consequences:**
- RunPod image pods (5090, klein NVFP4) are **DORMANT but intact** — config default is `IMAGE_PROVIDER=runpod`, so flipping the Railway var (or unsetting it) reverts instantly. Not deleted.
- **VIDEO idle-state animation (LTX-2.3 on RunPod H100 SXM) is UNCHANGED** — still RunPod. The orchestrator / provisioner / reaper / cost-monitor now serve video (+ the dormant image fallback) only; they are NOT on the live image path.
- fal's conditioning is its img2img feedback loop (`output_feedback_strength` / `schedule_mu`), not our reference-mode VAE-concat — different look, tuned via params (optionally surfaced in the iPad SettingsPanel).
- **Billing is by connection DURATION** (`ceil(open_seconds) × $0.00194`, ~2s floor, no fixed 30s minimum), charged per connection-open. Two cost levers shipped (commit f6f89793): **lazy-connect** (no socket until the first stroke → opening a drawing without drawing costs $0) and **`FAL_IDLE_CLOSE_MS`** (close the WS N ms after the last frame; reopen lazily on the next stroke). Measured billing details in `documents/references/provider-config.md`.
- NSFW *output* filter requirement dropped (see `content-safety.md`); prompt *input* filter still gates external TestFlight.

### 2026-05-09 — Removed `too_many_active_pods` quota check; surface raw deny reasons to iOS

**Context:** During heavy iteration (Xcode rebuilds in tight succession), backend started rejecting WS connections with `too_many_active_pods` and the iOS toast read "Unable to connect. Please restart the app." with no indication of the actual cause. Two problems compounded:
1. `rateLimiter.checkProvisionQuota` had a binary "any active session exists" guard before the hourly/daily windows. It read the same Redis row that `hasReadySession` had just consulted at `routes/stream.ts:348`, but ms apart and after one synchronous `checkEntitlement` call. Concurrent WS handlers (or a previous provision from the same user mid-flight) could race past `hasReadySession=false` and then see the row in `getActiveSessionCount` — false-positive `too_many_active_pods`.
2. iOS's `StreamWebSocketClient.connect()` swallowed `{type:"error"}` JSON arriving during the WS handshake — wrapped the full text in a generic `URLError`, and after the reconnect loop exhausted, fell back to a hardcoded "Unable to connect. Please restart the app." string that discarded the server's `message` field. Backend's entitlement and quota paths additionally fabricated UX-friendly strings ("Subscription required to continue", "Too many sessions — try again shortly"), so even the wire-level message was a friendly placeholder rather than the raw enum reason.

**Decision:**
- Deleted the active-pod check (`getActiveSessionCount`, `MAX_ACTIVE_PODS_PER_USER`, `'too_many_active_pods'` reason) from `backend/src/modules/auth/rateLimiter.ts`. Hourly (20/h) + daily (100/d) sliding windows unchanged. Concurrent-pod protection was always redundant: `getOrProvisionPod` already serializes via `inFlightProvisions` and reuses existing rows via `getReusableFromRow`.
- Backend now sends the raw enum reason as the `message` field for both entitlement (`message: entitlement.reason`) and quota (`message: quota.reason ?? 'rate_limited'`) denies. Auth deny was already raw.
- iOS gained `ServerRejectedError` (public, in `NetworkModule`). `StreamWebSocketClient.connect()` now decodes the initial WS message as `ServerStatus` and throws `ServerRejectedError(message:)` for `type:"error"` — no more URLError-wrapping. `StreamSession.runReconnect` catches this, calls `setReadiness(.failed(message: serverError.message))`, and exits the loop. Generic transport errors still fall through to the existing back-off-and-retry path. Net: red toast renders the verbatim server message (e.g. literally `hourly_rate_exceeded` / `free_exhausted` / `invalid_token`).

**Alternatives considered:**
- **Keep the active-pod check, raise `MAX_ACTIVE_PODS_PER_USER` to 2.** Would reduce false-positive frequency but doesn't address the underlying redundancy or the read-read race. Removal is cleaner.
- **Tighten the race window with a Redis lock or atomic SETNX.** Adds complexity for a guard that wasn't pulling weight.
- **Map enum reasons to friendlier UX strings on iOS** ("hourly_rate_exceeded" → "You've hit the per-hour limit, try again at HH:MM"). Useful for production but premature: today these denies fire on us during dev, and the raw reason is more debug-friendly than any mapping. Layer this in when we have real users.

**Consequences:**
- The `'too_many_active_pods'` value disappears from the wire protocol's `code` field. Any old iOS build that hard-coded a UI mapping for it now falls through to the generic toast (which would render "Server error" since no `message` carries that string anymore — the value is just gone). Not a problem in dev; would be a wire-compat consideration if we shipped a broader release.
- The hourly cap of 20 still bounds heavy retry-storm cost. At ~$0.55/hr per RTX 5090, the worst-case extra provisioning during a debug session is bounded.
- `ACTIVE_STATES` set is gone from `rateLimiter.ts` — the "step (4) update rate limiter `ACTIVE_STATES`" reminder in the 2026-04-23 entry below no longer applies. Adding new states only requires updating the orchestrator's `State` union, iOS `ProvisionState`, iOS `displayText()`, and `ACTIVE_PROVISION_STATES` in `orchestrator.ts`.

---

### 2026-04-24 — Idle-timeout reap: user-visible "Session Paused" UX with tap / draw to resume
**Context:** The 30-min idle reaper (`orchestrator.ts:runReaper`) used to terminate a user's pod silently from the iPad's perspective: the Redis row was deleted, the upstream WS closed, the new always-recover path attempted `replaceSession`, which threw `"No session to replace"` and bounced the iPad with a generic 1011 close. User had no idea what happened.
**Decision:** Reaper emits a `terminated` state through the broker with a new `failureCategory='idle_timeout'` BEFORE killing the pod. Stream.ts's broker subscriber closes the iPad WS cleanly with code 1000 on `state='terminated'`, setting the `clientDisconnected` flag so the upstream-close recovery path exits early (no fallback `replaceSession` attempt). iOS `StreamReadiness` gains an `.idleTimeout` case; `ResultState.idleTimeout(previousImage:)` renders a semi-transparent overlay on top of the last-generated image with an SF Symbol moon-zzz icon and "Session Paused - Draw to Resume" title in a teal→purple gradient with Apple-style layered drop shadows. Two resume paths — both wired to a new public `coordinator.resumeStream()`:
1. Tap anywhere on the overlay (button).
2. Start drawing — new `CanvasViewModel.onUserActivity` callback (fired from the existing `MetalCanvasView.onInteractionBegan` → `handleInteractionBegan`) notifies AppCoordinator, which auto-resumes if readiness is `.idleTimeout`.

`StreamSession.stop()` gained an optional `finalReadiness` parameter so the idle-timeout path can tear down without passing through `.disconnected` first.

Other `state='terminated'` paths (manual abort, `replaceSession` cleanup of the old pod) carry no `failureCategory` → iOS routes those to `.disconnected` as before. `idle_timeout` is the only category that triggers the new overlay.

**Alternatives considered:**
- **Leave the overlay generic / re-use `.failed`**: failure UI is red/alarming; idle timeout is routine and deserves calm visual tone.
- **Auto-resume silently on next stroke without a message**: tested poorly conceptually — user sees their session flip to "Finding GPU..." with no explanation for the interruption. Explicit acknowledgment is clearer.
- **Require page navigation to resume** (gallery → back to drawing): annoying friction; user explicitly pushed back on this path.
- **Carry a backend-authored message through to the overlay**: considered, but the UI hardcodes "Session Paused - Draw to Resume" so the message string is unused. Trimmed `message` out of `StreamReadiness.idleTimeout` and `ResultState.idleTimeout`; backend still emits a `failureCategory` which iOS maps locally. Less data, same result.

**Consequences:**
- Backend changes: add `idle_timeout` to `FailureCategory`; reaper calls `emitState(sessionId, 'terminated', 'idle_timeout')` before `terminatePod`; stream.ts broker subscriber closes iPad WS on `state='terminated'`.
- iOS changes: `FailureCategory.idleTimeout`, `StreamReadiness.idleTimeout`, `ResultState.idleTimeout(previousImage:)`. New `idleTimeoutView` in ResultView. Badge handling in DrawingView. `AppCoordinator.resumeStream()` public; `handleUserActivity()` bridges canvas strokes to it. `CanvasViewModel.onUserActivity` callback fires from `handleInteractionBegan`.
- Wire protocol unchanged — `failureCategory='idle_timeout'` is a new string value in an existing field. An old iOS build receiving it maps to `.unknown` and shows the generic "Something went wrong" message (graceful degradation, no crash).
- Testing: because the reaper only fires on 30 min of zero frame activity AND the capture loop touches `lastActivityAt` on every frame (~5 Hz), triggering this naturally while a session is live is near-impossible. Added `POST /v1/ops/test/idle-timeout/:userId` (gated by existing `X-Ops-Key` preHandler) that directly calls `emitState` to simulate the reaper event for UX testing. Future ops test-simulators land in the same file under `/v1/ops/test/*`.

---

### 2026-04-24 — Always recover the iPad session when upstream WS drops (delete classifyClose)
**Context:** Backend proxies `iPad ↔ Railway ↔ RunPod pod`. When the upstream (backend↔pod) WS closed mid-stream, the old `classifyClose` function decided whether to (a) replace the pod, (b) mark the close as `'crashed'` and replace, or (c) classify as `'voluntary'` and tell iPad the session is over. The `voluntary` branch checked only pod health: if `/health` returned 200, it assumed the close was client-initiated. Observed failure on 2026-04-24 07:56 UTC: upstream WS closed with code 1006 after ~10 min of no drawing — almost certainly a RunPod proxy idle timeout — pod was fine, classifier returned `voluntary`, backend closed iPad with code 1000 (clean close), iOS reconnect logic (which only retries on abnormal closures) did nothing. App stuck on "Connecting…" with no retry.
**Decision:** Delete `classifyClose` + `CloseClassification` entirely. Invariant: **if the iPad WS is still open when upstream closes, the user expects frames**. Always recover — there is no legitimate "voluntary upstream close while iPad is connected" case, because the user-left-the-app flow closes the iPad WS first and is already filtered by the `clientDisconnected || socket.readyState !== socket.OPEN` check at the top of `relay.onClose`. New flow:
1. Try reconnecting to the same `podUrl` first (~1–2 s if pod is still healthy — common for transient RunPod proxy idle timeouts and network blips; no full re-provision needed).
2. If that connect fails, call `replaceSession` (existing flow — provisions a fresh pod, ~90 s "Replacing — …" UX).

Extracted shared relay-wiring into a single `wireRelay(podUrl)` helper inside the `/v1/stream` route handler, used for the initial connect, same-pod reconnects, and replacement pods. Eliminated the duplicated-with-slight-variations code blocks.

**Alternatives considered:**
- **Fix at the transport layer** (WS keep-alive pings on the upstream): would reduce how often drops happen, but drops still happen on real network issues and cold hosts. Recovery at the handler level is needed regardless; keep-alive is a separate optimization.
- **Keep `classifyClose` but fix the `voluntary` branch** (e.g., inspect the close code): the upstream WS close code is 1006 for both "client abrupt disconnect → upstream sees abnormal" and "transport-level drop with pod alive." Not actually distinguishable. Simpler to always recover.
- **Tear down and restart after one failed replacement** (non-recursive onClose for the replacement relay): kept previously as belt-and-suspenders. `replaceSession`'s `MAX_SESSION_REPLACEMENTS` cap is the real protection against flapping pods — it throws when exhausted and the outer `try/catch` bounces iPad with a real error. Deleted the redundant non-recursive handler.

**Consequences:**
- `orchestrator.ts` loses `classifyClose` (~25 lines) + the `CloseClassification` type. `stream.ts` shrinks from ~290 lines of relay setup + onClose logic to ~150 lines with a shared `wireRelay` helper. Net: +112 insertions / -158 deletions across the commit.
- Transient WS drops (common: RunPod proxy idle timeout, brief network blips) now recover transparently in ~2–5 s with no "Replacing — …" UX flash. Real pod preemption still goes through the existing `replaceSession` flow unchanged.
- No Redis schema changes, no wire protocol changes. Single-commit rollback restores the `classifyClose` flow.

---

### 2026-04-23 — Deploy Python deps + app code via network volume (eliminate custom GHCR image)
**Context:** Each user session's pod was built from a slim `ghcr.io/donpinkus/kiki-flux-klein:<sha>` image layered on top of `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404`. PostHog data over the last 7 days showed ~38 % of provisions hit a GHCR pull stall: `pod.runtime` stayed null past the 120 s watchdog deadline on a specific subset of RunPod hosts unable to pull reliably from ghcr.io. Each stall added ~120 s of user-visible wait before the orchestrator rerolled to a different DC; real user wait on affected provisions was 200–310 s vs. the p50 of 83 s. Per-phase timing breakdown showed `fetching_image` = 18–28 s clean, `warming_model` = ~55 s; model load (not image pull) was the dominant chunk. 23 stall events / week (16 in EUR-NO-1). The custom image was originally introduced to avoid runtime `pip install` + HF weight downloads; weights moved onto network volumes shortly after (the image couldn't fit ~28 GB), but deps + app code stayed baked.
**Decision:** Remove the custom image entirely. Pods launch directly from the stock `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` (publicly cached on most RunPod hosts). Python deps + app code live on the attached network volume at `/workspace/venv/` (created via `python3 -m venv --system-site-packages` — base-image torch/CUDA visible so pip skips reinstalling them) and `/workspace/app/` (rsynced server code). Pod boot uses RunPod's `dockerArgs` to override CMD with `bash -lc 'source /workspace/venv/bin/activate && cd /workspace/app && exec python3 -u server.py'`, plus create-time `env:[]` for `HF_HOME`, `HF_HUB_OFFLINE`, `FLUX_*`. Deploy flow: `npx tsx backend/scripts/sync-flux-app.ts --dc <X> --volume-id <Y>` once per DC; idempotent (rsync/pip skip unchanged). Watchdog renamed `ImagePullStallError` → `PodBootStallError` (covers NFS mount stalls and cold-host stock-image pulls that can still occur, just much rarer); budget lowered 120 s → 45 s.
**Alternatives considered:**
- **`pip install --target /workspace/pydeps` (no venv)** — tested in POC, FAILS: pip treats target as a fresh env, installs a default `torch 2.11.0` + `nvidia-cublas-13.1.0.3` (CUDA 13) alongside base image's torch 2.9.1+cu128, breaking CUDA. The `--system-site-packages` flag on venv is what makes pip see base's torch as satisfied and skip reinstalling.
- **Keep GHCR but switch registry to Docker Hub / ECR** — doesn't address the GHCR-host stall, just shifts it.
- **Pre-warmed pod pool (standby pods always hot)** — directly addresses cold-start UX but costs ~$14/day per standby. Orthogonal to this decision; can stack on top later.
- **Versioned dirs `pydeps-<sha>/` + atomic symlink flip** — considered for partial-sync failure handling. Cut as overengineering for single-user scale; `git revert && railway up` is a valid rollback, and partial sync = re-run that DC's sync.
- **`FLUX_BOOT_MODE` dual-mode flag for gradual cutover** — cut for the same reason. Rollback via revert is fast enough; a compat flag adds permanent code surface.
**Consequences:**
- Backend code changes (one commit): `runpodClient.ts` (add `dockerArgs?`/`env?` fields), `orchestrator.ts` (pass `BASE_IMAGE`/`BOOT_DOCKER_ARGS`/`BOOT_ENV`; rename watchdog + error class), `errorClassification.ts` (rename `ImagePullStallError` → `PodBootStallError`, `image_pull_stall`/`fetch_image_timeout` categories → `pod_boot_stall`), `config/index.ts` (remove `FLUX_IMAGE`, `RUNPOD_GHCR_AUTH_ID`; rename `CONTAINER_PULL_*` → `POD_BOOT_*` with 45 s default), `vitest.setup.ts` (drop `FLUX_IMAGE` dummy). New: `backend/scripts/sync-flux-app.ts`. iOS: `ProvisionState.swift` drops `imagePullStall`/`fetchImageTimeout` failure categories, adds `podBootStall`.
- Clean-path cold-start comparable to today (~15 s gained from no custom-layer pull, ~30 s lost to NFS imports of diffusers/transformers on cold pod). Real win is tail-latency elimination — the 38 % of provisions that previously stalled 120–240 s now take a normal cold start.
- GHCR image build workflow (`.github/workflows/build-flux-image.yml`), `model-servers/Dockerfile`, and `backend/scripts/probe-dc-pulls.ts` are dead code after cutover. **Not deleted yet** — retained through the bake period for easy rollback; scheduled for stage-3 cleanup after 2–5 days of passing metrics (p95 ≤ 90 s, stall events ≤ 2 per 24 h).
- Railway env vars `FLUX_IMAGE`, `RUNPOD_GHCR_AUTH_ID`, `CONTAINER_PULL_*` still present — also removed at stage-3 cleanup. The base image tag is hardcoded (`BASE_IMAGE` const in orchestrator.ts) rather than env-driven, because bumping the base image requires a coordinated `/workspace/venv/` resync against the new Python/CUDA ABI, not just a config flip.
- **Rollback procedure (valid until stage-3 cleanup):**
  1. `git revert 332bcad` — the cutover commit (`refactor(provisioning): launch pods from stock runpod/pytorch + volume-entrypoint`). Brings back the orchestrator + iOS changes + config fields.
  2. On Railway: set `FLUX_IMAGE` and `RUNPOD_GHCR_AUTH_ID` again. Last known-good tag: `ghcr.io/donpinkus/kiki-flux-klein:sha-<commit>` where `<commit>` is `git rev-parse 332bcad^` (the commit immediately before the cutover). GHCR retains old tags indefinitely; no rebuild needed.
  3. `cd backend && railway up`.
  4. Rebuild iOS in Xcode, reconnect.
  5. `/workspace/venv/` and `/workspace/app/` dirs on the volumes are harmless to leave; old path ignores them.
  - After stage-3 cleanup, rollback additionally requires: restoring the Dockerfile + GHA workflow from history, and possibly rebuilding the GHCR image (~10 min) if the `:sha-<commit>` tag has been pruned.
- **When bumping the base image tag later:** delete `/workspace/venv/` on each DC first (SSH in or sync-script variant), then re-run `sync-flux-app.ts`. Python ABI in the old venv's `.so` files would otherwise conflict with a new base Python version.

---

### 2026-04-23 — Structured state machine for provisioning (replaces free-form status strings)
**Context:** Backend emitted 14 free-form status strings ("Pulling container image...", "Pod is starting up...", etc.) over the iOS WebSocket; iOS displayed them verbatim. Three problems: (1) iOS joiners reconnecting mid-provision got a one-shot "Pod is starting up..." and silence because `onStatus` was bound to the original caller's WS — joiner's callback was never wired in. (2) Display text crossed the wire, conflating state (backend's concern) with presentation (iOS's concern). (3) Redis had `SessionStatus` and the orchestrator had a separate `ProvisionPhase` type — two state machines at different granularities.
**Decision:** Single flat `State` enum (9 values: `queued | finding_gpu | creating_pod | fetching_image | warming_model | connecting | ready | failed | terminated`). Wire format is structured: `{ type: 'state', state, stateEnteredAt, replacementCount, failureCategory? }`. Backend never emits display strings; iOS maps state codes → user-facing text locally. In-memory broker (`subscribe` + `emitState`) fans out transitions to every WS connection for the session, so fresh callers and joiners share one mechanism. Redis stays the source of truth; broker owns subscriber sets only.
**Alternatives considered:**
- **Merge `status` and `phase` internally but keep free-form strings on the wire** — preserves the joiner bug and the layering violation; didn't solve either root cause.
- **Polling-based "last status" field in Redis** — simpler, but 1s latency is visible and reintroduces "display text in Redis" which the layering cleanup was trying to eliminate.
- **Fold the `connecting` state into `warming_model`** — lose explicit visibility into a distinct phase (pod `/health` ok but relay not yet connected). This gap caused silent frame drops when iOS thought "Ready" but the backend's `socket.on('message')` handler wasn't registered yet.
- **Don't separate `ready` from pod-ok vs relay-ready** — same silent-drop issue; "Ready" must mean iOS can actually stream, not just "pod is alive."
- **Emit separate `pod.state.exited` events for analytics** — doubles event volume for the same information. Instead, each `pod.state.entered` event carries `previous_state` + `previous_state_duration_ms`.
**Consequences:**
- `replacementCount` stays incremented through a session's life (doesn't reset on successful replacement). Required for the `MAX_SESSION_REPLACEMENTS` cap to protect against flapping pods. Tradeoff: after one preemption, reconnect flows briefly flash "Replacing — ..." until the session fully retires. Acceptable at current scale.
- `waitForReplacement` (polling helper) deleted — broker subscribers handle mid-replacement connects natively.
- `PodVanishedError.phase` renamed to `.state`; `FailureCategory` renamed (`runtime_up_timeout` → `fetch_image_timeout`, `health_timeout` → `warm_model_timeout`) to match.
- Rate limiter's `ACTIVE_SESSION_STATUSES` set moved to `ACTIVE_STATES` with new values — easy to forget when adding states; see `backend/src/modules/auth/rateLimiter.ts`. *(Superseded 2026-05-09: `ACTIVE_STATES` was removed from `rateLimiter.ts` along with the `too_many_active_pods` check. Adding new states no longer requires touching the rate limiter.)*
- Adding new states in the future: update (1) backend `State` union, (2) iOS `ProvisionState` enum, (3) iOS `displayText()`, (4) `ACTIVE_PROVISION_STATES` in orchestrator.ts.
- Wire protocol change: atomic swap across backend + iOS. Dev build only — single user rebuilds iOS and deploys backend in lockstep. TestFlight would require a dual-send compat layer.

---

### 2026-03-25 — Gallery home page with SwiftData local persistence
**Context:** App was single-screen with no persistence. Drawings were lost on app close. Needed a way to save, browse, and resume multiple drawings.
**Decision:** Add a gallery home page as the app root (state-based navigation, no NavigationStack). Each drawing is a SwiftData `@Model` with `@Attribute(.externalStorage)` for all image blobs. Auto-save on change (debounced 1s for UI events, immediate after generation). CanvasViewModel uses a pending-state pattern for save/restore: `setPendingState()` queues data before navigation, `attach()` applies it before the PKCanvasView delegate is set to avoid spurious change events. Gallery uses `@Query` for automatic SwiftData observation. Empty drawings are cleaned up on gallery navigation.
**Alternatives considered:**
- NavigationStack — adds push/pop semantics but the drawing view is heavy and we don't want it in the back stack; state-switching is simpler
- File-based storage (PKDrawing files + metadata JSON) — more manual, SwiftData is mandated by architecture decisions
- Drawing model as source of truth (bind views directly to `@Model`) — would require restructuring AppCoordinator; deferred to v2
- Separate GalleryModule SPM package — unnecessary complexity for v1; gallery views live in main app target
**Consequences:**
- ContentView renamed to DrawingView; RootView added as navigation root
- AppCoordinator now accepts `ModelContext` in init; `KikiApp` creates `ModelContainer`
- Gallery button (top-left of DrawingView) and "New" button (top-right of GalleryView) for navigation
- Long-press delete mode on gallery tiles with X badge overlay
- Canvas thumbnail pre-rendered at save time (256px max) since PKDrawing can't be rendered without a live PKCanvasView
- Generated image loaded at full resolution in gallery tiles (SwiftUI handles downscaling)

---

### 2026-03-17 — Use drawHierarchy for canvas snapshot capture (not PKDrawing.image)
**Context:** Sketch images uploaded to ComfyUI were blank white despite PKDrawing containing valid strokes at valid coordinates within canvas bounds. Root cause: `PKDrawing.image(from:scale:)` returns a blank image when the PKCanvasView is inside a transformed parent view (RotatableCanvasContainer). This broke ControlNet sketch adherence entirely — generations were prompt-only with no sketch conditioning.
**Decision:** Use `canvasView.drawHierarchy(in:afterScreenUpdates:)` inside a `UIGraphicsImageRenderer` to capture the live rendered view content instead of re-rendering from PKDrawing data.
**Alternatives considered:**
- `PKDrawing.image(from:scale:)` — blank output, likely PencilKit bug with ancestor transforms
- Moving `PKDrawing.image()` outside the renderer block — not tested, drawHierarchy is more reliable
- `canvasView.snapshotView(afterScreenUpdates:)` — returns a UIView, not a UIImage
**Consequences:**
- Snapshot captures exactly what's on screen (WYSIWYG)
- Requires canvasView to be in the window hierarchy and visible (always true for our use case)
- Corrects the previous decision's note about switching TO `PKDrawing.image(from:scale:)` — that approach is broken

---

### 2026-03-17 — Canvas zoom and rotation via RotatableCanvasContainer
**Context:** Users need to zoom in for detail work and rotate the canvas to draw at comfortable angles.
**Decision:** Wrap PKCanvasView in a RotatableCanvasContainer with a three-level view hierarchy: container (SwiftUI-managed, no transform) → transformView (receives combined CGAffineTransform for scale + rotation) → PKCanvasView (drawing only). Zoom and rotation are handled by UIPinchGestureRecognizer and UIRotationGestureRecognizer on the container, applied as a single combined transform on the intermediate view. UIKit automatically translates touch coordinates through the parent's transform, so drawing works at any scale/rotation.
**Alternatives considered:**
- SwiftUI `.rotationEffect()` — breaks touch coordinate mapping for UIViewRepresentable
- Transform on the UIViewRepresentable root view — SwiftUI re-layouts fight the transform, squishing the canvas
- PKCanvasView's built-in UIScrollView zoom — zooms content inside a fixed frame with scroll bars, not the whole canvas visually
- CALayer transform3D — undocumented interaction with PencilKit touch handling
**Consequences:**
- ~~Snapshot capture switched from `drawHierarchy` to `PKDrawing.image(from:scale:)` to capture full drawing regardless of visual transform~~ **REVERTED** — `PKDrawing.image()` produces blank output with transformed ancestors; switched back to `drawHierarchy` (see 2026-03-17 decision above)
- New file: `RotatableCanvasContainer.swift` in CanvasModule
- Rotation snaps to 90° increments when released within ~8° threshold; scale clamped to 0.5x–5x
- Reset button appears in toolbar when canvas is zoomed or rotated

---

### 2026-03-15 — Replace fal.ai with ComfyUI (Qwen-Image) on RunPod
**Context:** fal-ai/scribble (SD 1.5 ControlNet) produced low-fidelity results with limited control. Needed higher quality generation with better sketch adherence and a model that supports more control types.
**Decision:** Switch to Qwen-Image 20B (FP8) + InstantX ControlNet Union running on ComfyUI, hosted on a RunPod H100 80GB SXM GPU pod. Use AnyLine Lineart preprocessor for soft edge control from PencilKit sketches. Lightning LoRA V2.0 for 8-step generation.
**Alternatives considered:**
- Union DiffSynth LoRA (supports lineart/softedge but is a LoRA hack, less stable)
- DiffSynth Model Patches (only canny/depth/inpaint, no lineart)
- Keeping fal.ai with different models (limited model selection)
**Consequences:**
- Generation latency increased from ~4s to ~6-8s (but quality is dramatically higher)
- Backend now depends on RunPod pod availability (no auto-scaling yet)
- Workflow params (strength, steps, models) changed via ComfyUI web UI + re-export of API format template
- Cost model changed from per-image API pricing to per-hour GPU rental ($2.69/hr H100 SXM)
