# Plan: Debug ControlNet Comparison Mode

## Overview
Add a toggle that runs a second generation with controlnet strength=0 after the normal generation. A debug button (always visible, disabled until data is ready) opens a full-screen 2x2 grid modal showing: original sketch, lineart, generated image, and no-controlnet image.

---

## Architecture Decisions

**`compareWithoutControlNet` is a request-level flag, not a generation parameter.**
It lives on `GenerateRequest` / `ProviderRequest`, not on `AdvancedParameters`. It controls _how many_ generations to run, not _how_ a single generation runs. The toggle state lives on `AppCoordinator`.

**Debug button lives in ContentView, not ResultModule.**
ResultModule is a standalone SPM package focused on displaying generation results. Debug comparison is a main-app concern. The button overlays the result area from ContentView. No changes to ResultModule.

**Comparison data is bundled in structs at every layer.**
- Pipeline: `ComparisonBundle` (snapshot + lineart + CN=0 image) is optional on `Output`. Only populated when comparison mode is on. Keeps `Output` lean for normal usage.
- Coordinator: `ComparisonData` (all 4 images + CN strength label) is optional. Built by combining `output.image` + `output.comparisonBundle` + coordinator's CN strength. All-or-nothing — no partial state.

**Pipeline downloads all images. Non-critical downloads are best-effort.**
Main image download is required (throws on failure). Lineart and comparison image downloads catch errors and return nil — the primary generation never fails because of comparison mode. If any optional download fails, the whole `ComparisonBundle` is nil and the debug button stays disabled.

**Second workflow clones the already-configured first workflow.**
Don't rebuild from template via `getWorkflow()`. The first workflow already has the sketch filename, prompt, seed, and all parameters applied. Just `structuredClone()` it and override CN strength to 0.

**Second generation failure is non-fatal.**
If the first gen succeeds but the second fails, the backend logs the error, returns the first result normally without `comparisonImageUrl`. The user gets their generated image; comparison is just unavailable.

---

## Changes

### 1. Backend: Second generation when flag is set

**`backend/src/modules/providers/types.ts`:**
- Add `compareWithoutControlNet?: boolean` to `ProviderRequest`
- Add `comparisonImageUrl?: string` to `ProviderResponse`

**`backend/src/routes/generate.ts`:**
- Add `compareWithoutControlNet` to `generateBodySchema`: `{ type: 'boolean', nullable: true }`
- Add `compareWithoutControlNet?: boolean | null` to `GenerateBody` interface
- Pass `compareWithoutControlNet: compareWithoutControlNet ?? undefined` to `ProviderRequest`
- Include `comparisonImageUrl: result.comparisonImageUrl ?? null` in the success response

**`backend/src/modules/providers/comfyui.ts`:**

After the first generation completes (after line 104 where seed is extracted), add comparison logic:

```
if (request.compareWithoutControlNet) {
  try {
    const compWorkflow = structuredClone(workflow);  // clone configured workflow
    compWorkflow[CONTROLNET_APPLY_NODE_ID].inputs['strength'] = 0;
    // seed, sketch, prompt, all other params are already set from the first workflow
    const compPromptId = await this.submitPrompt(baseUrl, compWorkflow);
    const compOutputs = await this.pollForResult(baseUrl, compPromptId);
    const compSaveOutput = compOutputs[SAVE_IMAGE_NODE_ID]?.images?.[0];
    if (compSaveOutput) {
      comparisonImageUrl = `${baseUrl}/view?filename=...`;  // same URL pattern as main image
    }
  } catch (err) {
    console.warn('Comparison generation failed:', err);
    // Non-fatal: comparisonImageUrl stays undefined
  }
}
```

The try/catch ensures the comparison failure doesn't affect the primary result.

### 2. iOS NetworkModule: Update request/response models

**`AdvancedParameters.swift`:** No changes.

**`GenerateRequest.swift`:**
- Add `public let compareWithoutControlNet: Bool?` property
- Add to init with default `nil`
- Swift auto-synthesized Codable uses `encodeIfPresent` for optionals, so `nil` is omitted from JSON (not sent as `null`), keeping the payload clean

**`GenerateResponse.swift`:**
- Add `public let comparisonImageURL: URL?` property
- Add to init with default `nil`

**`APIClient.swift` (`decodeSuccessResponse`):**
- Add `let comparisonImageUrl: String?` to the private `APIResponse` struct
- Map: `let comparisonImageURL = decoded.comparisonImageUrl.flatMap { URL(string: $0) }`
- Pass through to `GenerateResponse` init

### 3. iOS GenerationPipeline: Expand Output, download comparison images

**`GenerationPipeline.swift`:**

Add new struct:
```swift
struct ComparisonBundle {
    let snapshotImage: UIImage     // canvas snapshot that was sent
    let lineartImage: UIImage      // ControlNet preprocessor output
    let noControlNetImage: UIImage // generation with CN strength=0
}
```

Expand `Input`:
- Add `let compareWithoutControlNet: Bool`

Expand `Output`:
- Add `let comparisonBundle: ComparisonBundle?` — nil when comparison mode is off or any download fails

In `run()`, update the downloading phase:
- Download the main image (required, throws on failure) — same as today
- If `input.compareWithoutControlNet` is true AND `response.lineartImageURL` and `response.comparisonImageURL` are both present:
  - Download both images sequentially (simple, fine for debug feature)
  - Both downloads are in a do/catch — if either fails, log and set `comparisonBundle = nil`
  - On success, build `ComparisonBundle` with `snapshot.image` (already in scope from preparing phase), lineart UIImage, and comparison UIImage
- Return `Output(image: mainImage, seed: seed, comparisonBundle: comparisonBundle)`

**Timeout note:** The `APIClient` has `timeoutIntervalForResource = 60s`. Two sequential backend generations could approach this limit on slow pods. The pipeline should set a longer timeout on the URLRequest when comparison mode is on: `urlRequest.timeoutInterval = 120` in APIClient, or pass a timeout parameter. (Implementation detail — simplest approach is increasing the default to 120s since the timeout is a max, not a delay.)

### 4. iOS AppCoordinator: Store comparison data, add toggle state

**`AppCoordinator.swift`:**

Add struct (can be nested or top-level in file):
```swift
struct ComparisonData {
    let snapshotImage: UIImage      // what was sent to the server
    let lineartImage: UIImage       // ControlNet preprocessor output
    let generatedImage: UIImage     // normal generation result
    let comparisonImage: UIImage    // generation with CN strength=0
    let controlNetStrength: Double  // the CN strength used for the normal gen (for label)
}
```

Add state properties:
```swift
var comparisonData: ComparisonData?
var compareWithoutControlNet = false

var hasComparisonData: Bool { comparisonData != nil }
```

In `generate()`:
- Clear `comparisonData = nil` at the start (line ~108, alongside `hasUnsavedChanges = false`)
- Pass `compareWithoutControlNet: compareWithoutControlNet` into `GenerationPipeline.Input`
- After pipeline returns output, if `output.comparisonBundle` is non-nil, build `ComparisonData`:
  ```swift
  if let bundle = output.comparisonBundle {
      comparisonData = ComparisonData(
          snapshotImage: bundle.snapshotImage,
          lineartImage: bundle.lineartImage,
          generatedImage: output.image,
          comparisonImage: bundle.noControlNetImage,
          controlNetStrength: advancedParameters.controlNetStrength
              ?? AdvancedParameters.defaultControlNetStrength
      )
  }
  ```

### 5. iOS AdvancedParametersPanel: Add toggle

**`AdvancedParametersPanel.swift`:**

Add a "Debug" section before the Reset section:
```swift
Section("Debug") {
    Toggle("Compare without ControlNet", isOn: $coordinator.compareWithoutControlNet)
}
```

Update the Reset button action to also reset: `coordinator.compareWithoutControlNet = false`
Update the Reset button `.disabled` condition to include: `&& !coordinator.compareWithoutControlNet`

### 6. iOS New View: DebugComparisonModal

**New file: `ios/Kiki/Views/DebugComparisonModal.swift`**

- Init takes `ComparisonData` and a dismiss action or uses `@Environment(\.dismiss)`
- Full-screen dark background (`.background(Color.black)`)
- 2x2 grid using `LazyVGrid(columns: [.flexible(), .flexible()], spacing: 12)`:
  - Top-left: "Original Sketch" — `data.snapshotImage`
  - Top-right: "Lineart" — `data.lineartImage`
  - Bottom-left: "Generated (CN: {strength})" — `data.generatedImage`
  - Bottom-right: "Generated (CN: 0)" — `data.comparisonImage`
- Each cell: `Image(uiImage:).resizable().aspectRatio(contentMode: .fit)` with a small caption label below in `.white` / `.secondary`
- X button (`xmark.circle.fill`) top-trailing, dismisses the modal
- Presented via `.fullScreenCover` from ContentView

### 7. iOS ContentView: Wire up debug button and modal

**`ContentView.swift`:**

Add state: `@State private var showDebugModal = false`

Overlay the debug button on the ResultView area (top-trailing of the VStack containing ResultView):
```swift
VStack(spacing: 0) {
    ResultView(state: coordinator.resultState)
        .overlay(alignment: .topTrailing) {
            Button { showDebugModal = true } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(!coordinator.hasComparisonData)
            .opacity(coordinator.hasComparisonData ? 1 : 0.4)
            .padding(12)
        }
    promptBar(promptText: $coordinator.promptText)
}
.fullScreenCover(isPresented: $showDebugModal) {
    if let data = coordinator.comparisonData {
        DebugComparisonModal(data: data)
    }
}
```

---

## Execution Order
1. Backend: types → comfyui adapter → route (step 1)
2. iOS NetworkModule: request, response, APIClient (step 2)
3. iOS GenerationPipeline (step 3)
4. iOS AppCoordinator (step 4)
5. iOS AdvancedParametersPanel (step 5)
6. iOS DebugComparisonModal (step 6)
7. iOS ContentView (step 7)

## Risks & Mitigations
- **Timeout:** Two sequential gens could approach the 60s iOS resource timeout on slow pods. Mitigation: increase `timeoutIntervalForResource` to 120s (it's a max, not a delay — no impact on normal usage).
- **Second gen failure:** Backend catches errors from comparison gen and returns primary result normally. iOS sees nil `comparisonImageURL` → no comparison bundle → debug button stays disabled.
- **Memory:** Four UIImages in ComparisonData. Each is ~1-2MB decoded. ~8MB total, acceptable on iPad.

## Notes
- Sequential backend execution means generation time roughly doubles when comparison is on. Acceptable for a debug feature.
- Same seed guaranteed: cloned from the first workflow's configured KSampler seed.
- Toggle defaults to off — zero impact on normal usage.
- All image downloading stays inside GenerationPipeline.
- No changes to ResultModule.
