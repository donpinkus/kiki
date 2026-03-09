import SwiftUI

/// Displays the generated image result with support for loading, error, and empty states.
///
/// The view never shows a blank pane after the first successful image.
/// Errors are shown as non-blocking toasts while preserving the last image.
public struct ResultView: View {

    // MARK: - Properties

    private let state: ResultState

    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastDismissTask: Task<Void, Never>?

    // MARK: - Lifecycle

    public init(state: ResultState = .empty) {
        self.state = state
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            Color(.systemGray6)
                .ignoresSafeArea()

            switch state {
            case .empty:
                emptyView

            case .generating(let previousURL):
                generatingView(previousURL: previousURL)

            case .preview(let imageURL):
                imageContent(url: imageURL)

            case .error(let message, let previousURL):
                errorView(message: message, previousURL: previousURL)
            }

            if showToast {
                toastOverlay
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showToast)
    }

    // MARK: - Subviews

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Start drawing to see your image come to life.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func generatingView(previousURL: URL?) -> some View {
        ZStack {
            if let url = previousURL {
                imageContent(url: url)
            } else {
                placeholderBackground
            }

            shimmerOverlay

            VStack {
                Spacer()
                generatingLabel
                    .padding(.bottom, 32)
            }
        }
    }

    private func errorView(message: String, previousURL: URL?) -> some View {
        ZStack {
            if let url = previousURL {
                imageContent(url: url)
            } else {
                emptyView
            }
        }
        .onAppear {
            showToastMessage(message)
        }
    }

    private func imageContent(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)

            case .failure:
                placeholderBackground
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Unable to load image")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

            case .empty:
                placeholderBackground
                    .overlay {
                        ProgressView()
                    }

            @unknown default:
                placeholderBackground
            }
        }
    }

    private var placeholderBackground: some View {
        Color(.systemGray5)
    }

    private var shimmerOverlay: some View {
        ShimmerView()
            .allowsHitTesting(false)
    }

    private var generatingLabel: some View {
        Text("Creating preview...")
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var toastOverlay: some View {
        VStack {
            Spacer()

            Text(toastMessage)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .onTapGesture {
                    dismissToast()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Private

    private func showToastMessage(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        withAnimation {
            showToast = true
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            dismissToast()
        }
    }

    private func dismissToast() {
        toastDismissTask?.cancel()
        withAnimation {
            showToast = false
        }
    }
}

// MARK: - ShimmerView

private struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [
                    .clear,
                    .white.opacity(0.15),
                    .white.opacity(0.3),
                    .white.opacity(0.15),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geometry.size.width * 0.6)
            .offset(x: phase * geometry.size.width)
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1.5
                }
            }
        }
        .clipped()
    }
}

// MARK: - Preview

#Preview("Empty") {
    ResultView(state: .empty)
}

#Preview("Generating") {
    ResultView(state: .generating(previousImageURL: nil))
}

#Preview("Preview") {
    ResultView(state: .preview(imageURL: URL(string: "https://picsum.photos/512")!))
}

#Preview("Error") {
    ResultView(state: .error(
        message: "Connection lost. Retrying...",
        previousImageURL: URL(string: "https://picsum.photos/512")!
    ))
}
