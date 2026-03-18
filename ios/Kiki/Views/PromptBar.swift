import SwiftUI

struct PromptBar: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        HStack(spacing: 12) {
            TextField("Describe what you want…", text: $coordinator.promptText)
                .textFieldStyle(.plain)
                .font(.subheadline)

            Button {
                coordinator.generate()
            } label: {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        coordinator.canvasViewModel.isEmpty || coordinator.isGenerating
                            ? Color.accentColor.opacity(0.4)
                            : Color.accentColor,
                        in: Circle()
                    )
            }
            .disabled(coordinator.canvasViewModel.isEmpty || coordinator.isGenerating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
