import CodenamePromiseCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Everything attached to one entry, at a size you can actually look at.
///
/// The strip in the editor is a row of 80-point thumbnails you scrub sideways. That is fine as
/// a reminder of what is there and useless for anything else: you cannot tell a face from a
/// shoe at that size, the order is whatever fits in the two inches on screen, and reordering
/// lived behind a small "Reorder" button underneath, which is a thing people find by accident.
///
/// So: one screen, a grid, and every action on the tile itself. Drag to reorder, or use the
/// tile's menu — both, because dragging is quicker when it works and a menu is the one that
/// always does. The first tile is the cover, said in words rather than left to be inferred
/// from position.
struct AttachmentsView: View {
    let items: [MediaItem]
    let fileStore: MediaFileStore
    let onReorder: ([UUID]) -> Void
    let onRemove: (UUID) -> Void
    let onAdd: ([PhotosPickerItem]) -> Void
    let onOpen: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var order: [MediaItem] = []
    @State private var dragging: MediaItem?
    @State private var picking: [PhotosPickerItem] = []

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !failures.isEmpty { failureNotice }

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(order, id: \.id) { item in
                            tile(item)
                        }
                    }

                    Text(hint)
                        .font(Type.caption(12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(16)
            }
            .background(Brand.ground)
            .navigationTitle(summary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(
                        selection: $picking,
                        maxSelectionCount: nil,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .onAppear { order = items }
            .onChange(of: items.map(\.id)) { _, _ in order = items }
            .onChange(of: picking) { _, new in
                guard !new.isEmpty else { return }
                onAdd(new)
                picking = []
            }
        }
    }

    // MARK: - Pieces

    private func tile(_ item: MediaItem) -> some View {
        let isCover = item.id == order.first?.id

        return AttachmentTile(
            item: item,
            fileStore: fileStore,
            isCover: isCover,
            onOpen: {
                onOpen(item.id)
                dismiss()
            },
            menu: { menu(for: item, isCover: isCover) }
        )
        .opacity(dragging?.id == item.id ? 0.35 : 1)
        .onDrag {
            dragging = item
            // A provider is required. The id is enough to identify the tile and nothing
            // outside this screen consumes the drag.
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: ReorderDrop(
                item: item, order: $order, dragging: $dragging,
                onDrop: { commit() }
            )
        )
    }

    @ViewBuilder
    private func menu(for item: MediaItem, isCover: Bool) -> some View {
        if !isCover {
            Button {
                move(item, to: 0)
            } label: {
                Label("Make it the cover", systemImage: "star")
            }
        }
        Button {
            move(item, by: -1)
        } label: {
            Label("Move earlier", systemImage: "arrow.up.left")
        }
        .disabled(isCover)

        Button {
            move(item, by: 1)
        } label: {
            Label("Move later", systemImage: "arrow.down.right")
        }
        .disabled(item.id == order.last?.id)

        Divider()

        Button(role: .destructive) {
            onRemove(item.id)
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    /// Says which attachment did not upload and why.
    ///
    /// The tile gets a red border, which answers "which one" at a glance and nothing else.
    /// The reason only fits down here, and the reason is what tells somebody whether to retry
    /// or to give up on that one video.
    private var failureNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                failures.count == 1
                    ? "One attachment hasn't uploaded"
                    : "\(failures.count) attachments haven't uploaded",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(Type.label(14))
            .foregroundStyle(Brand.failed)

            ForEach(failures, id: \.id) { item in
                Text("\(item.kind == .video ? "Video" : "Photo") from \(item.createdAt.formatted(.dateTime.hour().minute())): \(item.uploadError ?? "no reason recorded")")
                    .font(Type.caption(12))
                    .foregroundStyle(.secondary)
            }

            Text("They're still on this device. Sending the entry again picks them up.")
                .font(Type.caption(12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.failed.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Words

    private var failures: [MediaItem] {
        order.filter { $0.uploadStatus == .failed }
    }

    private var summary: String {
        let photos = order.filter { $0.kind != .video }.count
        let videos = order.count - photos
        switch (photos, videos) {
        case (0, 0): return "Attachments"
        case (let p, 0): return p == 1 ? "1 photo" : "\(p) photos"
        case (0, let v): return v == 1 ? "1 video" : "\(v) videos"
        case (let p, let v):
            return "\(p) photo\(p == 1 ? "" : "s"), \(v) video\(v == 1 ? "" : "s")"
        }
    }

    private var hint: String {
        order.count <= 1
            ? "This one represents the entry in your list."
            : "Drag to reorder, or use the button on any tile. The first one represents this entry in your list."
    }

    // MARK: - Moving

    private func move(_ item: MediaItem, by offset: Int) {
        guard let index = order.firstIndex(where: { $0.id == item.id }) else { return }
        move(item, to: max(0, min(order.count - 1, index + offset)))
    }

    private func move(_ item: MediaItem, to destination: Int) {
        guard let index = order.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            let moved = order.remove(at: index)
            order.insert(moved, at: min(destination, order.count))
        }
        Haptics.picked()
        commit()
    }

    /// Saves the order as soon as it changes rather than behind a Done button.
    ///
    /// This screen has no Cancel, so there is no draft state to commit — what you see is what
    /// the entry is. Deferring the write would only create a window where the two disagree.
    private func commit() {
        guard order.map(\.id) != items.map(\.id) else { return }
        onReorder(order.map(\.id))
    }
}

/// Reorders as a tile is dragged over another, so the grid shows the result before the finger
/// lifts rather than rearranging afterwards.
private struct ReorderDrop: DropDelegate {
    let item: MediaItem
    @Binding var order: [MediaItem]
    @Binding var dragging: MediaItem?
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id,
              let from = order.firstIndex(where: { $0.id == dragging.id }),
              let to = order.firstIndex(where: { $0.id == item.id })
        else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        Haptics.landed()
        onDrop()
        return true
    }
}

/// One attachment, big enough to recognise.
///
/// The menu is a tapped button rather than a long press on the tile, because long press is
/// already how you pick a tile up to move it. Two gestures on one target means one of them
/// loses, and it is never the same one twice.
private struct AttachmentTile<Menu: View>: View {
    let item: MediaItem
    let fileStore: MediaFileStore
    let isCover: Bool
    let onOpen: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var image: UIImage?

    private var failed: Bool { item.uploadStatus == .failed }

    var body: some View {
        Button(action: onOpen) {
            // The rectangle is what has a size; the picture rides in an overlay on top of it.
            //
            // A `scaledToFill` image asked to fit a height reports its own natural width,
            // which is a couple of thousand points, and an adaptive grid sizing its columns
            // from that gives every tile a column wider than the phone. Overlays don't
            // participate in their parent's layout, so this way the cell decides and the
            // picture obeys.
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 108)
                .overlay { picture }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            failed ? Brand.failed : Brand.violet,
                            lineWidth: failed || isCover ? 2 : 0
                        )
                }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) { badge }
        .overlay(alignment: .topTrailing) {
            SwiftUI.Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.white, .black.opacity(0.45))
            }
            .padding(5)
        }
        .overlay(alignment: .bottomTrailing) {
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white, Brand.failed)
                .padding(6)
        } else if isCover {
            Text("Cover")
                .font(Type.caption(9.5, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Brand.violet, in: Capsule())
                .padding(6)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: item.kind == .video ? "video.fill" : "photo")
                .foregroundStyle(.secondary)
                .task {
                    image = await ThumbnailCache.shared.thumbnail(
                        for: item, fileStore: fileStore, maxPixel: 360
                    )
                }
        }
    }
}
