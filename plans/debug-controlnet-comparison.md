# Plan: Debug ControlNet Comparison Mode

## Overview
Add a toggle that runs a second generation with controlnet strength=0 after the normal generation. A debug button (always visible, disabled until results ready) opens a full-screen 2x2 grid modal showing: original sketch, lineart, generated image, and no-controlnet image.

---

## Changes

### 1. Backend: Add `compareWithoutControlNet` parameter and second image URL

**Files:**
- `backend/src/routes/generate.ts` — Add `compareWithoutControlNet: boolean` to request schema. Add `comparisonImageUrl` to response.
- `backend/src/modules/providers/types.ts` — Add `compareWithoutControlNet` to `ProviderRequest`. Add `comparisonImageUrl` to `ProviderResponse`.
- `backend/src/modules/providers/comfyui.ts` — When `compareWithoutControlNet` is true, after the first generation completes, run a second workflow with identical parameters except `controlNetStrength=0`. Return both image URLs.

**Behavior:**
- First generation runs normally (with current controlnet strength).
- After it completes, if `compareWithoutControlNet=true`, clone the workflow, set node `111:85` strength to `0`, reuse the same uploaded sketch (already on the pod), and submit a second prompt.
- Poll the second prompt to completion.
- Return both `imageUrl` (normal) and `comparisonImageUrl` (no controlnet) in the response.
- Same seed is used for both generations for a fair comparison.

### 2. iOS NetworkModule: Update request/response models

**Files:**
- `ios/Packages/NetworkModule/Sources/NetworkModule/GenerateRequest.swift` — Add `compareWithoutControlNet: Bool?` to `AdvancedParameters`.
- `ios/Packages/NetworkModule/Sources/NetworkModule/GenerateResponse.swift` — Add `comparisonImageUrl: String?` to `GenerateResponse`.

### 3. iOS AdvancedParametersPanel: Add toggle

**File:** `ios/Kiki/Views/AdvancedParametersPanel.swift`

Add a new section "Debug" at the bottom of the panel with a toggle: "Compare without ControlNet". This sets `advancedParameters.compareWithoutControlNet = true`.

### 4. iOS AppCoordinator: Download comparison image

**File:** `ios/Kiki/App/AppCoordinator.swift`

- Add `comparisonImage: UIImage?` property.
- After a successful generation, if `comparisonImageUrl` is present in the response, download it and store it.
- Add `hasComparisonData: Bool` computed property (true when we have all 4 images: snapshot, lineart, generated, comparison).
- Store `lastInputImage` (original sketch snapshot) and `lastLineartImage` (downloaded from `lineartImageUrl`) alongside the existing `lastSuccessfulImage`.

### 5. iOS ResultModule: Add debug button

**File:** `ios/Packages/ResultModule/Sources/ResultModule/ResultView.swift`

- Add a small debug button (e.g., magnifying glass or grid icon) positioned above the generated image, top-right corner.
- Button is always visible but disabled (`opacity(0.4)`) until `hasComparisonData` is true.
- Tapping the button triggers a callback/action to present the debug modal.

Since ResultModule shouldn't depend on AppCoordinator, the button action and disabled state will be passed in as parameters (closure + bool).

### 6. iOS New View: DebugComparisonModal

**File:** `ios/Kiki/Views/DebugComparisonModal.swift` (new file)

- Full-screen modal overlay (`.fullScreenCover`).
- 2x2 grid of images with labels:
  - Top-left: "Original Sketch" — the canvas snapshot
  - Top-right: "Lineart" — the preprocessed lineart
  - Bottom-left: "Generated (CN: {strength})" — normal output with controlnet
  - Bottom-right: "Generated (CN: 0)" — output without controlnet
- Each image is resizable, aspect-fit.
- Tap anywhere or X button to dismiss.
- Presented from ContentView, triggered by the debug button action.

### 7. Wire it up in ContentView

**File:** `ios/Kiki/Views/ContentView.swift`

- Add `@State var showDebugModal = false`.
- Pass `showDebugModal` binding and `coordinator.hasComparisonData` to ResultView.
- Present `DebugComparisonModal` via `.fullScreenCover(isPresented: $showDebugModal)`.
- Pass the 4 images from coordinator to the modal.

---

## Execution Order
1. Backend types + provider logic (steps 1)
2. iOS network models (step 2)
3. iOS advanced parameters toggle (step 3)
4. iOS AppCoordinator state (step 4)
5. iOS ResultView debug button (step 5)
6. iOS DebugComparisonModal (step 6)
7. iOS ContentView wiring (step 7)

## Notes
- Sequential execution means generation time roughly doubles when comparison is enabled. This is acceptable for a debug/tuning feature.
- The same seed is forced for both runs to ensure a fair visual comparison.
- The comparison toggle defaults to off — no impact on normal usage.
- No new dependencies or packages needed.
