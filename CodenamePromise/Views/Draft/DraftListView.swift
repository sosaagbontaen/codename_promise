import CodenamePromiseCore
import SwiftUI

/// Drafts grouped by the day they're about, newest first.
///
/// Nothing here is called "done" or "published" — every entry is a draft, and syncing is a
/// side effect shown as a badge rather than a state the entry graduates into.
struct DraftListView: View {
    @Environment(AppServices.self) private var services
    @State private var drafts: [DraftSummary] = []
    @State private var loadError: String?
    @State private var showingSettings = false
    @State private var showingImport = false
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmingBulkDelete = false
    /// The navigation stack's path.
    ///
    /// Rows push a *value*, not a view. `NavigationLink { CaptureView(...) }` stores its
    /// destination as a stored property, so building the row built a whole CaptureView —
    /// and CaptureController.init reads draft.content. Opening this list constructed one
    /// per row on every body pass, which is both wasteful and how a freshly deleted draft
    /// got read after detaching. See `remove`.
    @State private var path: [OpeningDraft] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let store = services.store, let files = services.files {
                    content(store: store, files: files)
                        .environment(\.editMode, $editMode)
                } else {
                    ContentUnavailableView("Journal unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle("AutoReflect")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editMode == .active {
                        Button(selection.isEmpty ? "Done" : "Delete \(selection.count)",
                               role: selection.isEmpty ? nil : .destructive) {
                            if selection.isEmpty {
                                editMode = .inactive
                            } else {
                                confirmingBulkDelete = true
                            }
                        }
                    } else {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !drafts.isEmpty {
                        Button(editMode == .active ? "Cancel" : "Select") {
                            withAnimation {
                                selection.removeAll()
                                editMode = editMode == .active ? .inactive : .active
                            }
                        }
                    }
                }
                // Two visible buttons rather than a menu behind a long-press. Importing by
                // date is one of the more useful things this app does, and nobody discovers a
                // long-press.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import photos by date", systemImage: "photo.stack")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createDraft()
                    } label: {
                        Label("New entry", systemImage: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                NotionSettingsView()
            }
            // One destination for both tapping a row and creating an entry, resolved by
            // UUID rather than by holding a model — so a draft deleted underneath it
            // resolves to nothing instead of trapping (ADR-009a).
            .navigationDestination(for: OpeningDraft.self) { opening in
                if let store = services.store, let files = services.files,
                   let draft = try? store.draft(id: opening.id) {
                    CaptureView(draft: draft, store: store, fileStore: files)
                        .onDisappear { reload() }
                } else {
                    ContentUnavailableView("Entry no longer exists", systemImage: "tray")
                }
            }
            .sheet(isPresented: $showingImport) {
                if let store = services.store, let files = services.files {
                    PhotoImportView(store: store, fileStore: files) { reload() }
                }
            }
            .task { reload() }
            .confirmationDialog(
                "Delete \(selection.count) \(selection.count == 1 ? "entry" : "entries")?",
                isPresented: $confirmingBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteSelected() }
            } message: {
                Text("This can't be undone. Anything already in Notion stays there.")
            }
        }
    }

    @ViewBuilder
    private func content(store: DraftStore, files: MediaFileStore) -> some View {
        List(selection: $selection) {
            if let notice = services.recoveryNotice {
                Section {
                    RecoveryNotice(message: notice) { services.dismissRecoveryNotice() }
                }
            }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            ForEach(groupedDrafts, id: \.day) { group in
                Section(group.label) {
                    ForEach(group.drafts, id: \.id) { draft in
                        NavigationLink(value: OpeningDraft(id: draft.id)) {
                            DraftRow(summary: draft, fileStore: files)
                        }
                        // Swipe the opposite way from delete. Duplicating is the safe action,
                        // so it gets the leading edge where an accidental swipe costs nothing.
                        .swipeActions(edge: .leading) {
                            Button {
                                duplicate(draft, files: files)
                            } label: {
                                Label("Duplicate", systemImage: "doc.on.doc")
                            }
                            .tint(.indigo)
                        }
                    }
                    .onDelete { offsets in
                        delete(offsets, in: group.drafts, files: files)
                    }
                }
            }

        }
        .overlay {
            if drafts.isEmpty {
                // The call to action lives *inside* the overlay. A button in a List section
                // underneath it is unreachable — the overlay covers the whole list and eats
                // the tap.
                ContentUnavailableView {
                    Label("Nothing captured yet", systemImage: "book.closed")
                } description: {
                    Text("Capture first. Organize later. Sync whenever.")
                } actions: {
                    Button("Start today's entry", action: createDraft)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Grouping

    private struct DraftGroup {
        let day: String
        let label: String
        let drafts: [DraftSummary]
    }

    /// `entryDateKey` is `yyyy-MM-dd`, so the store already returns these in day order.
    private var groupedDrafts: [DraftGroup] {
        let buckets = Dictionary(grouping: drafts, by: \.entryDateKey)
        return buckets.keys.sorted(by: >).map { key in
            let day = CalendarDay(rawValue: key)
            return DraftGroup(
                day: key,
                label: day?.representativeDate()
                    .formatted(.dateTime.weekday(.wide).month(.wide).day().year()) ?? key,
                drafts: buckets[key] ?? []
            )
        }
    }

    // MARK: - Actions

    /// Snapshot limit for the row strip: enough to recognise a day at a glance without
    /// turning the list into a gallery.
    private static let thumbnailLimit = 6

    private func reload() {
        guard let store = services.store else { return }
        do {
            drafts = try store.allDrafts().map {
                DraftSummary($0, thumbnailLimit: Self.thumbnailLimit)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func createDraft() {
        guard let store = services.store else { return }
        do {
            let draft = try store.createDraft()
            reload()
            path.append(OpeningDraft(id: draft.id))
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Resolves ids to models at the moment of acting, rather than holding models in state.
    private func models(for ids: [UUID]) -> [EntryDraft] {
        guard let store = services.store else { return [] }
        return ids.compactMap { try? store.draft(id: $0) }
    }

    private func duplicate(_ summary: DraftSummary, files: MediaFileStore) {
        guard let store = services.store, let draft = models(for: [summary.id]).first else { return }
        do {
            try store.duplicate(draft, fileStore: files)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Deletes everything ticked, in one pass.
    private func deleteSelected() {
        guard let files = services.files else { return }
        let doomed = drafts.filter { selection.contains($0.id) }.map(\.id)
        selection.removeAll()
        editMode = .inactive
        remove(doomed, files: files)
    }

    private func delete(_ offsets: IndexSet, in group: [DraftSummary], files: MediaFileStore) {
        remove(offsets.map { group[$0].id }, files: files)
    }

    /// Takes the rows out of the list *before* deleting the models behind them.
    ///
    /// A deleted `@Model` is detached from its context, and reading any attribute on it
    /// traps — "This backing data was detached from a context without resolving attribute
    /// faults". SwiftUI is free to evaluate this list's body between the delete and the
    /// refetch, and `DraftRow` reads `draft.content`, so leaving a doomed draft in `drafts`
    /// for even one pass is a crash waiting for the right timing. Emptying first closes the
    /// window rather than narrowing it.
    private func remove(_ doomed: [UUID], files: MediaFileStore) {
        guard let store = services.store, !doomed.isEmpty else { return }
        let ids = Set(doomed)
        let models = models(for: doomed)

        drafts.removeAll { ids.contains($0.id) }
        // Nor may the stack still be pointing at one of them.
        path.removeAll { ids.contains($0.id) }

        for draft in models {
            do {
                try store.delete(draft, fileStore: files)
            } catch {
                loadError = error.localizedDescription
            }
        }
        reload()
    }
}

/// Wrapper so a `UUID` can drive `.navigationDestination(item:)` without a retroactive
/// `Identifiable` conformance on a stdlib type.
struct OpeningDraft: Identifiable, Hashable {
    let id: UUID
}

struct DraftRow: View {
    /// A snapshot, never a model — see `DraftSummary` for the crash that bought this rule.
    let summary: DraftSummary
    let fileStore: MediaFileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.title)
                .font(.body.weight(.medium))
                .lineLimit(1)

            if !summary.preview.isEmpty {
                Text(summary.preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // A strip of what's actually attached, rather than a count. Seeing the day's
            // photos is the point of opening the list — "3 photos" tells you nothing about
            // which day this was.
            if !summary.thumbnails.isEmpty {
                HStack(spacing: 4) {
                    ForEach(summary.thumbnails) { thumb in
                        RowThumbnail(thumb: thumb, fileStore: fileStore)
                    }
                    if summary.hiddenThumbnailCount > 0 {
                        Text("+\(summary.hiddenThumbnailCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                if summary.pendingRecordings > 0 {
                    badge("waveform", "\(summary.pendingRecordings)", .secondary)
                }
                if summary.isFormatted {
                    // Purple is the app's mark for anything the AI touched.
                    badge("sparkles", "formatted", .purple)
                }
                syncBadge
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
    }

    /// Green when the destination holds what you see; amber when it doesn't yet.
    @ViewBuilder
    private var syncBadge: some View {
        switch summary.sync {
        case .hidden:
            EmptyView()
        case .syncing:
            badge("arrow.up.circle", "syncing", .secondary)
        case .failed:
            badge("exclamationmark.icloud", "sync failed", .orange)
        case .synced:
            badge("checkmark.icloud.fill", "synced", .green)
        case .unsyncedChanges:
            badge("arrow.triangle.2.circlepath", "unsynced changes", .orange)
        case .notSynced:
            badge("icloud.slash", "not synced", .orange)
        }
    }

    private func badge(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(tint)
    }
}

/// A small thumbnail for the list. Uses the shared downsampling cache — decoding full-size
/// originals while scrolling would make the list stutter badly.
private struct RowThumbnail: View {
    let thumb: DraftSummary.Thumb
    let fileStore: MediaFileStore

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            if thumb.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white)
                    .padding(2)
            }
        }
        .task {
            if image == nil {
                image = await ThumbnailCache.shared.thumbnail(
                    id: thumb.id, relativePath: thumb.relativePath, isVideo: thumb.isVideo,
                    fileStore: fileStore, maxPixel: 80
                )
            }
        }
    }
}

struct RecoveryNotice: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(.blue)
            Text(message).font(.footnote)
            Spacer()
            Button("OK", action: onDismiss).font(.footnote)
        }
    }
}
