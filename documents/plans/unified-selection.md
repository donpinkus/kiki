# Unified Selection — one mask, two authors, three uses

**Status: BUILT 2026-07-19 (all three phases in one pass, per Donald's "whatever you think is best — proceed"). Sim-verified: persistence across tool switches, freehand∪auto union, freehand subtract, selection undo, Move begin/commit (identity), Clear. Offline-verified: rasterize/subtract/transform math (incl. holes), distance-field Expand. Device install pending (iPad went offline); SAM auto-mode still needs on-device confirmation.**

Donald's framing (2026-07-19): lasso and magic wand are both *tools for creating a mask*.
Once masked, you can (a) move/resize the masked content, (b) draw/paint restricted to it,
(c) re-edit the mask to add or subtract. This plan replaces the current mutual-exclusion
model (switching tools clears the other tool's selection) with a single Selection that both
tools author.

## UX

**One "Select" tool button** in the top bar (replaces the lasso + wand buttons). Panel:

| Control | Behavior |
|---|---|
| Mode: **Auto / Freehand** | Auto = SAM tap-to-select (today's wand). Freehand = drawn loop (today's lasso gesture). Both write into the same selection. |
| **Add / Remove** | Auto+Add: tap adds an object (or refines the object you tapped). Auto+Remove: negative SAM point carves the tapped object. Freehand+Add: loop region added as an object. Freehand+Remove: loop subtracts from whatever it overlaps (the manual scalpel). |
| Small / Auto / Large, Contiguous | Auto-mode only (SAM candidate pick + connected component), as shipped. |
| **Expand** | Moves from per-object to the WHOLE selection (union-level post-process, distance-field thresholded). "Grow/shrink my selection" uniformly, freehand regions included. |
| **Move** | Explicit: lifts selected pixels (existing Phase A extraction + pan/pinch/rotate), commit on confirm/exit. Selection mask survives the move. |
| **Clear Selection** | The only way a selection dies (besides select-undo). Shown under the Select button whenever a selection exists, any tool active. |

**Key rules:**
- **No "New Object" button.** Tap routing by hit-test: positive tap outside the selection →
  new object (auto-commits current); any tap inside an existing object → REOPEN that object
  and refine with the new point. Objects become invisible plumbing.
- **Selection persists across every tool switch.** The on-switch clearing (wand↔lasso mutual
  exclusion, 2026-07-19 v1) is deleted. Painting with brush/eraser clips as today.
- **Drawing a freehand loop no longer auto-floats the pixels.** Moving is a consumption of
  the mask (the Move button), not a side effect of authoring it. This is the one deliberate
  behavior change vs. the shipped lasso; it also makes SAM-selected objects movable
  (tap a tree → Move → drag), which lasso-only never offered.
- **Undo** while Select is active steps back selection edits (points, loops, reopens,
  subtractions); canvas undo unchanged otherwise.
- Ants + stripes visualization unchanged — already selection-source-agnostic.

## Approach

The shipped wand already IS the unified model underneath: a union of per-object 1024²
bitmaps feeding one clip path; ants/stripes/clip don't care who authored a bitmap (the sim
fake-mask shim proves arbitrary bitmaps compose). Work:

1. **Freehand as a bitmap author** — keep `MetalCanvasView` lasso touch capture + dashed
   preview; on finish, rasterize the closed loop into a 1024² bitmap (CGContext, even-odd,
   the documented Y-flip) → `SelectionController.addFreehand(mask, mode)`. Remove mode:
   bake subtraction into overlapping objects' bitmaps. Extract-on-finish stops firing.
2. **Reopen-on-tap** — hit-test the tap pixel against per-object bitmaps. Reopening an auto
   object re-decodes from its stored points (re-encode first if the canvas version moved —
   per-object points are already stored, so this is safe).
3. **Union-level Expand** — expansion no longer baked into object bitmaps at commit; it's a
   post-union distance-field threshold (cache the union field; recompute on any selection
   change). All derivation stays on the off-main coalesced path (`scheduleRefresh`).
4. **Move** — union path → `CanvasRenderer.extractSelection` (needs an even-odd fill-rule
   fix for multi-subpath rasterization) → existing `LassoSelectionView` gestures → existing
   commit. Extraction must use the DISPLAYED union (incl. Expand).
5. **Tool plumbing** — `DrawingTool`/`ToolState`: `.lasso` + `.magicWand` → `.select`;
   delete the coordinator mutual-exclusion clearing; unify undo intercept; one Clear button;
   update DevAutomation actions (`wandTap`/`wandFake`/`lasso`) so sim automation keeps working.
6. Rename `MagicWandController` → `SelectionController` (typealias for transition).

## Phasing (each shippable + testable alone)

1. **Persistence + composition** — no on-switch clearing; freehand loop → selection object;
   unified Clear. Both toolbar buttons remain, feeding one selection. Kills the data-loss
   trap; delivers the hybrid wand+lasso workflow.
2. **One Select tool** — merged button, panel modes, reopen-on-tap (drop New Object),
   union-level Expand.
3. **Move** — explicit transform of selected content via the union path.

## Risks / open points

- Phase 3 changes lasso muscle memory (loop no longer auto-floats). Deliberate, per the
  design framing; revisit if it tests badly.
- Selection undo across two author types is bookkeeping (an edit-op stack on the
  controller), not architecture — but design the op list before coding.
- Freehand Remove against a reopened auto object: subtraction bakes into the bitmap; the
  object's SAM points no longer fully describe it. Rule: a baked-subtracted object reopens
  as a FREEHAND object (points discarded) — predictable, avoids resurrecting carved areas
  on the next decode.
- Sim: SAM decode still broken in the iOS simulator (all-zero masks; see CanvasModule
  CLAUDE.md) — phase 1/2 testing uses fake-mask + freehand paths, device for auto mode.
