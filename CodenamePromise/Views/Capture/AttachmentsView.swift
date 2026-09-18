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
    @State private var selected: Set<UUID> = []
    @State private var selecting = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !failures.isEmpty { failureNotice }
                    if !staying.isEmpty { stayingNotice }

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(order, id: \.id) { item in
                            tile(item)
                        }
                    }

                    if selecting { selectionActions }

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
                    Button(selecting ? "Cancel" : "Done") {
                        if selecting { endSelecting() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if selecting {
                        Button(selected.count == order.count ? "None" : "All") {
                            selected = selected.count == order.count
                                ? [] : Set(order.map(\.id))
                        }
                    } else if order.count > 1 {
                        Button("Select") {
                            withAnimation(.easeOut(duration: 0.15)) { selecting = true }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !selecting {
                        PhotosPicker(
                            selection: $picking,
                            maxSelectionCount: nil,
                            matching: .any(of: [.images, .videos])
                        ) {
                            Label("Add", systemImage: "plus")
                        }
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
            selecting: selecting,
            isSelected: selected.contains(item.id),
            onOpen: {
                if selecting {
                    toggle(item.id)
                } else {
                    onOpen(item.id)
                    dismiss()
                }
            },
            menu: { menu(for: item, isCover: isCover) }
        )
        .opacity(isMoving(item) ? 0.35 : 1)
        .onDrag {
            dragging = item
            // Dragging one of a selection carries the whole selection. Picking up a tile
            // that is *not* selected is the ordinary one-tile drag, and ends the selection
            // rather than silently dragging something you did not pick up.
            if selecting, !selected.contains(item.id) {
                selected = [item.id]
            }
            // A provider is required. The id is enough to identify the tile and nothing
            // outside this screen consumes the drag.
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: ReorderDrop(
                item: item, order: $order, dragging: $dragging,
                moving: { movingIds },
                onDrop: { commit() }
            )
        )
    }

    /// Every tile this drag is carrying: the whole selection, or just the one picked up.
    private var movingIds: [UUID] {
        guard let dragging else { return [] }
        if selecting, selected.contains(dragging.id) {
            return order.map(\.id).filter { selected.contains($0) }
        }
        return [dragging.id]
    }

    private func isMoving(_ item: MediaItem) -> Bool {
        dragging != nil && movingIds.contains(item.id)
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        Haptics.picked()
    }

    private func endSelecting() {
        withAnimation(.easeOut(duration: 0.15)) {
            selecting = false
            selected = []
        }
    }

    /// What you can do with a selection, spelled out.
    ///
    /// Dragging a group is the quick way and needs a steady hand on a phone; these are the
    /// ones that always work, and "to the front" is the only reordering most people want —
    /// it is how you choose the picture that represents the day.
    private var selectionActions: some View {
        HStack(spacing: 10) {
            Button {
                moveSelection(toFront: true)
            } label: {
                Label("To the front", systemImage: "arrow.up.to.line")
            }
            Button {
                moveSelection(toFront: false)
            } label: {
                Label("To the end", systemImage: "arrow.down.to.line")
            }
            Spacer()
            Button(role: .destructive) {
                for id in selected { onRemove(id) }
                endSelecting()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .font(Type.caption(13, .medium))
        .disabled(selected.isEmpty)
        .opacity(selected.isEmpty ? 0.45 : 1)
        .padding(.horizontal, 2)
    }

    /// Moves the selection as a block, keeping the order they are already in.
    private func moveSelection(toFront: Bool) {
        let picked = order.filter { selected.contains($0.id) }
        let rest = order.filter { !selected.contains($0.id) }
        guard !picked.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            order = toFront ? picked + rest : rest + picked
        }
        Haptics.landed()
        commit()
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

    /// Says plainly that a video is staying here, and why.
    private var stayingNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                staying.count == 1 ? "One video stays on this phone" : "\(staying.count) videos stay on this phone",
                systemImage: "iphone"
            )
            .font(Type.label(14))
            .foregroundStyle(Brand.ink)

            Text(staying.count == 1
                 ? "It is too long to send anywhere without ruining it. It is still in this entry, and still on your phone. Everything else in this entry sends normally."
                 : "They are too long to send anywhere without ruining them. They are still in this entry, and still on your phone. Everything else in this entry sends normally.")
                .font(Type.caption(12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Words

    private var failures: [MediaItem] {
        order.filter { $0.uploadStatus == .failed && !$0.isTooLargeToSend }
    }

    /// Videos too long for the destination to take at any watchable quality.
    ///
    /// Kept apart from ordinary upload failures because it is not a failure and retrying will
    /// not change it. The entry has the video; the destination will not.
    private var staying: [MediaItem] {
        order.filter(\.isTooLargeToSend)
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
        if selecting {
            return selected.isEmpty
                ? "Tap the ones you want to move."
                : "Drag any of them to move all \(selected.count) together, or use the buttons above."
        }
        return order.count <= 1
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
    /// Every tile being carried. One for an ordinary drag, several when a selection is
    /// being moved as a block.
    let moving: () -> [UUID]
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) {
        guard dragging != nil else { return }
        let carried = Set(moving())
        // Dropping onto one of the tiles you are carrying is a no-op, not a reorder.
        guard !carried.isEmpty, !carried.contains(item.id),
              let to = order.firstIndex(where: { $0.id == item.id })
        else { return }

        // Lifted out and reinserted, rather than moved one at a time. Moving them
        // individually shifts the indices under the ones not moved yet, which scrambles a
        // multiple selection into whatever order the loop happened to visit it in.
        let offsets = IndexSet(order.indices.filter { carried.contains(order[$0].id) })
        let insertAt = to - offsets.filter { $0 < to }.count
        withAnimation(.easeInOut(duration: 0.18)) {
            let picked = offsets.map { order[$0] }
            order.remove(atOffsets: offsets)
            order.insert(contentsOf: picked, at: min(max(insertAt, 0), order.count))
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
    var selecting: Bool = false
    var isSelected: Bool = false
    let onOpen: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var image: UIImage?

    private var failed: Bool { item.uploadStatus == .failed && !item.isTooLargeToSend }

    private var border: Color {
        if selecting { return isSelected ? Brand.violet : .clear }
        return failed ? Brand.failed : Brand.violet
    }

    private var borderWidth: CGFloat {
        if selecting { return isSelected ? 3 : 0 }
        return failed || isCover ? 2 : 0
    }

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
                        .strokeBorder(border, lineWidth: borderWidth)
                }
                .opacity(selecting && !isSelected ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) { badge }
        .overlay(alignment: .topTrailing) {
            if selecting {
                // The tick takes the corner while selecting. Offering the menu in the same
                // spot would put "remove for good" one slip away from "choose".
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.9),
                                     isSelected ? Brand.violet : .black.opacity(0.45))
                    .padding(5)
            } else {
                SwiftUI.Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .padding(5)
            }
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
        .overlay(alignment: .bottomLeading) { partsBadge }
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

    /// What became of a video too big to send as one file.
    ///
    /// Worth saying on the tile. "Sent in 4 parts" explains why the page has four video blocks
    /// where the entry has one attachment, and it is the difference between the app looking
    /// broken and the app looking like it handled something.
    @ViewBuilder
    private var partsBadge: some View {
        if item.isTooLargeToSend {
            caption("Stays here", systemImage: "iphone")
        } else if item.isSplit {
            caption("\(item.partRelativePaths.count) parts", systemImage: "square.stack")
        }
    }

    private func caption(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(Type.caption(9.5, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
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
