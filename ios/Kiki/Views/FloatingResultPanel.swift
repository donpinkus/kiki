import SwiftUI
import UIKit
import ResultModule

struct FloatingResultPanel: View {
    let resultState: ResultState
    let canSwapStream: Bool
    let containerSize: CGSize
    let currentBrushColor: Color
    let onClose: () -> Void
    let onSwapStreamToCanvas: () -> Void
    let onColorPicked: ((Color) -> Void)?
    var onInteraction: (() -> Void)? = nil

    @State private var position: CGPoint = .zero
    @State private var size: CGSize?
    @State private var dragOffset: CGSize = .zero
    @State private var resizeOffset: CGSize = .zero

    @State private var isPickingColor = false
    @State private var pickLocation: CGPoint = .zero
    @State private var sampledColor: Color = .white
    @State private var holdTimer: Task<Void, Never>?
    @State private var dragStart: CGPoint = .zero

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

            // Footer
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
            pickableImage(image).padding(4)

        case .generating(_, let previousImage):
            ZStack {
                if let prev = previousImage {
                    pickableImage(prev).opacity(0.5)
                }
                ProgressView()
                    .controlSize(.regular)
            }
            .padding(4)

        case .provisioning:
            ZStack {
                Color(.systemGray6)
                ProgressView()
                    .controlSize(.regular)
            }

        case .error(_, let previousImage):
            if let prev = previousImage {
                pickableImage(prev).padding(4)
            } else {
                Color(.systemGray6)
            }

        case .empty:
            Color(.systemGray6)
        }
    }

    private func pickableImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay(
                GeometryReader { proxy in
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(eyedropperGesture(image: image, size: proxy.size))

                        if isPickingColor {
                            EyedropperRing(sampledColor: sampledColor, brushColor: currentBrushColor)
                                .position(x: pickLocation.x, y: pickLocation.y - EyedropperRing.offset)
                        }
                    }
                }
            )
    }

    // MARK: - Eyedropper

    private func eyedropperGesture(image: UIImage, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                if !isPickingColor {
                    if holdTimer == nil {
                        dragStart = drag.location
                        holdTimer = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            isPickingColor = true
                            updateSample(at: dragStart, image: image, size: size)
                        }
                    }
                    let dx = drag.location.x - dragStart.x
                    let dy = drag.location.y - dragStart.y
                    if dx * dx + dy * dy > 100 {
                        holdTimer?.cancel()
                        holdTimer = nil
                    }
                } else {
                    updateSample(at: drag.location, image: image, size: size)
                }
            }
            .onEnded { _ in
                holdTimer?.cancel()
                holdTimer = nil
                if isPickingColor {
                    onColorPicked?(sampledColor)
                    isPickingColor = false
                }
            }
    }

    private func updateSample(at location: CGPoint, image: UIImage, size: CGSize) {
        pickLocation = location
        let samplePoint = CGPoint(x: location.x, y: location.y - EyedropperRing.offset)
        if let color = EyedropperRing.sampleColor(from: image, at: samplePoint, in: size) {
            sampledColor = color
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if canSwapStream {
                Button(action: onSwapStreamToCanvas) {
                    Text("Send to canvas")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
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

// MARK: - Color Picker Ring
