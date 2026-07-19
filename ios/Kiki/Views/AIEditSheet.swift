import SwiftUI

/// AI Edit prompt sheet. One entry point for both scopes: an active lasso or
/// wand selection scopes the edit to that region (masked client-side —
/// pixels outside the selection are guaranteed untouched); no selection edits
/// the whole drawing. Raw model params live in the Advanced disclosure.
struct AIEditSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false
    @FocusState private var promptFocused: Bool

    private var isRegion: Bool { coordinator.canvasViewModel.hasSelectionForEdit }

    /// Rotating idea examples — scoped to the edit target. Shuffled once per
    /// sheet presentation so repeat visits teach different possibilities.
    @State private var exampleIdeas: [String] = []

    private static let regionIdeas = [
        "make this red brick",
        "fill this area with wildflowers",
        "add a person sitting here",
        "turn this into stained glass",
        "make this look like it's on fire",
        "cover this in ivy",
        "make this metallic and shiny",
        "replace this with a sleeping cat",
    ]
    private static let wholeIdeas = [
        "make the sky sunset colors",
        "redraw my shaky lines as clean smooth lines",
        "color this drawing in with soft watercolors",
        "add gentle shading and shadows",
        "make it nighttime with stars and moonlight",
        "turn this into a snowy winter scene",
        "add rain and reflections",
        "make everything look made of candy",
    ]

    var body: some View {
        @Bindable var coordinator = coordinator

        NavigationStack {
            Form {
                Section {
                    Label(
                        isRegion ? "Editing the selected area" : "Editing the whole drawing",
                        systemImage: isRegion ? "lasso" : "square.dashed"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } footer: {
                    Text(isRegion
                        ? "Only pixels inside your selection will change. The result lands on a new layer."
                        : "Select an area with the lasso or magic wand first to edit just that region.")
                }

                Section {
                    TextField(
                        isRegion ? "e.g. make this wall red brick" : "e.g. make the sky sunset colors",
                        text: $coordinator.aiEditPrompt,
                        axis: .vertical
                    )
                    .lineLimit(2, reservesSpace: true)
                    .focused($promptFocused)

                    // Education, not preset buttons: tapping an idea FILLS the
                    // prompt field so the user can tweak it — they learn the
                    // feature's range instead of memorizing canned actions.
                    ForEach(exampleIdeas, id: \.self) { idea in
                        Button {
                            coordinator.aiEditPrompt = idea
                            promptFocused = true
                        } label: {
                            Label(idea, systemImage: "lightbulb")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("What should change?")
                } footer: {
                    Text("Anything you can describe works: colors, textures, lighting, cleaning up lines, adding things…")
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        Stepper(value: $coordinator.aiEditSteps, in: 1...50) {
                            HStack {
                                Text("Steps")
                                Spacer()
                                Text("\(coordinator.aiEditSteps)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        HStack {
                            Text("Seed")
                            Spacer()
                            TextField("random", text: $coordinator.aiEditSeedText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                        }
                    }
                }
            }
            .navigationTitle("AI Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        coordinator.startAIEdit()
                        dismiss()
                    }
                    .disabled(coordinator.aiEditPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                // No keyboard auto-focus: the Ideas section is the education
                // surface and should be visible before the keyboard covers it.
                exampleIdeas = Array((isRegion ? Self.regionIdeas : Self.wholeIdeas).shuffled().prefix(3))
            }
        }
        .presentationDetents([.medium, .large])
    }
}
