# Kiki Unified Brush Engine — Target Architecture (Procreate-Parity, One Pipeline, No Modes)

**Written:** 2026-06-08 · **Method:** produced by a multi-agent planning workflow (5 independent architecture plans, each from a distinct lens → 2 independent reviews → 1 convergence). This doc is the converged output.

**Status:** Committed target architecture. Supersedes the per-feature phasing in `pro-brush-roadmap.md` (whose phases map onto this as additive parameters, §6).
**Scope:** the iPad Metal canvas engine in `ios/Packages/CanvasModule/`. No backend/pod involvement.
**Hard product constraint:** there is no `wetEnabled` toggle and no per-feature render path. Every Procreate Brush Studio control is an ordinary parameter present on every brush, defaulting such that a plain pen is a brush with `wetness=0, grainDepth=0, shape=round, scatter=0`. Reaching this state is the only acceptable destination; any design that forecloses full parity, or bolts on a code path per feature, is rejected (§7).

---

## 1. Target architecture overview (the unified stroke pipeline in one diagram-in-prose)

The engine's two paths today (`renderStampsIntoScratch` → dry; `applyWetStamps` → direct-to-layer framebuffer-fetch RMW) exist for exactly one reason: dry needs an **isolated** accumulation buffer to get Glaze (self-overlap stays flat, composited once at an opacity ceiling), while wet needs to **read the paint underneath** to mix against it, and in-place RMW is incompatible with isolation. The wet path's framebuffer fetch is also why its PSO is nil on the Simulator.

The whole redesign rests on **one decoupling**: today's split conflated two orthogonal questions — *(a) where does the stroke accumulate?* and *(b) does a dab's color depend on what's already on the canvas?* The target answers them independently:

- **(a) The write target is ALWAYS the isolated per-stroke buffer.** This is what preserves Glaze and the single opacity-ceiling composite, for every brush, unconditionally.
- **(b) "The canvas underneath" is read as BOUND SOURCE TEXTURES** (`sample()`), never as the framebuffer being written. *Reading the canvas as a source ≠ modifying it in place.* This is Simulator-safe (sampled textures compile; framebuffer-fetch PSOs do not), and it is strictly more capable than today's wet path — it can see the in-flight stroke's own paint, which framebuffer-fetch-of-committed-layer cannot.

Concretely, every stroke renders into a **Stroke Accumulation Buffer (SAB)** via one instanced dab pass whose single fragment shader is given read-only bindings to (i) `belowTex` — a frozen snapshot of the active layer at `touchesBegan`; (ii) `sabPrev` — the stroke-so-far via ping-pong; (iii) `reservoirBuf` — a tiny GPU paint reservoir carrying the brush's loaded pigment along the stroke; (iv) the shape and grain masks. The fragment computes one coverage and one pigment color and writes them into the SAB. Wet mix is a `mix(brushColor, wetTarget, wetness)` term inside that one shader: at `wetness=0` it collapses to the plain premultiplied deposit, **bit-identical to today's dry pen**. The SAB is composited onto the layer exactly once, at stroke end, scaled by the per-stroke opacity ceiling (today's `activeStrokeOpacity` uniform, unchanged — *this is the Glaze cap*).

Per frame, for the active stroke, the **same** sequence runs for every brush — pen, oil, chalk, smudge, eraser — with no path-level branch:

```
On touchesBegan:
  blit active layer → belowTex            (one-shot, off hot path)
  allocate SAB; allocate sabPrev + reservoirBuf ONLY IF the brush samples them
  push undo snapshot of active layer       (generalized eraser pattern — same for all brushes)

Per advancing frame (new dabs only):
  Pass A  Reservoir update   → reservoirBuf'   (1-D, scheduled only when wet/smudge active)
  Pass B  Dab accumulation   → SAB             (ONE instanced draw; reads belowTex, sabPrev, reservoir, shape, grain)
  blit SAB→sabPrev over the frame's DIRTY BBOX (not full document)
  Pass C  Composite preview  → drawable        (layers + SAB×opacity ceiling + blend mode)

On touchesEnded:
  Pass D  Commit             → active layer     (Pass C's math, store target = the layer; the ONE waitUntilCompleted)
  free SAB / sabPrev / belowTex / reservoirBuf  (idle footprint unchanged)
```

No `isWet` chooses among these. Wetness, dilution, charge, pull, grade are uniforms read inside Pass B; at their defaults the shader runs the identical kernel and emits the dry result. The only per-stroke *selection* is which pre-built blend-state PSO Pass B uses (Glaze-cap vs Build-up vs eraser destination-out) and whether Pass A / the `sabPrev` snapshot are scheduled — both decided once at `touchesBegan` from the descriptor, neither a per-pixel branch nor a duplicated code path.

The sections below resolve the four contested details (SAB format, ping-pong determinism, Glaze↔Build-up mechanism, reservoir sizing) explicitly.

---

## 2. Unified parameter model

### 2.1 The descriptor

Replace the flat `BrushConfig` (`DrawingEngine.swift:63`, including the forbidden `wetEnabled: Bool`) with `BrushDescriptor`: nested sub-structs mirroring Brush Studio panels 1:1. This is the persistence + preset unit.

```
BrushDescriptor : Codable, Sendable, Identifiable
├─ id, schemaVersion
├─ meta:          BrushMeta          // About — title, author, dateCreated, signatureRef, resetPoint
├─ strokePath:    { spacing, spacingJitter, jitter, fallOff, fallOffPerPoint }
├─ stabilization: { streamlineAmount, streamlinePressure, stabilizationAmount, motionFilter, motionExpression }
├─ taper:         { pressureSize, pressureOpacity, tip, touchTaper, classic, linkTipSizes }
├─ shape:         { shapeRef:AssetRef?, scatter, count, countJitter, randomized,
│                   flipX, flipY, roundness, baseRotation, pressureRoundness, tiltRoundness,
│                   inputStyle(touch|azimuth|azimuthBarrelRoll), filtering }
├─ grain:         { grainRef:AssetRef?, behavior(moving|texturized), movement, scale, zoom,
│                   rotation, depth, depthMin, depthJitter, offsetJitter, blendMode, brightness, contrast,
│                   followsCamera }    // followsCamera stored, not rendered (§4)
├─ rendering:     { mode(6 Glaze/Blend variants), flow, wetEdges, burntEdges, blendMode, luminance }
├─ wetMix:        { dilution, charge, attack, pull, grade, blur, blurJitter, wetnessJitter }  // ALL default 0 ⇒ dry
├─ colorDynamics: { stamp{hue,sat,light,dark,secondary}, stroke{...}, pressure{...}, tilt{...} }
├─ dynamics:      { speedSize, speedOpacity, jitterSize, jitterOpacity }
├─ pencil:        { pressure{size,opacity,flow,bleed}, tilt{size,opacity,gradation,bleed,curve}, sizeCompression, barrelRoll{...} }
├─ properties:    { maxSize, minSize, maxOpacity, minOpacity, smudgePull, orientToScreen, useStampPreview }
└─ materials:     { metallic, metallicScale, roughness, roughnessScale }   // stored, not rendered (§4)
```

**Color is NOT in the brush.** The brush is the preset, color is the active swatch. A `Stroke` carries `brushID` (+ an inlined descriptor snapshot for replay fidelity) **plus** `ink: CodableColor` and `secondaryInk: CodableColor`. Secondary ink feeds Color Dynamics and Wet Mix. Today's `BrushConfig.color` (`DrawingEngine.swift:64`) is modeled wrong for presets; migration moves it to `Stroke.ink` (§6, Step 0).

**The no-toggle requirement is enforced structurally, not by discipline.** There is no `wetEnabled`. "Is this wet?" is a derived scalar `wetness = max(dilution, pull, charge)`, computed once per stroke, used only to *schedule* Pass A / the `sabPrev` snapshot (a perf decision) — never to fork dab behavior. The picker UI may hide the Wet Mix panel when `wetness==0`; the engine never reads a mode.

### 2.2 Defaults = today's pen

Every field defaults to its inert value and is combined multiplicatively/by-lerp such that it is identity at default (`grainDepth=0 ⇒ ×1`; `wetness=0 ⇒ mix weight 0`; `scatter=0, count=1 ⇒ one dab`; `shapeRef=nil ⇒ procedural round`). A `BrushDescriptor()` reproduces `defaultPen` exactly. This generalizes the roadmap's Phase-0 non-regression property to *all* future parameters: shipping a new control is provably non-regressive for existing brushes.

### 2.3 Persistence + presets

- `BrushDescriptor` is `Codable` to JSON and **is the preset**.
- **Backward-compat:** `decodeIfPresent ?? default` on every key (the existing pattern at `DrawingEngine.swift:164–191`), plus a `schemaVersion` migration ladder. A v1 flat `BrushConfig` (or a save missing whole panels) decodes to a dry round pen, byte-identical to today.
- **Assets are content-addressed references, not inline blobs.** `shapeRef`/`grainRef`/`signatureRef` are `AssetRef { source: .builtin(id) | .imported(sha256), displayName }`, resolved through a `BrushAssetStore` (generalizes today's `BrushShapeCatalog` to also serve grains). Presets ship IDs; identical textures dedup.
- **Sharing:** a `.kikibrush` bundle = `descriptor.json` + referenced shape/grain/signature PNGs, symmetric to Procreate's `.brush`. We can import `.brush` losslessly because we *store* the fields we don't render (Materials, followsCamera, barrel-roll) and round-trip them — a future renderer lights them up with zero schema change.

### 2.4 How parameters reach the GPU (the flat-projection invariant)

Hard rule: **the renderer consumes only the projection, never the descriptor.** Two POD structs bridge descriptor → GPU:

- **`StampInstance`** (per dab, vertex stage) — superset of today's 9 floats: `center`, **`size: SIMD2` (anisotropy = roundness)**, `rotation`, `color: SIMD4` (premultiplied, post per-stamp color-dynamics jitter), `flow`, `hardness`, `wetness`, `grainPhase: SIMD2`, `reservoirIndex`, `seed`. All *per-stamp dynamics* (scatter, count, jitter, taper, pressure/tilt/speed→size/opacity/flow, color-dynamics) are resolved **CPU-side at stamp generation** (`generateStampsForStroke`) and baked here. This keeps the fragment uniform-driven.
- **`BrushUniforms`** (per stroke, fragment stage) — the *per-pixel-constant* knobs: `renderMode`, `blendMode`, `hardness`, `wetness`, `dilution`, `charge`, `attack`, `pull`, `grade`, `wetEdges`, `grainDepth`, `grainMode`, `grainBlend`, `hasShape`, `hasGrain`.

`hasShape`/`hasGrain` are **texture-binding validity guards, not feature flags** (you cannot sample an unbound texture in MSL). With `hasGrain==0` the grain term is `1.0` (identity); the shader still runs one path.

Because the dab generator and the fragment see only `StampInstance` + `BrushUniforms` — never `descriptor.wetMix.dilution` — an `if brush.wetEnabled`-style branch is **structurally impossible to reintroduce**. The only branches that can exist are `switch renderMode`/`switch grainBehavior` (data-driven equation selection) and the binding guards.

**Determinism:** every jitter/scatter/count/color-dynamics RNG draw is seeded from `stroke.seed` (new `UInt64` on `Stroke`) + stamp index. Undo/replay re-renders from points; a wall-clock RNG would desync. This is the known Phase-2 trap, made structural.

**The CPU-bake cost flag:** baking per-stamp color-dynamics/secondary-color into `StampInstance` adds main-thread per-stamp work, and `appendStamp` already writes through a `.shared` buffer pointer on the main thread. This is the opposite direction from the perf goal at high `count`/`scatter`. **Mitigation:** keep the bake to cheap scalar ops; benchmark a high-count scatter brush early; if the bake dominates, move color-dynamics into the vertex stage (it has the seed and per-instance attributes already). Tracked as an open perf item (§7).

---

## 3. Rendering pipeline detail

### 3.1 Textures and lifetimes

| Texture | Format | Size | Lifetime | Role |
|---|---|---|---|---|
| `layers[i]` | bgra8Unorm_srgb | 2048² | document | committed paint (unchanged) |
| **`sab`** | **see §3.2** | 2048² | per stroke | isolated current stroke; pigment + coverage. Replaces `scratchTexture` |
| **`sabPrev`** | same as `sab` | 2048² | per stroke (wet only) | stroke-so-far snapshot (self-smear source) |
| **`belowTex`** | bgra8Unorm_srgb | 2048² | per stroke | frozen active layer at `touchesBegan` (wet pickup source) |
| **`reservoirBuf`** | RGBA float | **1×K, K≈256** | per stroke (wet only) | carried pigment + remaining volume along arc-length |
| `shapeTex` | r8Unorm mip | ≤2048² | app | tip mask (exists) |
| `grainTex` | r8Unorm mip | tileable | app | paper/grain (new) |

`belowTex` is one GPU blit at `touchesBegan` (off the hot path). `sab`/`sabPrev`/`reservoirBuf` are pooled and reused across strokes (texture creation, not per-frame). For a dry brush, `sabPrev` and `reservoirBuf` are **not allocated at all** — the dry path is exactly today's path reached by the same code with wet sampling switched off by data.

### 3.2 SAB format — resolving the 16F dispute

Both reviews flagged an unconditional rgba16Float SAB (+16F `sabPrev`) as the highest budget risk: it doubles bandwidth on every dab fill and every ping-pong blit, and it introduces a color-space hazard (a 16F-linear-straight buffer composited to 8-bit-sRGB-premultiplied layers can resurrect the module's cumulative-darkening bug if the conversion is wrong).

**Resolution:** the SAB format is **chosen per stroke**, not globally.
- **Dry / Glaze / plain brushes → `bgra8Unorm_srgb`** — provably sufficient (it ships today as the scratch buffer), half the bandwidth, same color encoding as every other texture (no conversion hazard).
- **Wet or heavy Build-up brushes → `rgba16Float`** — needed for KM precision and many-low-flow accumulation without banding, allocated only for that stroke, with the **sRGB-linear ↔ premultiplied conversion specified explicitly at the composite** (Pass C/D): SAB stores straight linear pigment + coverage; the composite converts to sRGB-encoded premultiplied before writing the layer. This conversion is verified offline against a reference (per `feedback_verify_shader_color_offline`) before any device test.

This is format-selection-by-capability at `touchesBegan` — the same class of per-stroke decision as PSO selection, not a path fork.

### 3.3 Pass A — Reservoir update (GPU, retiring the CPU `getBytes`)

Today's smear carries load on the CPU: per dab a 1×1 `sampleLayerColor` `getBytes` (`CanvasRenderer.swift:585`) + `kmMixCPU` (`MetalCanvasView.swift:960`) — a synchronous main-thread readback per stamp, and it only sees *committed* paint. Deleting this is unambiguously right; it fixes the named anti-pattern **and** a correctness bug.

**Resolving the reservoir-sizing dispute:** a 2-D reservoir (256² ring) is over-designed. Procreate's Charge is a scalar volume along **one 1-D stroke**. **`reservoirBuf` is 1×K**, indexed by arc-length bucket. Each frame, for the new arc-length span:
- sample `belowTex` at the new dab centers (the canvas the brush crosses);
- `newLoad = KM_mix(prevLoad, sampledCanvas, pull · canvasAlpha)` — Pull draws underlying color into the load;
- `volume -= attack` per unit length; Charge refills; on depletion the load fades toward Dilution (medium).

The KM tables (`setupWetKMTables`) move verbatim into this shader. Pass A is **scheduled only when `wetness>0`** (a per-stroke decision); a dry brush binds a constant load and skips it.

**Encoder-dependency warning:** Pass A must not be a per-dab encoder — that's a per-frame serial barrier on the hot path. It is **one 1-D pass per frame** (or folded into the dab pass), updating the whole frame's arc-length span at once. Within one command queue, the render Pass B that reads `reservoirBuf` is correctly ordered after the Pass A that writes it; state the dependency explicitly in code.

**Before building the GPU reservoir, benchmark the cheap fix:** a *per-frame coalesced* CPU readback (one `getBytes` of the frame's dab region per frame, not per stamp) may already kill the cost. Measure it first; only build the GPU reservoir if the coalesced readback is insufficient.

### 3.4 Pass B — Dab accumulation (the one shader)

One PSO family, one fragment shader (descendant of `renderStampsIntoScratch`), instanced quads. The fragment:

```
// coverage
base     = (hasShape ? sample(shapeTex, shapeUV).r : proceduralSoftCircle(uv, hardness))
base    *= mix(1.0, sample(grainTex, grainUV).r, grainDepth)   // grainDepth=0 ⇒ ×1
base    *= taperEnvelope(arcLenNorm)
coverage = pow(base, hardnessGamma) · in.dabOpacity
deposit  = coverage · in.flow

// pigment — wet is a lerp, gated to identity at wetness 0
under    = over(sample(sabPrev, canvasUV), sample(belowTex, canvasUV))   // stroke-so-far over frozen layer
wetTarget= KM_mix(reservoirLoad, under, grade)
pigment  = mix(in.color /*brush ink*/, wetTarget, in.wetness)            // wetness 0 ⇒ pigment == ink, EXACTLY dry

// cheap-out for dry: branch is coherent across a dry dab → no divergence cost
if (in.wetness < ε) { pigment = in.color; }   // skips KM loop + sabPrev/belowTex sample for dry brushes

write (pigment, deposit) into SAB
```

**The load-bearing identity:** at `wetness=0`, `pigment == in.color` and every wet term contributes nothing → the SAB receives exactly what today's dry premultiplied stamp would. The default pen is provably non-regressive (snapshot diff = 0), and the 30%-self-crossing-stays-flat Glaze test is inherited verbatim because the SAB is still an isolated coverage buffer composited once.

**Grain UV mode** is `behavior` selecting stamp-space UV (moving) vs **document-space** UV (texturized) from the `canvasPos` the vertex shader already computes — a `mix()` of two UV sources by `movement`, not a branch. Texturized grain is locked to the fixed 2048² **document** space, so it is invariant under the view's pan/zoom/rotate (the canvas container transforms the *display*, not the document). **Verify this explicitly** before promising grain parity (open item, §7).

### 3.5 Ping-pong, dab ordering, and live-preview-vs-flatten determinism

This is the subtlest correctness area.

**Within one frame, all dabs read the same immutable `sabPrev`** (last frame's SAB), so the whole frame's dabs are **one instanced draw** — the cheap path — with order-independent results. Cross-frame, the smear evolves because `sabPrev` and `reservoirBuf` advance each frame. This is what keeps us to one draw call per frame instead of N serialized draws (today's `wetOrderingPerStamp` per-stamp serialization).

**The `sabPrev` snapshot is dirty-bbox-limited** — the single most important perf optimization. A full 2048² blit per frame would threaten the budget (and a fast diagonal stroke's axis-aligned bbox can be large); blit only the frame's dab bounding box. **Do not ship the naive full-frame copy.**

**Honest labeling of what frame-granular mixing discards:** overlapping wet dabs *within one frame* do not mix with each other — they each mix against frozen `sabPrev`. At 120 Hz with adaptive spacing, intra-frame dabs span ~one short stroke segment; the visible difference from true per-dab serialization is *plausibly* sub-perceptual and *plausibly* below what img2img resolves — but this is an **inference, not a measurement**. Gate it: keep the existing `wetOrderingPerStamp` A/B, validate frame-granular against serialized on a real wet drag, and only then delete the serialized fallback.

**Live-preview-vs-flatten determinism — the one genuinely open correctness question.** Because the SAB accumulates incrementally and the ping-pong read is frame-granular, a *wet* stroke's accumulated result depends on which dabs landed in which frame. The live preview (Pass C) and the deterministic replay-at-commit / undo-replay must not diverge. **Resolution:** the commit (Pass D) and any undo-replay **replay through the identical batched pipeline** — the same per-frame dab batching and ping-pong cadence — not a one-shot all-dabs pass. We make this deterministic by recording, per stroke, the dab-batch boundaries (which dab indices were submitted in each frame) alongside the points, so replay reproduces the exact frame-granular evolution. For dry brushes this is moot (source-over is order-independent); for wet it is required.

### 3.6 Glaze ↔ Build-up — resolving the mechanism dispute

"Lerp the blend factor in-shader by a `buildUp` scalar" is rejected because Glaze (saturate to a coverage ceiling) and Build-up (accumulate past 1) are **different blend equations**, and an in-shader lerp is not numerically equivalent. **Glaze and Build-up are two pre-built PSOs sharing one vertex+fragment function, differing only in the color-attachment blend descriptor**, selected once per stroke from `rendering.mode` (exactly how `makeBrushStampPSO(eraser:)` already builds two PSOs from differing blend descriptors).

| Render mode | Pass B (dab→SAB) blend |
|---|---|
| Light/Uniform/Intense/Heavy **Glaze** | source-over, coverage capped at 1 (overlaps saturate); the four variants differ only by a coverage-shaping curve uniform |
| Uniform/Intense **Blending** (Build-up) | source-over without cap (deposit accumulates past the ceiling) |

This is a per-stroke pipeline-state lookup — **not** a per-pixel branch, **not** a code path. The four Glaze intensities are one coverage-curve uniform, needing no distinct PSO.

### 3.7 Eraser

The eraser is genuinely subtractive and canvas-color-independent. It is the **shared dab pass with a `destinationOut` blend-state variant** into the SAB (so erase is isolated and undoable like any stroke), or onto the layer if the live-erase feel is preferred — through the *same* fragment, a third blend-state PSO in the family. This removes the last framebuffer-fetch PSO (today's `eraserStampFragment`) and unifies undo (snapshot-at-`touchesBegan` for all brushes).

### 3.8 Pass C / D — composite and commit

Identical math, different render target + store action (today's `compositeToDrawable` / `flattenScratchIntoCanvas` pair). The SAB is composited over the destination layer: multiply coverage by the **per-stroke opacity ceiling** (the existing `activeStrokeOpacity` uniform — the Glaze cap, untouched); apply the blend mode against the real layer; convert SAB straight-linear pigment+coverage → sRGB premultiplied (the conversion specified in §3.2). Commit (Pass D) writes the layer once, the single sanctioned `waitUntilCompleted` per stroke.

---

## 4. Procreate Brush Studio coverage matrix

Legend: **Native** = falls out as parameters into one pass; **Stage** = a new unified (non-branching) stage; **Hard** = admitted but expensive/tuning-heavy; **Reject** = admitted by the architecture but deliberately not built (reason given). "img2img" = leverage under klein re-reading the canvas every ~250ms.

| Panel / control | Coverage | Engine mechanism | img2img leverage |
|---|---|---|---|
| **Stroke Path** — Spacing, Jitter, Fall Off | Native | CPU stamp gen; spacing exists; jitter = seeded perpendicular offset; fall-off = α ramp over arc-length | High (geometry) |
| **Stabilization** — StreamLine, Stabilization, Motion Filter | Native | CPU input filter upstream (StreamLine shipped); add spring + motion low-pass | High |
| **Taper** — pressure/touch size & opacity, tip, classic | Native | `taperEnvelope` over arc-length + width ramp (partly shipped) | Med-high |
| **Shape** — source, scatter, count, jitter, roundness, flip, azimuth, filtering | Native | shapeRef → bound mask; scatter/count/jitter/flip in stamp gen (seeded); roundness = anisotropic `size`; rotation field already plumbed; filtering = sampler mode | High |
| **Grain** — moving/texturized, scale, zoom, depth, jitters, blend, brightness/contrast | Stage (gated) | second bound `grainTex` in Pass B; moving=stamp-UV, texturized=document-UV via `canvasPos`; depth modulates coverage. **Gate on img2img-survival spike** — coarse value-grain survives, fine tooth resynthesized | Lower (gated) |
| **Rendering** — 6 modes, Flow, Wet Edges, Burnt, Blend Mode, Luminance | Native | mode → per-stroke PSO blend-state (§3.6); flow per-dab; Wet Edges = coverage-gradient rim boost; ship 3–4 value/hue blend modes, rest Reject | Med |
| **Wet Mix** — Dilution, Charge, Attack, Pull, Grade, Blur, jitters | **Hard** (native) | §3.3 reservoir + §3.4 pigment lerp. Dilution=mix toward medium; Charge=initial volume; Attack=deposit rate; Pull=pickup; Grade=transfer hardness; Blur=optional separable SAB blur (scheduled when blur>0). **Hardest, fully native.** KM color already shipped — reuse, never ship Mixbox unlicensed | **Highest** (pigment color = conditioning intent) |
| **Color Dynamics** — stamp/stroke/pressure/tilt jitter, secondary | Native | per-dab color baked CPU-side from descriptor + seed into `StampInstance.color`; secondary = `Stroke.secondaryInk` | Med-high |
| **Dynamics** — speed→size/opacity, jitter→size/opacity | Native | velocity from `StrokePoint.timestamp` (captured); seeded jitter | Med |
| **Apple Pencil** — pressure size/opacity/flow/bleed, tilt graph, barrel roll, hover | Native / Reject | pressure→size exists; curves = LUTs; **bleed→wetness coupling** (why bleed must be a unified-path param); barrel-roll/hover = Pencil-Pro/hardware-gated → Reject (admitted) | High (pressure/tilt) |
| **Properties** — max/min size & opacity, smudge pull, orient to screen, preview | Native | clamps; **smudge pull = `pull`**; orient = rotation frame | Med |
| **Materials** — metallic/roughness | **Reject (admitted)** | would be "sample one more normal/roughness texture + a synthetic light in Pass B, write an aux MRT channel" — pipeline admits it; **not built**: a relit canvas with no 3D scene is obliterated by the model's own lighting. Fields stored for lossless `.brush` import | ~0 |
| **About** — title/author/signature/reset | Native | `BrushMeta` + stored reset snapshot | N/A |

**Smudge** is not a tool or a mode — it is a **preset**: `wetMix.charge=0, pull=1, wetness=1, flow=0`, with `properties.smudgePull → pull`. This settles the long-deferred Metal smudge for free.

**Non-foreclosure proof:** the two genuinely hard sections (Wet Mix, Materials) and the leverage-rejects (grain-follows-camera, barrel-roll) all reduce to "bind another texture" or "add a uniform/channel" — none requires a new path. **Reachable ≠ on the build list:** we reject some on *leverage*, never on *capability*. Parity is foreclosed nowhere.

---

## 5. Performance & real-time strategy

**Per-frame hot path (target <8ms @ 120Hz):**
- Pass A: 1-D, ≤K texels, scheduled only when wet. Negligible. One pass/frame, never per-dab.
- `sabPrev` snapshot: **dirty-bbox blit only** — the keystone optimization. Sub-0.1ms for a typical segment; never the full-document 16F blit.
- Pass B: one instanced draw (≤ today's cost for dry; for wet the KM fragment is the real cost, see below).
- Pass C: composite (today's cost).
- **No `waitUntilCompleted`, no `getBytes`, no `drawHierarchy` on the per-frame/per-touch path.** The only `waitUntilCompleted` is Pass D, once per stroke.

**The KM fragment is the genuine budget risk.** Cost scales with brush *area* × the 36-band spectral loop. The stress case is a **~600px wet airbrush**. Fallback ladder, in order:
1. Replace the in-shader RGB→spectrum upsample (the expensive part) with a **fixed 7-basis matrix multiply** — cuts the 36-band loop to a few dot products. Almost certainly sufficient.
2. Compute pigment at half-res, upsample coverage at full-res (the model eats fine pigment detail anyway).
3. Decouple wet pigment from frame rate: linear-mix preview at 120Hz, KM refine on a coalesced cadence.

**Budget-test the 600px wet airbrush on the oldest target iPad FIRST**, not last — with both new costs (dirty-bbox snapshot, KM fragment) and their mitigations implemented from day one, not retrofitted.

**Framebuffer-fetch vs Simulator:** the entire engine — including wet — is `sample()` of bound textures + a 1-D reservoir pass. **No framebuffer fetch anywhere.** It compiles and runs on the Simulator, *fixing* today's wet-is-dead-on-Sim regression (`makeWetStampPSO`'s Simulator-nil guard at `CanvasRenderer.swift:1295` is deleted). Simulator-parity is a primary acceptance criterion.

**Memory budget:** new persistent state = pooled `sab` (+ `sabPrev`, `belowTex`, `reservoirBuf` allocated per *wet* stroke only). At 2048²: 8-bit SAB = 16MB; wet adds a 16F SAB+sabPrev (64MB) + belowTex (16MB) only while a wet stroke is in flight, freed at stroke end. Idle/gallery footprint is unchanged. Negligible against an active img2img session.

**Deferred/async:** `belowTex` blit (stroke start, off hot path); Pass D commit (stroke end); the optional Wet Mix Blur pass (scheduled only when `blur>0`). The CPU-bake of per-stamp dynamics is the one new main-thread cost — bounded, benchmarked early, with a vertex-stage escape hatch (§2.4).

---

## 6. Incremental migration plan

The architecture must land as one refactor (it must, to kill the second path), but features fold in as pure parameters afterward. Each step builds, behaves correctly, is independently shippable, and is `git revert`-able. The risky KM/wet rework lands **last**, on a proven substrate, with a non-regression oracle at every step. **No big-bang.**

**Step 0 — Parameter tree refactor (data only, zero render change). First shippable step.**
Restructure `BrushConfig` → `BrushDescriptor` (§2), `decodeIfPresent` everywhere + `schemaVersion`. Add `seed: UInt64` and dab-batch boundaries to `Stroke`. Move `color` → `Stroke.ink`/`secondaryInk`. **Delete `wetEnabled`** — behavior derived from `wetMix.*>0` (old `wetEnabled:true` → migrated `charge/pull>0`; the bool never re-enters). Defaults reproduce today's flat fields. *Validate:* old drawings load byte-identical; default-pen snapshot diff = 0. SwiftData schema is untouched (descriptor lives in stroke JSON / preset blobs — confirm before shipping). *Rollback:* trivial (data-only).
Migration map: `color→Stroke.ink`, `opacity→rendering.opacity`, `flow→rendering.flow`, `hardness/spacing/taper/shapeID/pressureGamma/tiltSensitivity/streamline` → panels, `wetStrength→wetMix.charge/attack`, `wetPickup→wetMix.pull`, `wetEnabled` dropped.

**Step 1 — Unify the dab fragment (shape + round + hardness + grain-ready).**
Merge `brushStampFragment` + `shapedStampFragment` into one `unifiedDabFragment` (round = procedural branch; shapeTex always bindable; grain sampled at `grainDepth`, default 0 ⇒ inert; binding guards `hasShape`/`hasGrain`). Dry/scratch path otherwise unchanged. *Validate offline:* coverage == today's procedural/shaped output; device snapshot diff = 0. *Rollback:* keep old two fragments until the diff is verified, then delete.
Files: `renderStampsIntoScratch`'s `if activeShapeTexture` branch (`CanvasRenderer.swift:1168`) collapses; `brushStampPSO`/`shapedBrushStampPSO` → one PSO.

**Step 2 — SAB ping-pong + incremental accumulation + dirty-bbox snapshot.**
Rename `scratchTexture` → `sab` (8-bit for now); add `sabPrev` ping-pong + dirty-bbox blit. Switch dry accumulation to incremental `loadAction=.load` depositing only new dabs.
**Corrected rationale:** today's *wet* path (`applyNewWetStamps`, `MetalCanvasView.swift:929`) is **already incremental** (deposits only dabs since `lastWetPointIndex`); only the *dry* scratch path re-stamps the whole stroke each frame, and that is harmless idempotent source-over, **not** an O(stroke²) re-mix bug. So incremental accumulation is a perf optimization for long strokes **and an enabler** for keeping wet incremental inside the new isolated buffer — *not* a fix for a nonexistent wet re-mix.
**Blocking prerequisite:** incremental `.load` source-over of overlapping new dabs builds up *past* the per-frame boundary, which can silently convert Glaze into **frame-rate-dependent Build-up** (slow vs fast stroke over the same path saturating differently). This must be solved **before this step ships**, without a mode branch: Glaze uses a **coverage-saturating blend state** (cap at 1, the §3.6 Glaze PSO) so self-overlap is flat independent of dabs-per-frame; Build-up uses the accumulating PSO. **Prove this offline** (a self-crossing 30% stroke at varied simulated frame cadences must produce identical flat saturation) before any device test. *Rollback:* revert to clear-and-redraw (differs only in loadAction + submitted dab range + blend state).

**Step 3 — `belowTex` + reservoir + fold the wet path in. The marquee rework.**
Blit layer→`belowTex` at `touchesBegan`. Allocate `sabPrev`/`reservoirBuf` + select the 16F SAB only when `wetness>0`. Move the KM mix from `wetStampFragment` into `unifiedDabFragment`, sampling `belowTex`+`sabPrev` instead of fetching `dst [[color(0)]]` (a real shader rewrite, not "verbatim reuse"). Replace the CPU `wetLoad`/`sampleLayerColor`/`kmMixCPU` reservoir with Pass A (after benchmarking the per-frame coalesced-readback alternative, §3.3). Specify the linear↔sRGB-premultiplied composite conversion (§3.2). Record dab-batch boundaries so commit/undo replay the exact frame-granular evolution (§3.5). Delete `applyWetStamps`/`wetStampPSO`/`makeWetStampPSO`/`wetOrderingPerStamp` (after the A/B validates frame-granular). Now **one path** runs dry and wet. *Validate offline:* `wetness=0` ≡ Step 2 output (the identity oracle); blue-through-yellow→green matches the `km_tune_final` reference; **PSO compiles on Simulator** (the regression fix). Device: re-run shipped wet-paint checks + the 600px-airbrush budget test on the oldest iPad. *Rollback:* retain the old wet path inactive behind a private build flag (not a user toggle) for one release, delete after device validation.

**Step 4 — Fold the eraser into the dab pass.**
`applyEraserStamps` (`CanvasRenderer.swift:404`) → `unifiedDabFragment` with a `destinationOut` blend-state PSO (§3.7). Removes the last framebuffer-fetch PSO; unifies undo. *Rollback:* revert to the standalone eraser pass.

**Step 5 — Fill the panels (now cheap, on the unified substrate).**
In img2img-leverage order: **Wet-Mix tuning first** (Charge/Attack/Pull/Dilution on the reservoir) → **stabilization/taper/shape** geometry (scatter/count/roundness/jitter) → **Color Dynamics** → **Grain behind the img2img-survival spike** → Wet Edges → curated blend modes. Each is a CPU stamp-gen addition or a Pass B term — no new pass, no path. Then the curated preset library UI (a dozen presets, not an on-device Brush Studio clone — per `feedback_ipad_dev_toggles`; full per-param editing stays a dev panel). *Rollback:* per-feature, data-gated (param at 0 = off).

**Retiring old paths:** after Step 3 — delete `wetStampPSO`/`makeWetStampPSO`/`applyWetStamps`/`wetStampFragment` + CPU smear helpers. After Step 4 — delete the standalone eraser pass. After Step 1 — delete `shapedStampFragment`. End state: **one dab PSO family** (Glaze-cap / Build-up / destination-out blend variants of one vertex+fragment) + one compositor; lasso/masked PSOs untouched.

---

## 7. Risks, open questions, and explicitly-rejected approaches

### Open questions (must be resolved during implementation, not asserted away)

1. **Glaze frame-rate-independence under incremental accumulation (BLOCKING, gates Step 2).** Prove offline that the Glaze coverage-saturating blend state yields identical flat self-overlap regardless of dabs-per-frame. This is the deepest landmine; it hides inside the best idea and touches the sacred canvas's defining behavior.
2. **Live-preview-vs-flatten determinism for wet (§3.5).** Commit/undo must replay the identical frame-granular batching; we record dab-batch boundaries per stroke to guarantee it. Verify preview == flattened on a wet drag.
3. **CPU-bake cost at high count/scatter (§2.4).** Benchmark early; vertex-stage escape hatch ready.
4. **Per-frame coalesced CPU readback vs full GPU reservoir (§3.3).** Measure the cheaper fix before building the reservoir + its per-frame dependency.
5. **Texturized-grain stability under pan/zoom/rotate (§3.4).** Document-space invariant should make it correct; verify before promising grain parity.
6. **Two "below perceptual threshold" inferences** — intra-frame wet feedback discarded; grain surviving img2img. Both are *inferences, not measurements*. Gate behind the `wetOrderingPerStamp` A/B and an img2img-survival spike respectively before deleting the serialized fallback / building the grain asset pipeline.

### Explicitly rejected (with reasons)

1. **The `wetEnabled` toggle / two-destination split (scratch-for-dry, direct-to-layer-for-wet).** The structural source of the forbidden mode; forecloses Glaze-on-wet; forces framebuffer fetch (Simulator-dead); duplicates color models. The SAB unifies the write target. *Central rejection.*
2. **Framebuffer fetch (`[[color(0)]]`) / `raster_order_groups` as the wet primitive.** Device-only (Simulator-dead); order-undefined for overlapping instanced dabs. Replaced by sampling immutable `belowTex`+`sabPrev`.
3. **Per-stamp CPU `getBytes` reservoir.** Main-thread per-stamp readback (named anti-pattern) that sees only committed paint. Replaced by Pass A.
4. **Unconditional rgba16Float SAB + full-document per-frame ping-pong.** Highest budget risk; doubles bandwidth; color-space hazard. Replaced by per-stroke format selection (8-bit dry / 16F wet) + dirty-bbox snapshot, with the composite conversion specified.
5. **2-D reservoir texture (256² ring).** Over-designed; Charge is 1-D along the stroke. Replaced by 1×K `reservoirBuf`.
6. **Glaze↔Build-up as an in-shader scalar blend-factor lerp.** Two genuinely different blend equations; the lerp is not numerically equivalent. Replaced by per-stroke PSO/blend-state selection (one shared shader). This is *not* a per-feature path.
7. **Per-dab GPU reservoir / wet draw calls as the default.** Per-frame serial barrier / N draw calls for sub-perceptual intra-frame feedback. One instanced draw/frame + one 1-D reservoir pass.
8. **Materials/metallic relighting, 3D grain / grain-follows-camera, full barrel-roll dynamics, the full blend-mode matrix, hover/cursor.** Rejected on *leverage* (img2img relights/resynthesizes; Pencil-Pro-gated) — *admitted* by the architecture (more textures/uniforms), fields stored for lossless import. Reachable ≠ built.
9. **Mixbox under CC-BY-NC as a shipping dependency** (Critical Constraint #4). The free spectral KM stays the shipping color engine, isolated behind one mix function; a licensed swap is one function.
10. **An on-device full Brush Studio IDE at launch.** Curated preset library + dev parameter panel (per `feedback_ipad_dev_toggles`). Engine parity ≠ UI parity — the descriptor exposes every parameter; the shipping UI curates.

### Why no alternative architecture is acceptable

The constraint set — no wet toggle, full parity, no per-feature path, Simulator-safe, sacred 8ms canvas — forecloses every design except *one isolated stroke buffer with bound-source reads*:
- in-place wet RMW → forecloses Glaze + is a per-feature path → rejected;
- separate wet/dry pipelines → the banned toggle → rejected;
- framebuffer-fetch/raster-order unified pass → Simulator-dead → rejected;
- per-dab-to-layer (no isolation) → forecloses Glaze + the opacity ceiling → rejected.

The chosen design is the only one that holds Glaze + Build-up + Wet Mix in one branch-free pass while staying Simulator-compilable and parity-open.

---

## Acceptance gates (when built)

1. `wetness=0` default pen pixel-identical to today (snapshot diff = 0).
2. 30% self-crossing stroke stays flat at *varied frame cadences* (Glaze frame-rate-independence).
3. Wet drag reproduces the current oil/smudge look via the GPU reservoir on **both Simulator and device**.
4. 600px wet airbrush holds <8ms on the oldest target iPad.

## Key files (current → unified)

- `ios/Packages/CanvasModule/Sources/CanvasModule/CanvasRenderer.swift` — passes/PSOs/shaders/KM tables: `renderStampsIntoScratch`, `flattenScratchIntoCanvas`, `applyEraserStamps`, `applyWetStamps`, `wetStampFragment`, `makeWetStampPSO`, `setupWetKMTables`.
- `ios/Packages/CanvasModule/Sources/CanvasModule/MetalCanvasView.swift` — `generateStampsForStroke`, CPU smear `applyNewWetStamps`/`sampleLayerColor`/`kmMixCPU`.
- `ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift` — `BrushConfig` → `BrushDescriptor`.
- `documents/plans/pro-brush-roadmap.md` — superseded; its phases map onto §6 steps.
