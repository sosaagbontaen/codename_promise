import CodenamePromiseCore
import SwiftUI

/// Drafts grouped by the day they're about, newest first.
///
/// Nothing here is called "done" or "published" — every entry is a draft, and syncing is a
/// side effect shown as a badge rather than a state the entry graduates into.
struct DraftListView: View {
    @Environment(AppServices.self) private var services
    @State private var drafts: [EntryDraft] = []
    @State private var loadError: String?
    @State private var showingSettings = false
    @State private var showingImport = false
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmingBulkDelete = false
    @State private var openingDraft: OpeningDraft?

    var body: some View {
        NavigationStack {
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
            // Creating an entry should put you in it. Landing back on the list with a new
            // blank row and no cursor is a step the user then has to undo by hand.
            .navigationDestination(item: $openingDraft) { opening in
                if let store = services.store, let files = services.files,
                   let draft = try? store.draft(id: opening.id) {
                    CaptureView(draft: draft, store: store, fileStore: files)
                        .onDisappear { reload() }
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
                        NavigationLink {
                            CaptureView(draft: draft, store: store, fileStore: files)
                                .onDisappear { reload() }
                        } label: {
                            DraftRow(draft: draft, fileStore: files)
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
        let drafts: [EntryDraft]
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

    private func reload() {
        guard let store = services.store else { return }
        do {
            drafts = try store.allDrafts()
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
            openingDraft = OpeningDraft(id: draft.id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func duplicate(_ draft: EntryDraft, files: MediaFileStore) {
        guard let store = services.store else { return }
        do {
            try store.duplicate(draft, fileStore: files)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Deletes everything ticked, in one pass.
    private func deleteSelected() {
        guard let store = services.store, let files = services.files else { return }
        let doomed = drafts.filter { selection.contains($0.id) }
        for draft in doomed {
            do {
                try store.delete(draft, fileStore: files)
            } catch {
                loadError = error.localizedDescription
            }
        }
        selection.removeAll()
        editMode = .inactive
        reload()
    }

    private func delete(_ offsets: IndexSet, in group: [EntryDraft], files: MediaFileStore) {
        guard let store = services.store else { return }
        for index in offsets {
            do {
                try store.delete(group[index], fileStore: files)
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
    let draft: EntryDraft
    let fileStore: MediaFileStore

    /// Enough to recognise a day at a glance without turning the list into a gallery.
    private let previewLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)

            if !preview.isEmpty {
                Text(preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // A strip of what's actually attached, rather than a count. Seeing the day's
            // photos is the point of opening the list — "3 photos" tells you nothing about
            // which day this was.
            if !draft.orderedMedia.isEmpty {
                HStack(spacing: 4) {
                    ForEach(draft.orderedMedia.prefix(previewLimit), id: \.id) { item in
                        RowThumbnail(item: item, fileStore: fileStore)
                    }
                    if draft.orderedMedia.count > previewLimit {
                        Text("+\(draft.orderedMedia.count - previewLimit)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                if pendingRecordings > 0 {
                    badge("waveform", "\(pendingRecordings)", .secondary)
                }
                if draft.content.formattedText != nil {
                    // Purple is the app's mark for anything the AI touched.
                    badge("sparkles", "formatted", .purple)
                }
                syncBadge
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        if let title = draft.content.title, !title.isEmpty { return title }
        let firstLine = draft.content.rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled entry" : firstLine
    }

    private var preview: String {
        let text = draft.content.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != title else { return "" }
        return text
    }

    private var pendingRecordings: Int {
        draft.audioCaptures.filter { !$0.isSafeToDelete }.count
    }

    /// Green when the destination holds what you see; amber when it doesn't yet.
    ///
    /// An entry with edits made since its last sync counts as not synced — that is the state
    /// most worth flagging, because it's the one where the app and Notion silently disagree.
    @ViewBuilder
    private var syncBadge: some View {
        if draft.content.isEmpty {
            EmptyView()
        } else {
            let state = draft.syncStates.first { $0.target == .notion }
            let dirty = draft.needsSync(to: .notion)

            if let state, state.status == .syncing {
                badge("arrow.up.circle", "syncing", .secondary)
            } else if let state, state.status == .failed {
                badge("exclamationmark.icloud", "sync failed", .orange)
            } else if !dirty {
                badge("checkmark.icloud.fill", "synced", .green)
            } else if state?.externalId != nil {
                badge("arrow.triangle.2.circlepath", "unsynced changes", .orange)
            } else {
                badge("icloud.slash", "not synced", .orange)
            }
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
    let item: MediaItem
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
            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white)
                    .padding(2)
            }
        }
        .task {
            if image == nil {
                image = await ThumbnailCache.shared.thumbnail(
                    for: item, fileStore: fileStore, maxPixel: 80
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
