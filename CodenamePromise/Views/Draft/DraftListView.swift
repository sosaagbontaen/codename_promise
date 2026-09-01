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
    @AppStorage(RowDensity.storageKey) private var density: RowDensity = .comfortable
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
                ToolbarItem(placement: .principal) { Wordmark(size: 17) }
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
                        .tint(Brand.ink)
                    }
                }
                // Two visible buttons rather than a menu behind a long-press. Importing by
                // date is one of the more useful things this app does, and nobody discovers a
                // long-press.
                // Neutral, all of them. Violet was on the wordmark, Select, three toolbar
                // icons, the day rule, "Today" and the selected tab at once - at which point
                // it stops being an accent and becomes the app's grey. It now marks two
                // things: the brand, and what is selected or pressable *right now*.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { density = density.next }
                        Haptics.picked()
                    } label: {
                        Label("Density", systemImage: density.next.symbol)
                    }
                    .tint(Brand.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import photos by date", systemImage: "photo.stack")
                    }
                    .tint(Brand.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createDraft()
                    } label: {
                        Label("New entry", systemImage: "square.and.pencil")
                    }
                    .tint(Brand.ink)
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
                    // Deliberately no surface behind it. Every element having a background is
                    // what makes a screen read as a stack of floating panels rather than a
                    // page, and this one has the least claim to being an object.
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 22, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
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
                        Button {
                            path.append(OpeningDraft(id: draft.id))
                        } label: {
                            if density == .compact {
                                CompactDraftRow(summary: draft)
                            } else {
                                DraftRow(summary: draft, fileStore: files)
                            }
                        }
                        .buttonStyle(.row)
                        // A quiet container, not the old heavy card. Removing them entirely
                        // left days and entries separated identically, so the grouping
                        // stopped being readable - a day heading looked like just more list.
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Brand.surface)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                        )
                        .listRowSeparator(.hidden)
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
        // Section spacing is handed to the day heading instead of split between the two.
        //
        // A List's own gap plus the heading's top padding meant the distance from the prompt
        // to the first day was set in two places at once, and came out at roughly a thumb -
        // enough that the date read as another isolated object rather than as the start of
        // what is under it. One control point, one number.
        .listSectionSpacing(0)
        .contentMargins(.top, 6, for: .scrollContent)
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
        VStack(alignment: .leading, spacing: 7) {
            // Title and time on one line. The timeline header already said which day this
            // was, so repeating the date here only crowded it.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.title)
                    .font(Type.label(17, .semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(summary.time)
                    .font(Type.caption(11.5))
                    .foregroundStyle(Brand.muted)
            }

            if !summary.preview.isEmpty {
                Text(summary.preview)
                    .font(Type.journal(14.5))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(3)
                    .lineSpacing(2)
            }

            if !summary.thumbnails.isEmpty {
                MediaCollage(
                    thumbs: summary.thumbnails,
                    overflow: summary.hiddenThumbnailCount,
                    fileStore: fileStore
                )
            }

            // Metadata, and it should read as metadata. Previously "not synced" carried the
            // same visual weight as the entry itself, which put a housekeeping detail on a
            // level with somebody's evening.
            HStack(spacing: 10) {
                if !statusLabel.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: statusIcon).font(.system(size: 10, weight: .semibold))
                        Text(statusLabel)
                    }
                    .font(Type.caption(11, .semibold))
                    .foregroundStyle(statusTint)
                }

                // Separate badges rather than a run-on line, each with its own symbol and
                // colour, so three different facts do not read as one sentence.
                if summary.pendingRecordings > 0 {
                    badge("waveform", "\(summary.pendingRecordings) to transcribe", Brand.waiting)
                }
                if summary.isFormatted {
                    badge("sparkles", "formatted", Brand.ai)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
    }

    /// One symbol per state, never shared.
    ///
    /// The previous set used the same glyph for "not synced" and "edited since sync", which
    /// makes a symbol decorative rather than informative - you had to read the words anyway,
    /// so the icon was costing space and adding doubt. These are all from the cloud family
    /// so they read as one vocabulary about one thing, and each state owns exactly one.
    private var statusLabel: String {
        switch summary.sync {
        case .hidden: ""
        case .syncing: "syncing"
        case .failed: "sync failed"
        case .synced: "synced"
        case .unsyncedChanges: "unsynced changes"
        case .notSynced: "not synced"
        }
    }

    private var statusIcon: String {
        switch summary.sync {
        case .hidden: "icloud.slash"
        case .syncing: "arrow.up.circle"
        case .failed: "exclamationmark.icloud"
        case .synced: "checkmark.icloud.fill"
        case .unsyncedChanges: "arrow.triangle.2.circlepath"
        case .notSynced: "icloud.slash"
        }
    }

    /// Colour-coded, and small.
    ///
    /// Greying everything but failures was an overcorrection: colour is what marks this as a
    /// *different channel* from the entry's own words, and losing it made status read as more
    /// body text. What made it shout before was its size and weight, not its hue - so it
    /// keeps the colour and gives up the size.
    private func badge(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text)
        }
        .font(Type.caption(11, .semibold))
        .foregroundStyle(tint)
    }

    private var statusTint: Color {
        switch summary.sync {
        case .failed: Brand.failed
        case .synced: Brand.reached
        case .syncing: Brand.violet
        case .unsyncedChanges, .notSynced: Brand.waiting
        case .hidden: Brand.muted
        }
    }
}

/// A day, given the weight a day deserves.
///
/// A journal grouped by date should say the date like it matters. The default section header
/// is nine-point grey uppercase, which is what you use for "OTHER" in a settings screen.
///
/// **The date is the headline, not the weekday name.** "Wednesday" in 22pt told you almost
/// nothing while scrolling back through months - you cannot place a Wednesday without the
/// number, so the number was doing the work from the small grey line underneath. Now it reads
/// "Sat 8/22/26": weekday for feel, date for fact, one line at one size. The year is always
/// there because two digits cost nothing and "8/22" is ambiguous the moment a journal is more
/// than a year old.
///
/// "Today" and "Yesterday" keep the line underneath, since those are the two days where the
/// relative name really is the more useful fact - and today is tinted, so it is findable
/// without reading.
///
/// The hairline under it tapers the way the ripples do in the mark.
private struct DayHeader: View {
    let day: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: -1) {
                Text(headline)
                    .font(Type.display(22, .bold))
                    .foregroundStyle(Brand.ink)
                if let relative {
                    Text(relative)
                        .font(Type.caption(13, .semibold))
                        .foregroundStyle(isToday ? Brand.violet : Brand.muted)
                }
            }
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)

            LinearGradient(
                colors: [Brand.ripple, Brand.ripple.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1.5)
            .frame(maxWidth: 190)
        }
        // Much more space above a day than between its entries: that difference is what
        // makes the grouping legible at a glance. The asymmetry is the whole point - the
        // heading has to sit closer to the entries it owns than to the day above it, or it
        // reads as one more free-floating object in a column of them.
        .padding(.top, 26)
        .padding(.bottom, 0)
        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 2, trailing: 16))
    }

    /// "Sat" carries the feel of a day; "8/22/26" carries the fact. Both, once, at the top.
    ///
    /// Composed rather than asked for as one format style, because a combined weekday-plus-
    /// numeric-date style renders as "Sat, 8/22/2026" - a comma and four digits of year to
    /// say the same thing.
    private var headline: String {
        guard let calendarDay = CalendarDay(rawValue: day) else { return label }
        let date = calendarDay.representativeDate()
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        let numeric = date.formatted(
            .dateTime.month(.defaultDigits).day().year(.twoDigits)
        )
        return "\(weekday) \(numeric)"
    }

    private var isToday: Bool {
        CalendarDay(rawValue: day) == CalendarDay.today()
    }

    /// Only the two days that have a name worth more than their number.
    private var relative: String? {
        guard let calendarDay = CalendarDay(rawValue: day) else { return nil }
        let today = CalendarDay.today()
        if calendarDay == today { return "Today" }
        if calendarDay == today.adding(days: -1) { return "Yesterday" }
        return nil
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
