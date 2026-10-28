import CodenamePromiseCore
import SwiftUI

/// Entries waiting out their thirty days, with a way back for each.
///
/// Tapping an entry opens it in full, read only, with Restore and Delete now. Each row also
/// carries its own Restore button, and Select puts back or deletes several at once.
///
/// Holds plain rows rather than models, so a row animating away after a permanent delete
/// never reads a model that's gone (ADR-009a).
struct RecentlyDeletedView: View {
    let store: DraftStore
    let fileStore: MediaFileStore

    private struct Row: Identifiable, Hashable {
        let id: UUID
        let title: String
        let day: String
        let daysLeft: Int
        let thumb: DraftSummary.Thumb?
    }

    /// Which entry is open. Its own type so `navigationDestination(item:)` has something
    /// `Hashable` to hold that isn't a model.
    private struct Opened: Identifiable, Hashable {
        let id: UUID
    }

    @State private var rows: [Row] = []
    @State private var opened: Opened?
    @State private var editMode: EditMode = .inactive
    @State private var selected: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var deletingNow: Row?

    private var selecting: Bool { editMode.isEditing }

    /// What the bulk buttons act on: the selection if there is one, everything if not.
    private var targets: [UUID] {
        selected.isEmpty ? rows.map(\.id) : rows.map(\.id).filter(selected.contains)
    }

    var body: some View {
        List(selection: $selected) {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "trash",
                    description: Text("Deleted entries stay here for 30 days, then go for good.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(rows) { row in
                        rowView(row)
                            .tag(row.id)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    restore([row.id])
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(Brand.violet)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deletingNow = row
                                } label: {
                                    Label("Delete now", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    restore([row.id])
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    deletingNow = row
                                } label: {
                                    Label("Delete now", systemImage: "trash")
                                }
                            }
                    }
                } footer: {
                    Text("Tap an entry to see all of it. Swipe right to restore, left to delete for good.")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .background(Brand.ground)
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        .toolbar {
            if !rows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? "Done" : "Select") {
                        withAnimation {
                            editMode = selecting ? .inactive : .active
                            selected = []
                        }
                    }
                    .fontWeight(selecting ? .semibold : .regular)
                }
                if selecting {
                    ToolbarItem(placement: .bottomBar) {
                        Button(selected.isEmpty ? "Restore All" : "Restore \(selected.count)") {
                            restore(targets)
                        }
                        .tint(Brand.violet)
                    }
                    ToolbarItem(placement: .bottomBar) { Spacer() }
                    ToolbarItem(placement: .bottomBar) {
                        Button(selected.isEmpty ? "Delete All" : "Delete \(selected.count)", role: .destructive) {
                            confirmingDelete = true
                        }
                        .tint(Brand.failed)
                    }
                }
            }
        }
        .navigationDestination(item: $opened) { open in
            DeletedEntryView(
                store: store,
                fileStore: fileStore,
                id: open.id,
                onRestore: {
                    opened = nil
                    restore([open.id])
                },
                onDelete: {
                    opened = nil
                    deleteNow([open.id])
                }
            )
        }
        .confirmationDialog(
            "Delete \(targets.count) \(targets.count == 1 ? "entry" : "entries") for good?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete for good", role: .destructive) { deleteNow(targets) }
        } message: {
            Text("Their writing, photos and recordings are removed from this iPhone. This can\u{2019}t be undone.")
        }
        .confirmationDialog(
            "Delete this entry for good?",
            isPresented: Binding(get: { deletingNow != nil }, set: { if !$0 { deletingNow = nil } }),
            titleVisibility: .visible,
            presenting: deletingNow
        ) { row in
            Button("Delete for good", role: .destructive) { deleteNow([row.id]) }
        } message: { _ in
            Text("Its writing, photos and recordings are removed from this iPhone. This can\u{2019}t be undone.")
        }
        .task { reload() }
    }

    // MARK: Row

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        if selecting {
            // Plain while selecting, so a tap selects rather than opens or restores.
            rowLabel(row)
        } else {
            HStack(spacing: 12) {
                Button {
                    opened = Opened(id: row.id)
                } label: {
                    rowLabel(row).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the whole entry")

                Button {
                    restore([row.id])
                } label: {
                    Text("Restore")
                        .font(Type.label(14))
                        .foregroundStyle(Brand.violet)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Brand.violet.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Restore \(row.title)")
            }
        }
    }

    private func rowLabel(_ row: Row) -> some View {
        HStack(spacing: 12) {
            if let thumb = row.thumb {
                PhotoTile(thumb: thumb, fileStore: fileStore, maxPixel: 120)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .foregroundStyle(Brand.ink)
                    .lineLimit(2)
                Text("\(row.day) \u{00B7} \(DeletedEntryView.leftLabel(row.daysLeft))")
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private func reload() {
        let now = Date()
        rows = ((try? store.trashedDrafts()) ?? []).map { draft in
            let goes = (draft.deletedAt ?? now).addingTimeInterval(DraftStore.trashRetention)
            let left = max(0, Int(ceil(goes.timeIntervalSince(now) / 86_400)))
            // The first line is Markdown, so read it as text rather than show "# " or tags.
            let firstLine = RichDocument.words(ofMarkdown: draft.content.rawText)
                .split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            let title = draft.content.title.flatMap { $0.isEmpty ? nil : $0 }
                ?? firstLine
                ?? "Untitled entry"
            let first = draft.orderedMedia.first
            return Row(
                id: draft.id,
                title: title,
                day: draft.entryDate.representativeDate().formatted(.dateTime.month(.abbreviated).day().year()),
                daysLeft: left,
                thumb: first.map {
                    DraftSummary.Thumb(id: $0.id, relativePath: $0.relativePath, isVideo: $0.kind == .video)
                }
            )
        }
        selected.formIntersection(rows.map(\.id))
        if rows.isEmpty { editMode = .inactive }
    }

    /// Restoring only clears `deletedAt`; the store saves before returning (ADR-001).
    private func restore(_ ids: [UUID]) {
        for id in ids {
            if let draft = try? store.draft(id: id) { try? store.restore(draft) }
        }
        Haptics.picked()
        withAnimation { reload() }
    }

    /// Rows out first, then the models, so nothing reads a deleted model mid-animation. The
    /// store's delete takes the file store so the photos and recordings go too (ADR-018a).
    private func deleteNow(_ ids: [UUID]) {
        let gone = Set(ids)
        rows.removeAll { gone.contains($0.id) }
        selected.subtract(gone)
        for id in ids {
            if let draft = try? store.draft(id: id) { try? store.delete(draft, fileStore: fileStore) }
        }
        reload()
    }
}
