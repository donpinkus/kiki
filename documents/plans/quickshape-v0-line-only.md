# QuickShape v0 — Line-Only Implementation

**Status:** ✅ **Shipped + superseded.** Line-only v0 was the first ship (commits `2e52431`–`f74e715`). Subsequent shipping work added arc, ellipse, and circle on top — see the parent plan's "What's shipped" section for the current state. Polyline / triangle / rectangle remain unshipped pending corner detection.

**Parent plan:** [quickshape-stroke-recognizer.md](./quickshape-stroke-recognizer.md)

**Original goal:** Ship the smallest possible Procreate-style hold-to-snap feature — recognizing only **lines** — to validate the UX, hold detection, brush regeneration, and telemetry pipeline before investing in arc / ellipse / circle / triangle / rectangle / polyline branches.

This document was a **focused subset** of the parent plan, scoping the first ship. Kept for historical reference; refer to the parent plan for current shape coverage.

---

## Why line-only first

1. **Fastest path to "does the user feel it?"** Line is the most common cleanup users want; if hold-and-snap doesn't feel right with lines, it won't feel right with anything else.
2. **De-risks the hard parts before we invest in them.** Hold detection, preview overlay, brush-stamp regeneration, undo semantics — all 80% of the engineering work — are shape-agnostic. v0 validates them with the simplest possible classifier.
3. **TLS line fit is the only fitter that's already production-ready in §13.1 of the parent plan.** Halír–Flusser, Taubin, IStraw all have skeletons-with-comments. v0 has zero algorithm-verification risk.

---

## In scope (v0)

| Item | Source in parent plan |
|---|---|
| `StrokeRecognizerModule` Swift package | §2.3 |
| `RecognizerInputPoint` (position + timestamp only) | derived from §2.3 |
| Preprocessing: dedupe + arc-length resample + 5-tap smooth + endpoint hook trim (both ends) | §3 |
| Features: `pathLength`, `bboxDiagonal`, `sagittaRatio`, `totalAbsTurnDeg`, `lineNormRMS` | §4 |
| TLS line fit + endpoint projection | §5.1, §13.1 |
| Line-only scoring + abstain | §6.2 (line score formula), §6.5 (abstain rules) |
| Public `StrokeRecognizer` class | §2.3 |
| Hold detection state machine in `MetalCanvasView` | §2.4 |
| Preview overlay (`CAShapeLayer`) | §11.3 |
| Stamp regeneration in `CanvasRenderer.replaceScratchStamps` | §10 |
| Haptics (preview light, commit medium) | §11.5 |
| Single-undo semantics (free given existing snapshot model) | §11.7 |
| Kill switch (`quickShapeEnabled` flag) + settings toggle | §17.5 |
| Telemetry events for snap/abstain/undo | §17.2 |
| Unit tests against synthesized stroke gallery rows that apply to lines | §17.1 |

---

## Out of scope (v0 — deferred to v1)

| Item | Why deferred |
|---|---|
| Arc, ellipse, circle, triangle, rectangle, polyline | Each adds an algorithm to verify (Taubin, Halír–Flusser, polygon validators) and many seed thresholds to tune; v0 needs to ship first |
| Closed-stroke detection | No closed-shape branch in v0 — every stroke treated as open |
| Corner detection (ShortStraw + curve-aware) | Only needed for polylines and polygons |
| Self-intersection check | Only needed for closed shapes |
| Rounded-rect rejection | Only needed for closed shapes |
| Multi-candidate scoring + margin | Only one candidate (line) in v0 — no margin required |
| All competitive UX/timing TODOs from §18 of parent plan | Tune from v0 telemetry, not from competitor analysis |

---

## v0 simplifications vs parent plan

These shortcuts make v0 simpler than the v1 spec; reverse them when expanding:

1. **No `closureGate`.** Every stroke goes to the open-stroke branch.
2. **No closed-stroke branch at all.** Closed-looking strokes (e.g. circles) will simply abstain (line score is low because of high curvature).
3. **No abstain margin.** Only one candidate, so no margin check needed. Abstain still triggers on:
   - `pathLength < minPathLength`
   - resampled count < `minResampledPoints`
   - `lineScore < acceptScore`
   - `|totalSignedTurn| > overtraceTurnMax` (still useful — catches scribbles that happen to almost line up)
4. **No corner detection.** Lines don't have corners. If the stroke has corners, `lineNormRMS` and `sagittaRatio` will both be high → low line score → abstain.
5. **`stableCornerCount` field present in features but always 0.** The line-score formula still subtracts a corner penalty; it just always sees 0.
6. **No polyline competition.** L-shapes will abstain, not snap-to-polyline. That's an accepted v0 limitation.

---

## Phased execution (v0)

Implementation is being tracked in a GitHub issue (linked at top of issue body) and in the in-session task list.

### Phase 0a: Recognizer core (no UI integration) — **CURRENT FOCUS**
- [ ] Create `StrokeRecognizerModule` Swift package
- [ ] Core types
- [ ] TLS line fit + endpoint projection (port from §13.1)
- [ ] Preprocessing pipeline
- [ ] Line-only feature extraction
- [ ] Line-only scoring + abstain
- [ ] Public `StrokeRecognizer` class
- [ ] Unit tests
- [ ] `swift test` passes

### Phase 0b: Hold-detection + UI integration
- [ ] Recognizer feed in `MetalCanvasView.touchesMoved`
- [ ] Hold-detection state machine (Drawing → HoldStability → Preview → Commit)
- [ ] Preview overlay `CAShapeLayer`
- [ ] Hysteresis (`acceptScore − confidenceHysteresis` floor)
- [ ] Haptics (light on preview, medium on commit)

### Phase 0c: Brush integration
- [ ] Extract stamp-from-points logic to `StampGeneration.swift`
- [ ] `CanvasRenderer.replaceScratchStamps(_:)`
- [ ] Corrected-stamp generation along line geometry
- [ ] Manual verification of pressure preservation on tapered brush

### Phase 0d: Kill switch + telemetry + discoverability
- [ ] `quickShapeEnabled` settings toggle (default OFF for first internal build)
- [ ] PostHog events: `stroke.snap.committed`, `stroke.snap.abstained`, `stroke.snap.undone_within_2s`
- [ ] Replay log: per-Verdict feature snapshot
- [ ] First-stroke-of-session tooltip
- [ ] Internal beta testing (off-by-default flag flipped on for development builds)

### Phase 0e: Decide on v1 scope
After ~2 weeks of internal use of v0 line-only:
- Does the UX work?
- Are the seed values close?
- Is brush expressiveness preserved well enough?
- Telemetry: false-snap rate, abstain rate, time-to-commit distribution.
- If yes → start adding shapes per the v1 plan (likely circle/ellipse next, since closed shapes share zero infrastructure with lines and we need to validate the closed-stroke branch).
- If no → fix what's broken before adding complexity.

---

## v0 → v1 carry-forward

When v0 ships and we proceed to v1, **~90% of v0 carries forward unchanged.** The additions are:

1. Additional fitters: Taubin circle, Halír–Flusser ellipse, ShortStraw + curve-suppress corner detection, polygon validators.
2. Multi-candidate scoring with margin (parent plan §6.1–§6.5).
3. Closed-stroke branch (closure gate, ellipse/circle/triangle/rectangle routing).
4. Self-intersection + rounded-rect rejection.
5. Stamp regeneration extended to handle arcs, ellipses, polygons (v0 only handles lines).

Everything in Phases 0b, 0c, 0d (UI, brush integration, telemetry, kill switch) is shape-agnostic and stays as-is.

---

## Acceptance criteria for "v0 done"

- All tasks in Phase 0a–0d complete.
- Internal team can use the feature on dev builds and report it feels right.
- Telemetry shows < 5% false-snap rate on real Apple Pencil input over a 1-week internal-use window.
- No `recognizer_fault` events (deterministic crashes from the recognizer).
- Kill switch verified to fully disable the feature when flipped.

Once the bar is hit, write the v0 → v1 expansion task list and proceed.
