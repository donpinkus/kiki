import SwiftUI
import SwiftData

struct GalleryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Query(sort: \Drawing.updatedAt, order: .reverse) private var drawings: [Drawing]
    @State private var isDeleteMode = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(drawings) { drawing in
                    GalleryTile(
                        drawing: drawing,
                        isDeleteMode: isDeleteMode,
                        onTap: {
                            if !isDeleteMode {
                                coordinator.openDrawing(drawing)
                            }
                        },
                        onDelete: {
                            coordinator.deleteDrawing(drawing)
                            if drawings.count <= 1 {
                                isDeleteMode = false
                            }
                        }
                    )
                    .onLongPressGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDeleteMode.toggle()
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 80)
        }
        .overlay(alignment: .top) {
            HStack {
                Text("Kiki")
                    .font(.largeTitle.weight(.bold))

                Spacer()

                Button {
                    isDeleteMode = false
                    coordinator.newDrawing()
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
        .onChange(of: drawings.count) { _, newCount in
            if newCount == 0 {
                isDeleteMode = false
            }
        }
    }
}

// MARK: - Gallery Tile

private struct GalleryTile: View {
    let drawing: Drawing
    let isDeleteMode: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Canvas thumbnail (left half)
                Color(.systemGray6)
                    .overlay {
                        if let thumbnail = drawing.canvasThumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "pencil.tip")
                                .font(.title2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .clipped()

                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1)

                // Generated image (right half)
                Color(.systemGray5)
                    .overlay {
                        if let generated = drawing.generatedImage {
                            Image(uiImage: generated)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "sparkles")
                                .font(.title2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .clipped()
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if isDeleteMode {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .offset(x: -6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }
}
