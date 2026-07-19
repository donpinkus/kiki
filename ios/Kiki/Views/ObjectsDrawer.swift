import SwiftData
import SwiftUI

/// The object library drawer: a grid of reusable cutouts saved from
/// selections ("Save Object" in the selection panel). Tapping one drops it
/// into the current drawing as a movable paste float (Place/Cancel bar
/// commits). Long-press to rename or delete.
struct ObjectsDrawer: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Query(sort: \SavedObject.createdAt, order: .reverse) private var objects: [SavedObject]
    @State private var renaming: SavedObject?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        Group {
            if objects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No objects yet")
                        .font(.headline)
                    Text("Select something with the selection tool, then tap Save Object — it'll appear here, ready to drop into any drawing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(objects) { object in
                            objectTile(object)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .alert("Rename object", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                renaming?.name = renameText
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func objectTile(_ object: SavedObject) -> some View {
        Button {
            coordinator.insertObject(object)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    // Checkerboard-ish neutral so transparent cutouts read.
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.tertiarySystemGroupedBackground))
                    if let image = object.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    }
                }
                .frame(width: 96, height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            coordinator.pinnedObjectID == object.id ? Color.accentColor : Color(.separator),
                            lineWidth: coordinator.pinnedObjectID == object.id ? 2 : 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if coordinator.pinnedObjectID == object.id {
                        Image(systemName: "pin.circle.fill")
                            .font(.body)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 6, y: -6)
                    }
                }
                Text(object.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Identity conditioning: the pinned object rides the generation
            // stream as an extra klein reference so its look/identity
            // persists across generations (Kiki's AI path only).
            if coordinator.pinnedObjectID == object.id {
                Button {
                    coordinator.unpinObject()
                } label: {
                    Label("Unpin from generation", systemImage: "pin.slash")
                }
            } else {
                Button {
                    coordinator.pinObject(object)
                } label: {
                    Label("Pin as generation reference", systemImage: "pin")
                }
            }
            Button {
                renameText = object.name
                renaming = object
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                coordinator.deleteObject(object)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
