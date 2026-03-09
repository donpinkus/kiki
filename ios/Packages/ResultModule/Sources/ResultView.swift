import SwiftUI

/// Displays the generated image result with loading and error states.
public struct ResultView: View {

    let viewModel: ResultViewModel

    public init(viewModel: ResultViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color(.systemGroupedBackground)

            if let image = viewModel.displayImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                emptyState
            }

            if viewModel.isLoading {
                loadingOverlay
            }

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isLoading)
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "paintbrush.pointed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Start drawing to generate")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.red.opacity(0.85), in: Capsule())
                .padding(.bottom, 24)
        }
    }

    private var loadingOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.ultraThinMaterial)
            .frame(width: 80, height: 80)
            .overlay {
                ProgressView()
                    .controlSize(.large)
            }
    }
}

#Preview {
    ResultView(viewModel: ResultViewModel())
}
