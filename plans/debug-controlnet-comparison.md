# Plan: Debug ControlNet Comparison Mode

## Overview
Add a toggle that runs a second generation with controlnet strength=0 after the normal generation. A debug button (always visible, disabled until data is ready) opens a full-screen 2x2 grid modal showing: original sketch, lineart, generated image, and no-controlnet image.

---

## Architecture Decisions

**`compareWithoutControlNet` is a request-level flag, not a generation parameter.**
It lives on `GenerateRequest` / `ProviderRequest`, not on `AdvancedParameters`. It controls _how many_ generations to run, not _how_ a single generation runs. The toggle state lives on `AppCoordinator`.

**Debug button lives in ContentView, not ResultModule.**
ResultModule is a standalone SPM package focused on displaying generation results. Debug comparison is a main-app concern. The button overlays the result area from ContentView.

**Comparison data is bundled in a struct.**
A `ComparisonData` struct on AppCoordinator holds all 4 images + the CN strength used. It's either complete or nil — no partial state. Cleared at the start of every generation.

**Pipeline downloads all images.**
The pipeline already handles the main image download. Extend it to also download lineart and comparison images, keeping all network I/O in one place. Return everything in `Output`.

---

## Changes

### 1. Backend: Second generation when flag is set

**`backend/src/modules/providers/types.ts`:**
- Add `compareWithoutControlNet?: boolean` to `ProviderRequest`
- Add `comparisonImageUrl?: string` to `ProviderResponse`

**`backend/src/routes/generate.ts`:**
- Add `compareWithoutControlNet` to `generateBodySchema` (boolean, nullable, optional)
- Add `compareWithoutControlNet` to `GenerateBody` interface
- Pass it through to `ProviderRequest`
- Include `comparisonImageUrl` in the success response

**`backend/src/modules/providers/comfyui.ts`:**
- After the first generation completes and produces results (after line 86), check `request.compareWithoutControlNet`
- If true: build a second workflow via `getWorkflow()`, apply the same parameters but force `controlNetStrength=0`, force the same seed (extracted from first run's KSampler output on line 104), set the same sketch filename and prompt
- Submit second prompt, poll for result
- Extract the second image URL and set it on the response as `comparisonImageUrl`
- The first gen's latency is still returned as `latencyMs`; total time includes both gens

### 2. iOS NetworkModule: Update request/response models

**`AdvancedParameters.swift`:** No changes.

**`GenerateRequest.swift`:**
- Add `let compareWithoutControlNet: Bool?` property (default nil in init)

**`GenerateResponse.swift`:**
- Add `let comparisonImageURL: URL?` property

**`APIClient.swift` (`decodeSuccessResponse`):**
- Add `comparisonImageUrl: String?` to the `APIResponse` struct
- Map it to `comparisonImageURL` via `URL(string:)`

### 3. iOS GenerationPipeline: Expand Output, download all images

**`GenerationPipeline.swift`:**

Expand `Input`:
- Add `let compareWithoutControlNet: Bool`

Expand `Output`:
- Add `let snapshotImage: UIImage` — the canvas snapshot (already captured as `snapshot.image`, just return it)
- Add `let lineartImage: UIImage?` — downloaded from `response.lineartImageURL`
- Add `let comparisonImage: UIImage?` — downloaded from `response.comparisonImageURL`

In `run()`, after downloading the main image:
- If `response.lineartImageURL` is present, download it and decode to UIImage
- If `response.comparisonImageURL` is present, download it and decode to UIImage
- Use `async let` to download all images concurrently for speed
- Return expanded `Output` with all images

Update request construction to pass through `compareWithoutControlNet` from input.

### 4. iOS AppCoordinator: Store comparison data, add toggle state

**`AppCoordinator.swift`:**

Add a bundled struct and state:
```swift
struct ComparisonData {
    let snapshotImage: UIImage      // what was sent to the server
    let lineartImage: UIImage       // ControlNet preprocessor output
    let generatedImage: UIImage     // normal generation result
    let comparisonImage: UIImage    // generation with CN strength=0
    let controlNetStrength: Double  // the CN strength used for the normal gen
}

var comparisonData: ComparisonData?
var compareWithoutControlNet = false
```

Add computed property:
```swift
var hasComparisonData: Bool { comparisonData != nil }
```

In `generate()`:
- Clear `comparisonData = nil` when starting a new generation
- Pass `compareWithoutControlNet` into `GenerationPipeline.Input`
- After pipeline returns, if output has `snapshotImage`, `lineartImage`, `comparisonImage` all present, build `ComparisonData` and store it
- `controlNetStrength` is read from `advancedParameters.controlNetStrength ?? AdvancedParameters.defaultControlNetStrength`

### 5. iOS AdvancedParametersPanel: Add toggle

**`AdvancedParametersPanel.swift`:**

Add a "Debug" section at the bottom (before the Reset button section):
```swift
Section("Debug") {
    Toggle("Compare without ControlNet", isOn: $coordinator.compareWithoutControlNet)
}
```

The Reset button should also reset `compareWithoutControlNet = false`.

### 6. iOS New View: DebugComparisonModal

**New file: `ios/Kiki/Views/DebugComparisonModal.swift`**

- Takes `ComparisonData` and a dismiss binding
- Full-screen dark background
- 2x2 grid using `LazyVGrid(columns: [.flexible(), .flexible()])`:
  - Top-left: "Original Sketch" — `data.snapshotImage`
  - Top-right: "Lineart" — `data.lineartImage`
  - Bottom-left: "Generated (CN: {strength})" — `data.generatedImage`
  - Bottom-right: "Generated (CN: 0)" — `data.comparisonImage`
- Each cell: `Image(uiImage:).resizable().aspectRatio(contentMode: .fit)` with label below
- X button top-right to dismiss
- Presented via `.fullScreenCover`

### 7. iOS ContentView: Wire up debug button and modal

**`ContentView.swift`:**

- Add `@State private var showDebugModal = false`
- Overlay a debug button (SF Symbol: `square.grid.2x2`) on the result pane area, top-trailing
- Button always visible but disabled + reduced opacity when `!coordinator.hasComparisonData`
- On tap: `showDebugModal = true`
- Present `DebugComparisonModal` via `.fullScreenCover(isPresented: $showDebugModal)` passing `coordinator.comparisonData!`

---

## Execution Order
1. Backend: types → comfyui adapter → route (step 1)
2. iOS NetworkModule: request, response, APIClient (step 2)
3. iOS GenerationPipeline (step 3)
4. iOS AppCoordinator (step 4)
5. iOS AdvancedParametersPanel (step 5)
6. iOS DebugComparisonModal (step 6)
7. iOS ContentView (step 7)

## Notes
- Sequential execution means generation time roughly doubles when comparison is on. Acceptable for a debug feature.
- Same seed forced for both runs (extracted from first run's KSampler output) for fair comparison.
- Toggle defaults to off — zero impact on normal usage, no extra bytes in request (nil omitted by Codable).
- All image downloading stays inside GenerationPipeline.
- `ComparisonData` is all-or-nothing — no partial state to manage.
- No changes to ResultModule at all.
