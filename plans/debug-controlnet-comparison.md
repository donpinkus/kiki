# Plan: Debug ControlNet Comparison Mode

## Overview
Add a toggle that runs a second generation with controlnet strength=0 after the normal generation. A debug button (always visible, disabled until results ready) opens a full-screen 2x2 grid modal showing: original sketch, lineart, generated image, and no-controlnet image.

---

## Changes

### 1. Backend: Add `compareWithoutControlNet` parameter and second image URL

**Files:**
- `backend/src/routes/generate.ts` — Add `compareWithoutControlNet: boolean` to request schema. Add `comparisonImageUrl` to response.
- `backend/src/modules/providers/types.ts` — Add `compareWithoutControlNet` to `AdvancedParameters` interface. Add `comparisonImageUrl` to `ProviderResponse`.
- `backend/src/modules/providers/comfyui.ts` — When `compareWithoutControlNet` is true, after the first generation completes, run a second workflow with identical parameters except `controlNetStrength=0`. Return both image URLs.

**Behavior:**
- First generation runs normally (with current controlnet strength).
- After it completes, if `compareWithoutControlNet=true`, clone the workflow again via `structuredClone()`, set node `111:85` strength to `0`, reuse the same uploaded sketch filename (already on the pod), and submit a second prompt.
- Force the same seed from the first run's KSampler output (node `111:3`) into the second workflow for a fair comparison.
- Poll the second prompt to completion.
- Return both `imageUrl` (normal) and `comparisonImageUrl` (no controlnet) in the response.

### 2. iOS NetworkModule: Update request/response models

**Files:**
- `ios/Packages/NetworkModule/Sources/NetworkModule/AdvancedParameters.swift` — Add `compareWithoutControlNet: Bool?` property. Update `isDefault` computed property to include it. No slider default needed (it's a toggle, nil = off).
- `ios/Packages/NetworkModule/Sources/NetworkModule/GenerateResponse.swift` — Add `comparisonImageURL: URL?` (matching existing `imageURL`/`lineartImageURL` naming convention with `CodingKeys` mapping to `comparisonImageUrl`).

### 3. iOS AdvancedParametersPanel: Add toggle

**File:** `ios/Kiki/Views/AdvancedParametersPanel.swift`

Add a new "Debug" section at the bottom of the panel with a toggle: "Compare without ControlNet". Binds to `coordinator.advancedParameters.compareWithoutControlNet`. When toggled on, sets to `true`; when off, sets to `nil` (keeping request compact when disabled).

### 4. iOS GenerationPipeline: Expand Output to include comparison image

**File:** `ios/Kiki/App/GenerationPipeline.swift`

- Add `comparisonImage: UIImage?` to `GenerationPipeline.Output`.
- Add `inputSnapshotImage: UIImage` to `Output` — the canvas snapshot captured in the preparing phase (already exists as a local variable, just needs to be returned).
- Add `lineartImage: UIImage?` to `Output` — downloaded from `response.lineartImageURL` if present.
- After downloading the main generated image, if `response.comparisonImageURL` is present, download it too (still within the downloading phase).
- If `response.lineartImageURL` is present, download the lineart image as well.
- This keeps all image fetching inside the pipeline where it belongs.

### 5. iOS AppCoordinator: Store comparison data

**File:** `ios/Kiki/App/AppCoordinator.swift`

- Add properties: `comparisonImage: UIImage?`, `lastInputSnapshot: UIImage?`, `lastLineartImage: UIImage?`.
- Add `hasComparisonData: Bool` computed property — true when all 4 images are non-nil (lastInputSnapshot, lastLineartImage, lastSuccessfulImage, comparisonImage).
- After pipeline returns output, store `output.inputSnapshotImage`, `output.lineartImage`, `output.comparisonImage` alongside the existing `lastSuccessfulImage`.
- Clear `comparisonImage` (and lineart/snapshot) when a new generation starts without the comparison toggle.

### 6. iOS ResultView: Add debug button

**File:** `ios/Packages/ResultModule/Sources/ResultModule/ResultView.swift`

- Add a small debug button (grid icon via `SF Symbols: square.grid.2x2`) positioned top-trailing of the result image area.
- Button always visible but disabled + reduced opacity until comparison data is available.
- Since ResultModule has no dependency on AppCoordinator, pass in: `debugEnabled: Bool` and `onDebugTap: () -> Void` as parameters to `ResultView`.

### 7. iOS New View: DebugComparisonModal

**File:** `ios/Kiki/Views/DebugComparisonModal.swift` (new file)

- Full-screen modal (`.fullScreenCover`).
- 2x2 grid with labels:
  - Top-left: "Original Sketch" — `lastInputSnapshot`
  - Top-right: "Lineart" — `lastLineartImage`
  - Bottom-left: "Generated (CN: {strength})" — `lastSuccessfulImage`
  - Bottom-right: "Generated (CN: 0)" — `comparisonImage`
- Each cell: `Image(uiImage:).resizable().aspectRatio(contentMode: .fit)` with a label below.
- X button in top-right corner to dismiss.
- Dark background.

### 8. Wire it up in ContentView

**File:** `ios/Kiki/Views/ContentView.swift`

- Add `@State var showDebugModal = false`.
- Pass `debugEnabled: coordinator.hasComparisonData` and `onDebugTap: { showDebugModal = true }` to `ResultView`.
- Present `DebugComparisonModal` via `.fullScreenCover(isPresented: $showDebugModal)`, passing the 4 images from coordinator.

---

## Execution Order
1. Backend types + provider logic (step 1)
2. iOS network models (step 2)
3. iOS advanced parameters toggle (step 3)
4. iOS GenerationPipeline output expansion (step 4)
5. iOS AppCoordinator state (step 5)
6. iOS ResultView debug button (step 6)
7. iOS DebugComparisonModal (step 7)
8. iOS ContentView wiring (step 8)

## Notes
- Sequential execution means generation time roughly doubles when comparison is enabled. This is acceptable for a debug/tuning feature.
- The same seed is forced for both runs (extracted from first run's KSampler output) to ensure a fair visual comparison.
- The comparison toggle defaults to off (nil) — no impact on normal usage, no extra bytes in request.
- No new dependencies or packages needed.
- All image downloading stays inside `GenerationPipeline` (not AppCoordinator), following the refactored architecture.
- The `inputSnapshotImage` is the JPEG-encoded canvas snapshot already captured in the pipeline's preparing phase — we just return it in the output instead of discarding it.
