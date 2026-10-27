import CodenamePromiseCore
import SwiftUI

/// Entries waiting out their thirty days, with a way back for each.
///
/// Holds plain rows rather than models, so a row animating away after a permanent delete
/// never reads a model that's gone (ADR-009a).
struct RecentlyDeletedView: View {
    let store: DraftStore
    let fileStore: MediaFileStore

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let day: String
        let daysLeft: Int
    }

    @State private var rows: [Row] = []
    @State private var confirmingEmpty = false
    @State private var deletingNow: Row?

    var body: some View {
        List {
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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).foregroundStyle(Brand.ink)
                            Text("\(row.day) \u{00B7} \(row.daysLeft) \(row.daysLeft == 1 ? "day" : "days") left")
                                .font(.footnote)
                                .foregroundStyle(Brand.muted)
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                restore(row.id)
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
                                restore(row.id)
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
                    Text("Swipe right to restore, left to delete for good.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.ground)
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !rows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Empty", role: .destructive) { confirmingEmpty = true }
                        .tint(Brand.failed)
                }
            }
        }
        .confirmationDialog(
            "Delete \(rows.count) \(rows.count == 1 ? "entry" : "entries") for good?",
            isPresented: $confirmingEmpty,
            titleVisibility: .visible
        ) {
            Button("Delete for good", role: .destructive) { empty() }
        } message: {
            Text("Their writing, photos and recordings are removed from this iPhone. This can\u{2019}t be undone.")
        }
        .confirmationDialog(
            "Delete this entry for good?",
            isPresented: Binding(get: { deletingNow != nil }, set: { if !$0 { deletingNow = nil } }),
            titleVisibility: .visible,
            presenting: deletingNow
        ) { row in
            Button("Delete for good", role: .destructive) { deleteNow(row.id) }
        } message: { _ in
            Text("This can\u{2019}t be undone.")
        }
        .task { reload() }
    }

    private func reload() {
        let now = Date()
        rows = ((try? store.trashedDrafts()) ?? []).map { draft in
            let goes = (draft.deletedAt ?? now).addingTimeInterval(DraftStore.trashRetention)
            let left = max(0, Int(ceil(goes.timeIntervalSince(now) / 86_400)))
            let title = draft.content.title.flatMap { $0.isEmpty ? nil : $0 }
                ?? draft.content.rawText.split(separator: "\n").first.map(String.init)
                ?? "Untitled entry"
            return Row(
                id: draft.id,
                title: title,
                day: draft.entryDate.representativeDate().formatted(.dateTime.month(.abbreviated).day().year()),
                daysLeft: left
            )
        }
    }

    private func restore(_ id: UUID) {
        if let draft = try? store.draft(id: id) { try? store.restore(draft) }
        Haptics.picked()
        reload()
    }

    /// Rows out first, then the models, so nothing reads a deleted model mid-animation.
    private func deleteNow(_ id: UUID) {
        rows.removeAll { $0.id == id }
        if let draft = try? store.draft(id: id) { try? store.delete(draft, fileStore: fileStore) }
        reload()
    }

    private func empty() {
        let ids = rows.map(\.id)
        rows = []
        for id in ids {
            if let draft = try? store.draft(id: id) { try? store.delete(draft, fileStore: fileStore) }
        }
        reload()
    }
}
