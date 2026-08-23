import CanvasModule
import SwiftUI

/// The Extract screen: the GENERATED image on the left — tap to select with
/// SAM, refine with Add/Remove points (same interaction as the canvas Select
/// tool), then "Lift to 3D". The right pane lists lifts with a measured ETA;
/// lifts keep running if the screen is closed (they auto-save into Objects).
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
                VStack(spacing: 10) {
                    selectionControls
                    imagePane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.bottom, 12)
                Divider()
                liftsPane
                    .frame(width: 340)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Selection controls (Add/Remove refinement + confirm)

    @ViewBuilder private var selectionControls: some View {
        @Bindable var controller = controller
        HStack(spacing: 12) {
            Picker("Mode", selection: $controller.pointMode) {
                Label("Add", systemImage: "plus.circle")
                    .tag(ExtractController.PointMode.add)
                Label("Remove", systemImage: "minus.circle")
                    .tag(ExtractController.PointMode.remove)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button {
                controller.undoPoint()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(controller.selectionPoints.isEmpty)

            Button("Clear") {
                controller.clearSelection()
            }
            .disabled(controller.selectionPoints.isEmpty)

            Spacer()

            Button {
                withAnimation(.spring(duration: 0.3)) {
                    controller.liftCurrentSelection()
                }
            } label: {
                Label("Lift to 3D", systemImage: "cube")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.hasSelection)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Left: tappable image + selection overlay

    private var imagePane: some View {
        GeometryReader { geo in
            let fitted = fittedRect(image: controller.sourceImage.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(uiImage: controller.sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Current selection contour (normalized loops → fitted rect).
                if !controller.selectionLoops.isEmpty {
                    selectionShape(in: fitted)
                        .fill(Color.accentColor.opacity(0.22), style: FillStyle(eoFill: true))
                    selectionShape(in: fitted)
                        .stroke(Color.accentColor, lineWidth: 2)
                }

                // Refinement points: green = add, red = remove.
                ForEach(Array(controller.selectionPoints.enumerated()), id: \.offset) { _, p in
                    Circle()
                        .fill(p.positive ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .position(
                            x: fitted.minX + p.u * fitted.width,
                            y: fitted.minY + p.v * fitted.height
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
        .padding(.horizontal, 12)
    }

    /// The selection contour as a SwiftUI Shape path scaled into `fitted`.
    private func selectionShape(in fitted: CGRect) -> Path {
        var path = Path()
        for loop in controller.selectionLoops {
            guard let first = loop.first else { continue }
            path.move(to: point(first, in: fitted))
            for p in loop.dropFirst() {
                path.addLine(to: point(p, in: fitted))
            }
            path.closeSubpath()
        }
        return path
    }

    private func point(_ normalized: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(
            x: fitted.minX + normalized.x * fitted.width,
            y: fitted.minY + normalized.y * fitted.height
        )
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
                    Text("Tap anything in the image — a character, a house, an island. Add more taps to grow the selection, or use Remove to carve it, then Lift to 3D.")
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
                if controller.hasActiveLifts {
                    Text("You can close this screen and keep drawing — finished lifts land in your Objects.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func liftCard(_ item: ExtractController.ExtractItem) -> some View {
        VStack(spacing: 8) {
            if item.state == .lifting || item.state == .failed {
                HStack(spacing: 10) {
                    Image(uiImage: item.cutout)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            } else if item.glb != nil {
                // Live, slowly-spinning 3D viewer — unmistakably a 3D object
                // now. Drag to orbit, pinch to zoom (SceneKit camera control).
                Model3DView(meshData: item.glb, autoRotate: true)
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            switch item.state {
            case .lifting:
                // Determinate ETA from the measured median of recent lifts
                // (self-tuning; caps at 95% until the result actually lands).
                TimelineView(.periodic(from: item.liftStartedAt, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(item.liftStartedAt)
                    let eta = Double(ExtractController.estimatedLiftMs) / 1000
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: min(elapsed / max(eta, 1), 0.95))
                        Text("Lifting to 3D — \(ExtractController.estimatedLiftText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
