import SwiftUI

/// The Extract screen: the GENERATED image on the left (tap anything to lift
/// it into 3D via SAM + Hunyuan), the growing list of 3D lifts on the right,
/// each with "Save to Collection". Full-screen, entered from the drawing's
/// Extract button (next to Animate).
struct ExtractView: View {
    @Environment(AppCoordinator.self) private var coordinator
    let controller: ExtractController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    coordinator.closeExtract()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                Spacer()
                Text("Extract")
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            HStack(spacing: 0) {
                imagePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                liftsPane
                    .frame(width: 340)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Left: tappable image

    private var imagePane: some View {
        GeometryReader { geo in
            let fitted = fittedRect(image: controller.sourceImage.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(uiImage: controller.sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Tap markers (normalized → fitted-rect coords).
                ForEach(Array(controller.tapMarkers.enumerated()), id: \.offset) { _, p in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .position(
                            x: fitted.minX + p.x * fitted.width,
                            y: fitted.minY + p.y * fitted.height
                        )
                }

                if controller.isEncoding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing image…")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 14)
                }

                if let error = controller.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 14)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard fitted.contains(location) else { return }
                controller.handleTap(
                    u: (location.x - fitted.minX) / fitted.width,
                    v: (location.y - fitted.minY) / fitted.height
                )
            }
        }
        .padding(12)
    }

    private func fittedRect(image: CGSize, in container: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    // MARK: - Right: lifts

    private var liftsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3D Lifts")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            if controller.items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Tap anything in the image — a character, a house, an island — and it becomes a 3D model you can reuse anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(controller.items) { item in
                            liftCard(item)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func liftCard(_ item: ExtractController.ExtractItem) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(uiImage: item.cutout)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                if let thumb = item.meshThumb {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }

            switch item.state {
            case .lifting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lifting to 3D — a minute or two…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .failed:
                HStack {
                    Text("Lift failed.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { controller.retry(item) }
                        .font(.caption.weight(.semibold))
                }
            case .lifted:
                Button {
                    withAnimation(.spring(duration: 0.35)) {
                        controller.saveToCollection(item)
                    }
                } label: {
                    Label("Save to Collection", systemImage: "shippingbox")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.borderedProminent)
            case .saved:
                Label("Saved to your Objects", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(10)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
