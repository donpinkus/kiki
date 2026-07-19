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

                Section("What should change?") {
                    TextField(
                        isRegion ? "e.g. make this wall red brick" : "e.g. make the sky sunset colors",
                        text: $coordinator.aiEditPrompt,
                        axis: .vertical
                    )
                    .lineLimit(3, reservesSpace: true)
                    .focused($promptFocused)
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
            .onAppear { promptFocused = true }
        }
        .presentationDetents([.medium])
    }
}
