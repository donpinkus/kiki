import SwiftUI
import ResultModule

struct FloatingResultPanel: View {
    let resultState: ResultState
    let showingLineart: Bool
    let hasLineart: Bool
    let isGenerating: Bool
    let containerSize: CGSize
    let onClose: () -> Void
    let onToggleLineart: () -> Void
    let onSwapToCanvas: () -> Void
    var onInteraction: (() -> Void)? = nil

    @State private var position: CGPoint = .zero
    @State private var size: CGSize?
    @State private var dragOffset: CGSize = .zero
    @State private var resizeOffset: CGSize = .zero

    private let minSize = CGSize(width: 200, height: 160)

    private var resolvedSize: CGSize {
        size ?? CGSize(width: containerSize.width * 0.45, height: containerSize.height * 0.55)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — drag handle + close button
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        onInteraction?()
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        position.x += value.translation.width
                        position.y += value.translation.height
                        dragOffset = .zero
                    }
            )

            // Image
            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // Footer — lineart toggle + swap + resize handle
            footer
        }
        .frame(width: effectiveSize.width, height: effectiveSize.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .offset(x: position.x + dragOffset.width, y: position.y + dragOffset.height)
    }

    // MARK: - Image Content

    @ViewBuilder
    private var imageContent: some View {
        switch resultState {
        case .preview(let image), .streaming(let image, _):
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(4)

        case .generating(_, let previousImage):
            ZStack {
                if let prev = previousImage {
                    Image(uiImage: prev)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(0.5)
                }
                ProgressView()
                    .controlSize(.regular)
            }
            .padding(4)

        case .error(_, let previousImage):
            if let prev = previousImage {
                Image(uiImage: prev)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                Color(.systemGray6)
            }

        case .empty:
            Color(.systemGray6)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if hasLineart && !isGenerating {
                Button { if showingLineart { onToggleLineart() } } label: {
                    Text("Generated")
                        .font(.caption.weight(showingLineart ? .regular : .semibold))
                        .foregroundStyle(showingLineart ? .secondary : .primary)
                }
                .buttonStyle(.plain)

                Button { if !showingLineart { onToggleLineart() } } label: {
                    Text("Line art")
                        .font(.caption.weight(showingLineart ? .semibold : .regular))
                        .foregroundStyle(showingLineart ? .primary : .secondary)
                }
                .buttonStyle(.plain)

                if showingLineart {
                    Spacer()
                    Button(action: onSwapToCanvas) {
                        Text("Send to canvas")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }

            Spacer()

            // Resize handle
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            onInteraction?()
                            resizeOffset = value.translation
                        }
                        .onEnded { value in
                            let base = resolvedSize
                            size = CGSize(
                                width: max(minSize.width, base.width + value.translation.width),
                                height: max(minSize.height, base.height + value.translation.height)
                            )
                            resizeOffset = .zero
                        }
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Computed

    private var effectiveSize: CGSize {
        let maxWidth = containerSize.width * 0.8
        let maxHeight = containerSize.height * 0.8
        let base = resolvedSize
        return CGSize(
            width: min(maxWidth, max(minSize.width, base.width + resizeOffset.width)),
            height: min(maxHeight, max(minSize.height, base.height + resizeOffset.height))
        )
    }
}
