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
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.displayImage != nil)
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
