import CodenamePromiseCore
import SwiftUI

/// Drag photos into the order you want them in.
///
/// The first one is the entry's cover. Both the entry list and the collage read
/// `orderedMedia.first`, so this is how somebody decides which picture represents a day —
/// which is the reason to want this at all, and why the first row says so rather than leaving
/// people to infer it.
///
/// A list with drag handles rather than a draggable grid. Reordering a horizontal strip by
/// dragging is fiddly on a phone and easy to do by accident while scrolling it; a list is
/// unambiguous, and this is a thing people do rarely and deliberately.
struct MediaOrderSheet: View {
    let items: [MediaItem]
    let fileStore: MediaFileStore
    /// Called with the new order. Not called at all when nothing moved.
    let onSave: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var order: [MediaItem] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.id) { item in
                        row(item, isCover: item.id == order.first?.id)
                    }
                    .onMove { source, destination in
                        order.move(fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    Text("The first photo is the one shown with this entry in your list.")
                }
            }
            // Always editing: without it the handles are hidden behind an Edit button, and a
            // screen whose only purpose is reordering should not ask you to turn reordering on.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Photo order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if order.map(\.id) != items.map(\.id) {
                            onSave(order.map(\.id))
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { order = items }
        }
    }

    private func row(_ item: MediaItem, isCover: Bool) -> some View {
        HStack(spacing: 12) {
            OrderRowThumbnail(item: item, fileStore: fileStore)

            VStack(alignment: .leading, spacing: 2) {
                Text(isCover ? "Cover" : (item.kind == .video ? "Video" : "Photo"))
                    .font(.subheadline.weight(isCover ? .semibold : .regular))
                    .foregroundStyle(isCover ? Brand.violet : Brand.ink)
                Text(item.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// The small picture beside each row. Its own view so the async load has somewhere to live.
private struct OrderRowThumbnail: View {
    let item: MediaItem
    let fileStore: MediaFileStore

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: item.kind == .video ? "video.fill" : "photo")
                        .foregroundStyle(.secondary)
                }
                .task {
                    image = await ThumbnailCache.shared.thumbnail(for: item, fileStore: fileStore)
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
