import CodenamePromiseCore
import SwiftUI

/// Drafts grouped by the day they're about, newest first.
///
/// Nothing here is called "done" or "published" — every entry is a draft, and syncing is a
/// side effect shown as a badge rather than a state the entry graduates into.
struct DraftListView: View {
    /// A draft the Dump tab just created and wants opened. Cleared once acted on.
    var openEntry: Binding<UUID?> = .constant(nil)

    @Environment(AppServices.self) private var services
    @State private var drafts: [DraftSummary] = []
    @State private var loadError: String?
    @State private var showingImport = false
    @State private var showingOpenDays = false
    /// Recomputed on every reload; drives the prompt row at the top of the list.
    @State private var mostRecentOpenDay: CalendarDay?
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Wordmark(size: 19) }
            }
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
            .sheet(isPresented: $showingOpenDays) {
                if let store = services.store {
                    OpenDaysView(
                        store: store,
                        connection: services.connectionService
                    ) { draft in
                        reload()
                        path.append(OpeningDraft(id: draft.id))
                    }
                }
            }
            .sheet(isPresented: $showingImport) {
                if let store = services.store, let files = services.files {
                    PhotoImportView(store: store, fileStore: files) { reload() }
                }
            }
            .task { reload(); consumeOpenRequest() }
            // Both, on purpose. A dump sets the id and switches tab in the same update, and
            // whether this view is alive to observe the change depends on whether the tab has
            // been visited before - so the request is also drained on appear.
            .onChange(of: openEntry.wrappedValue) { _, _ in consumeOpenRequest() }
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
            if !drafts.isEmpty {
                Section {
                    OpenDaysPrompt(mostRecentOpenDay: mostRecentOpenDay) {
                        showingOpenDays = true
                    }
                    .listRowBackground(Brand.surface)
                }
            }

            if let notice = services.recoveryNotice {
                Section {
                    RecoveryNotice(message: notice) { services.dismissRecoveryNotice() }
                }
            }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.failed)
                }
            }

            ForEach(groupedDrafts, id: \.day) { group in
                Section {
                    ForEach(group.drafts, id: \.id) { draft in
                        NavigationLink(value: OpeningDraft(id: draft.id)) {
                            DraftRow(summary: draft, fileStore: files)
                        }
                        .listRowBackground(Brand.surface)
                        // Swipe the opposite way from delete. Duplicating is the safe action,
                        // so it gets the leading edge where an accidental swipe costs nothing.
                        .swipeActions(edge: .leading) {
                            Button {
                                duplicate(draft, files: files)
                            } label: {
                                Label("Duplicate", systemImage: "doc.on.doc")
                            }
                            .tint(Brand.violet)
                        }
                    }
                    .onDelete { offsets in
                        delete(offsets, in: group.drafts, files: files)
                    }
                } header: {
                    DayHeader(day: group.day, label: group.label)
                }
            }

        }
        .scrollContentBackground(.hidden)
        .background(Brand.ground)
        .overlay {
            if drafts.isEmpty {
                // The call to action lives *inside* the overlay. A button in a List section
                // underneath it is unreachable — the overlay covers the whole list and eats
                // the tap.
                VStack(spacing: 18) {
                    Image(systemName: "waveform")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(Brand.gradient)

                    VStack(spacing: 6) {
                        Text("Nothing captured yet")
                            .font(Type.title(21))
                        Text("Capture first. Organize later. Sync whenever.")
                            .font(Type.body(15))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: createDraft) {
                        Text("Start today's entry")
                            .font(Type.label(15.5, .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .frame(height: 46)
                            .background(Brand.gradient, in: Capsule())
                    }
                    .padding(.top, 2)
                }
                .padding(32)
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
    /// Four at 54pt plus the overflow chip is ~285pt, which fits the narrowest row this app
    /// runs in. It used to be six at 58pt - about 431pt - and an `HStack` that wide does not
    /// clip, it widens its parent: the row's title, preview and badges were pushed out of
    /// frame to the left, which looked like text randomly disappearing.
    private static let thumbnailLimit = 4

    /// The window the prompt row talks about. The sheet itself can widen it.
    private static let promptWindowDays = 30

    /// Opens a draft the Dump tab just created, once.
    private func consumeOpenRequest() {
        guard let id = openEntry.wrappedValue else { return }
        openEntry.wrappedValue = nil
        reload()
        path = [OpeningDraft(id: id)]
    }

    private func reload() {
        guard let store = services.store else { return }
        do {
            drafts = try store.allDrafts().map {
                DraftSummary($0, thumbnailLimit: Self.thumbnailLimit)
            }

            let through = CalendarDay.today()
            let from = through.adding(days: -(Self.promptWindowDays - 1))
            // Newest first, so the head of the list is the day still worth remembering.
            mostRecentOpenDay = JournalGaps.openDays(
                from: from,
                through: through,
                covered: try store.entryDays(from: from, through: through),
                firstEntryDay: try store.earliestEntryDay()
            ).first

            // Exactly one nudge is pending at a time, recomputed whenever the journal
            // changes rather than incremented.
            services.reminders.reschedule(using: store)

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
                .font(Type.label(16.5, .semibold))
                .lineLimit(1)

            if !summary.preview.isEmpty {
                Text(summary.preview)
                    .font(Type.body(14))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // A strip of what's actually attached, rather than a count. Seeing the day's
            // photos is the point of opening the list — "3 photos" tells you nothing about
            // which day this was.
            if !summary.thumbnails.isEmpty {
                HStack(spacing: 5) {
                    ForEach(summary.thumbnails) { thumb in
                        RowThumbnail(thumb: thumb, fileStore: fileStore)
                    }
                    if summary.hiddenThumbnailCount > 0 {
                        Text("+\(summary.hiddenThumbnailCount)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 54, height: 54)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                // Belt and braces: even if the strip is ever too wide again, it must clip
                // rather than drag the rest of the row off-screen with it.
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                if summary.pendingRecordings > 0 {
                    badge("waveform", "\(summary.pendingRecordings)", .secondary)
                }
                if summary.isFormatted {
                    // Purple is the app's mark for anything the AI touched.
                    badge("sparkles", "formatted", Brand.ai)
                }
                syncBadge
            }
            .font(Type.caption(11.5, .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
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
            badge("exclamationmark.icloud", "sync failed", Brand.failed)
        case .synced:
            badge("checkmark.icloud.fill", "synced", Brand.reached)
        case .unsyncedChanges:
            badge("arrow.triangle.2.circlepath", "unsynced changes", Brand.waiting)
        case .notSynced:
            badge("icloud.slash", "not synced", Brand.waiting)
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
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            if thumb.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(4)
            }
        }
        .task {
            if image == nil {
                image = await ThumbnailCache.shared.thumbnail(
                    id: thumb.id, relativePath: thumb.relativePath, isVideo: thumb.isVideo,
                    fileStore: fileStore, maxPixel: 140
                )
            }
        }
    }
}

/// A day, given the weight a day deserves.
///
/// A journal grouped by date should say the date like it matters. The default section header
/// is nine-point grey uppercase, which is what you use for "OTHER" in a settings screen.
///
/// The hairline under it tapers the way the ripples do in the mark.
private struct DayHeader: View {
    let day: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(weekday)
                    .font(Type.title(20))
                    .foregroundStyle(.primary)
                Text(rest)
                    .font(Type.caption(13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .textCase(nil)

            LinearGradient(
                colors: [Brand.ripple, Brand.ripple.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1.5)
            .frame(maxWidth: 190)
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
    }

    /// "Friday" carries the feel of a day; "August 14, 2026" carries the fact.
    private var weekday: String {
        guard let calendarDay = CalendarDay(rawValue: day) else { return label }
        let today = CalendarDay.today()
        if calendarDay == today { return "Today" }
        if calendarDay == today.adding(days: -1) { return "Yesterday" }
        return calendarDay.representativeDate().formatted(.dateTime.weekday(.wide))
    }

    private var rest: String {
        guard let calendarDay = CalendarDay(rawValue: day) else { return "" }
        return calendarDay.representativeDate()
            .formatted(.dateTime.month(.wide).day().year())
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
