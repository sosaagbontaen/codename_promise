import CodenamePromiseCore
import SwiftUI

/// The journal, organised by time.
///
/// A calendar first: which days have something, which don't, and what happened on the one
/// you tap. It answers "what happened that day?", where a wall of cards only answered "what
/// have I saved?". The list is the other way in, for scanning months at a time.
///
/// The list holds `DraftSummary` snapshots, never models: a view kept alive to animate a
/// deleted row away would otherwise read a detached model and trap (ADR-009a).
struct JournalView: View {
    @Environment(AppServices.self) private var services

    enum Mode: String, CaseIterable { case calendar, list, grid

        var symbol: String {
            switch self {
            case .calendar: "calendar"
            case .list: "list.bullet.rectangle"
            case .grid: "square.grid.2x2"
            }
        }
        var label: String {
            switch self {
            case .calendar: "Calendar"
            case .list: "List"
            case .grid: "Grid"
            }
        }
    }

    @AppStorage("journalMode") private var mode: Mode = .calendar
    @State private var drafts: [DraftSummary] = []
    /// Derived from `drafts` once per refresh rather than on every redraw. The calendar used
    /// to rebuild the per-day table inside each of its ~35 cells, every render.
    @State private var kinds: [CalendarDay: DayKind] = [:]
    @State private var months: [(key: String, label: String, entries: [DraftSummary])] = []
    @State private var artCache = EntryArtCache()
    /// The store revision the list was last brought up to. See `refresh()`.
    @State private var loadedRevision: Int?
    /// The scrubber's labels, built when the months change rather than on every redraw.
    @State private var scrubberMonths: [MonthScrubber.Month] = []
    /// How far the list or grid is scrolled, for the scrubber's handle. An object only the
    /// scrubber reads, so scrolling redraws the scrubber and not this whole view.
    @State private var scrollTracker = ScrollProgressTracker()
    @State private var loadError: String?
    @State private var month = Self.startOfMonth(Date())
    @State private var selectedDay = CalendarDay.today()
    @State private var path: [OpeningDraft] = []
    /// For the selected view's capsule, which slides to the one you tap.
    @Namespace private var modeSpace
    /// Which way the calendar last moved, so the next month slides in from that side.
    @State private var monthStep = 1

    @State private var showingQuickDump = false
    /// The day the dump sheet opens on, when it was opened for one.
    @State private var dumpDay: CalendarDay?
    @State private var showingInboxDigest = false
    /// Searching replaces the header with a search bar and the journal with results.
    @State private var searching = false
    @State private var query = ""
    @State private var searchFilter = SearchFilter()

    // Select mode: entered by holding an entry, which arrives already selected.
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    /// The entry last touched in select mode, kept in view through the layout change.
    @State private var anchor: UUID?
    /// Set by a long press so the tap that ends it doesn't also open or toggle the entry.
    @State private var swallowNextTap = false
    /// What the last delete moved to Recently Deleted, so it can be undone from the notice.
    @State private var lastTrashed: [UUID] = []
    @State private var movingSelection = false
    @State private var moveTo = Date()
    @State private var exportingSelection = false
    @State private var notice: String?
    @AppStorage("calendarFilter") private var filter: DayFilter = .all

    /// Which days the calendar circles.
    enum DayFilter: String, CaseIterable, Identifiable {
        case all, both, wordsOnly, mediaOnly, missing
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All entries"
            case .both: "Words and media"
            case .wordsOnly: "Words only"
            case .mediaOnly: "Media only"
            case .missing: "No entry"
            }
        }
        var symbol: String {
            switch self {
            case .all: "circle.grid.2x2"
            case .both: "text.below.photo"
            case .wordsOnly: "text.alignleft"
            case .mediaOnly: "photo"
            case .missing: "circle.dashed"
            }
        }
    }

    /// What a day holds, across all its entries.
    private struct DayKind { var words = false; var media = false }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Group {
                            if mode == .calendar {
                                VStack(alignment: .leading, spacing: 18) {
                                    notices
                                    calendar
                                    dayEntries
                                }
                            } else {
                                // Lazy, so only the months on screen are built, and each
                                // month's header stays at the top until the next one's
                                // pushes it off.
                                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    notices
                                    if drafts.isEmpty, loadedRevision != nil, loadError == nil {
                                        EmptyState(
                                            "Your journal starts here",
                                            message: "Tap + to dump a note, a photo, or a recording.",
                                            props: [.note, .photo, .mic]
                                        )
                                        .padding(.top, 80)
                                    }
                                    switch mode {
                                    case .list: listByMonth
                                    default: gridByMonth
                                    }
                                }
                            }
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 96)
                        }
                        .onChange(of: anchor) { _, id in keep(id, in: proxy) }
                        .onChange(of: selecting) { _, _ in keep(anchor, in: proxy) }
                        // One scroll handle, not two: the month scrubber stands in for it.
                        .scrollIndicators(mode != .calendar && showsScrubber ? .hidden : .automatic)
                        .modifier(ScrollProgress(tracker: scrollTracker))
                        .overlay(alignment: .trailing) {
                            if mode != .calendar { scrubber(proxy) }
                        }

                    }
            }
            .accessibilityHidden(searching)
            // Laid over the journal rather than swapped in for it: the journal keeps its
            // place for when search closes, and the header above stays the same view, which
            // its opening animation depends on.
            .overlay {
                if searching, let search = services.search, let store = services.store, let files = services.files {
                    SearchResultsView(search: search, store: store, fileStore: files,
                                      query: query, filter: searchFilter) { id, words in
                        path.append(OpeningDraft(id: id, highlight: words))
                    }
                    .transition(.opacity)
                }
            }
            .background(Brand.ground)
            // Pinned above whatever is scrolling, in every view: the title and view switcher,
            // or Cancel / count / All while selecting. Neither can be scrolled away.
            .safeAreaInset(edge: .top, spacing: 0) {
                Group {
                    if selecting {
                        selectionHeader
                    } else if services.search != nil {
                        JournalSearchBar(isOpen: $searching, query: $query, filter: $searchFilter) {
                            modeSwitcher
                        }
                    } else {
                        header
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .background(Brand.ground)
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) { if !selecting && !searching { addButton } }
            .safeAreaInset(edge: .bottom, spacing: 0) { if selecting { selectionBar } }
            // .automatic, not .visible, outside select mode: .visible overrode the entry
            // screen's own request to hide the tabs, stacking them on its toolbar.
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            // Not animated. Animating the header, tab bar and action bar swapping in moved the
            // grid under the finger, and on a long journal it lost its place entirely.
            .sheet(isPresented: $movingSelection) {
                NavigationStack {
                    DatePicker("Day", selection: $moveTo, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .navigationTitle("Move to which day?")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { movingSelection = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Move") { moveSelection(to: CalendarDay(date: moveTo)) }
                                    .fontWeight(.semibold)
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $exportingSelection) {
                if let store = services.store, let files = services.files {
                    ExportView(store: store, fileStore: files,
                               selection: drafts.map(\.id).filter { selection.contains($0) })
                }
            }
            .navigationDestination(for: OpeningDraft.self) { opening in
                EntryScreen(id: opening.id, highlight: opening.highlight)
                    .onDisappear { reload() }
            }
            .sheet(isPresented: $showingQuickDump, onDismiss: { dumpDay = nil }) {
                QuickDumpView(
                    initialDay: dumpDay,
                    onWriteFullEntry: {
                        showingQuickDump = false
                        createDraft(on: dumpDay)
                    },
                    onImportPhotos: {
                        showingQuickDump = false
                        // The import sheet is hosted above the tabs; let this one finish
                        // leaving first, or the second presentation is dropped.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(450))
                            services.imports?.isPresented = true
                        }
                    }
                )
            }
            .sheet(isPresented: $showingInboxDigest) {
                if let store = services.store, let files = services.files {
                    InboxDigestView(digest: services.inboxDigest, store: store, fileStore: files) { id in
                        showingInboxDigest = false
                        path.append(OpeningDraft(id: id))
                    }
                }
            }
            .onChange(of: services.imports?.isPresented ?? false) { _, showing in
                if !showing { reload() }
            }
            .onChange(of: services.backgroundWrites) { _, _ in reload() }
            // Once on appear covers launch and switching back from More, where something may
            // have been restored. (It also ran in a .task, which made launch load it twice.)
            .onAppear { reload() }
        }
    }

    // MARK: - Header

    /// Without search (its index couldn't be opened), just the wordmark and the views.
    private var header: some View {
        HStack {
            Wordmark(size: 26)
            Spacer()
            modeSwitcher
        }
        .padding(.top, 8)
    }

    /// Three pictures rather than three words: what each view looks like is the label.
    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases, id: \.self) { option in
                Button {
                    guard mode != option else { return }
                    Haptics.switched()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { mode = option }
                } label: {
                    // Three pieces, each with its own motion: the capsule slides across, the
                    // icon it lands on fills in, and that icon gives a small bounce.
                    Image(systemName: option.symbol)
                        .symbolVariant(mode == option ? .fill : .none)
                        .symbolEffect(.bounce.down, value: mode == option)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mode == option ? .white : Brand.muted)
                        .frame(width: 38, height: 32)
                        .background {
                            if mode == option {
                                Capsule().fill(Brand.violet)
                                    .matchedGeometryEffect(id: "mode", in: modeSpace)
                            }
                        }
                }
                .buttonStyle(PressableStyle(scale: 0.9, haptic: false))
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Brand.surface, in: Capsule())
    }

    // MARK: - Select mode

    private var selectionHeader: some View {
        HStack {
            Button("Cancel") { endSelecting() }
                .tint(Brand.ink)
            Spacer()
            Text(selection.isEmpty ? "Select entries" : "\(selection.count) selected")
                .font(Type.label(17, .semibold))
                .foregroundStyle(Brand.ink)
            Spacer()
            Button(allVisibleSelected ? "None" : "All") {
                selection = allVisibleSelected ? [] : Set(visibleEntries.map(\.id))
            }
            .tint(Brand.violet)
        }
        .frame(height: 44)
        .padding(.top, 4)
    }

    /// What can be done to everything selected at once.
    private var selectionBar: some View {
        HStack(spacing: 0) {
            Button { duplicateSelection() } label: {
                CompactAction(symbol: "plus.square.on.square", title: "Duplicate", tint: Brand.muted, accent: Brand.Mode.text)
            }
            Button {
                moveTo = selectedDay.representativeDate()
                movingSelection = true
            } label: {
                CompactAction(symbol: "calendar.badge.clock", title: "Change day", tint: Brand.muted, accent: Brand.Mode.extra)
            }
            Button { exportingSelection = true } label: {
                CompactAction(symbol: "square.and.arrow.up", title: "Export", tint: Brand.muted, accent: Brand.Mode.photo)
            }
            Button { arrangeSelection() } label: {
                CompactAction(symbol: "sparkles", title: "Arrange", tint: Brand.violet)
            }
            Button { trashSelection() } label: {
                CompactAction(symbol: "trash", title: "Delete", tint: Brand.failed, accent: Brand.failed)
            }
        }
        .buttonStyle(.toolbarAction)
        .disabled(selection.isEmpty)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The entries the current view is showing, which is what "All" selects.
    private var visibleEntries: [DraftSummary] {
        mode == .calendar ? drafts.filter { $0.entryDateKey == selectedDay.rawValue } : drafts
    }

    private var allVisibleSelected: Bool {
        !visibleEntries.isEmpty && visibleEntries.allSatisfy { selection.contains($0.id) }
    }

    private func beginSelecting(with id: UUID) {
        swallowNextTap = true
        Haptics.committed()
        anchor = id
        selecting = true
        selection = [id]
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    /// Brings the touched entry back into view after the layout settles, without moving
    /// anything if it's already visible (a nil anchor scrolls the least it can).
    private func keep(_ id: UUID?, in proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: nil) }
    }

    /// One handler for every entry in every view: open it, or toggle it while selecting.
    private func tapped(_ id: UUID) {
        if swallowNextTap { swallowNextTap = false; return }
        if selecting {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
            Haptics.picked()
        } else {
            path.append(OpeningDraft(id: id))
        }
    }

    /// Wraps an entry's look in the gestures every view shares.
    ///
    /// The id is for the grid only, where the lazy stack uses it to place a jump quickly
    /// (without it, jumping eight years back took half a minute). In the List it does the
    /// opposite: an explicit id on every row made the List build all of them up front,
    /// which took most of a minute in a journal of a few thousand entries.
    @ViewBuilder
    private func entryButton<Label: View>(_ entry: DraftSummary, @ViewBuilder label: () -> Label) -> some View {
        if mode == .list {
            entryButtonBody(entry, label: label)
        } else {
            entryButtonBody(entry, label: label).id(entry.id)
        }
    }

    private func entryButtonBody<Label: View>(_ entry: DraftSummary, @ViewBuilder label: () -> Label) -> some View {
        Button { tapped(entry.id) } label: {
            label()
                .overlay(alignment: mode == .list ? .trailing : .topTrailing) {
                    if selecting {
                        Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selection.contains(entry.id) ? Brand.violet : .black.opacity(0.35))
                            // So an empty circle still shows up on a white photo.
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            // In a list row it takes the chevron's place on the right.
                            .padding(mode == .list ? 14 : 8)
                    }
                }
        }
        .buttonStyle(.row)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if selecting {
                    selection.insert(entry.id)
                } else {
                    beginSelecting(with: entry.id)
                }
            }
        )
    }

    private func duplicateSelection() {
        let ids = selection
        endSelecting()
        for id in ids { duplicate(id) }
        notice = "Duplicated \(ids.count) \(ids.count == 1 ? "entry" : "entries")."
    }

    private func moveSelection(to day: CalendarDay) {
        guard let store = services.store else { return }
        for id in selection {
            if let draft = try? store.draft(id: id) { try? store.setEntryDate(day, for: draft) }
        }
        let count = selection.count
        movingSelection = false
        endSelecting()
        selectedDay = day
        month = Self.startOfMonth(day.representativeDate())
        reload()
        notice = "Moved \(count) \(count == 1 ? "entry" : "entries") to \(day.representativeDate().formatted(.dateTime.month(.abbreviated).day()))."
    }

    /// Arranges each selected entry in turn, in the background, the way a single one is.
    private func arrangeSelection() {
        let ids = Array(selection)
        endSelecting()
        guard let organising = services.organising else { return }
        let ready = ids.filter { organising.canOrganise(draftId: $0) }
        notice = ready.isEmpty
            ? "Nothing to arrange yet. Arrange needs some writing or a recording."
            : "Arranging \(ready.count) \(ready.count == 1 ? "entry" : "entries")\u{2026}"
        Task {
            for id in ready { _ = await organising.organise(draftId: id) }
            reload()
            if !ready.isEmpty { notice = "Arranged \(ready.count) \(ready.count == 1 ? "entry" : "entries")." }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let notice = services.recoveryNotice {
            RecoveryNotice(message: notice) { services.dismissRecoveryNotice() }
                .padding(12)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        if let notice = services.inboxNotice {
            InboxNotice(message: notice) {
                showingInboxDigest = true
            } onDismiss: {
                services.dismissInboxNotice()
            }
            .padding(12)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        if let notice {
            HStack {
                Text(notice).font(.footnote)
                Spacer()
                if !lastTrashed.isEmpty {
                    Button("Undo") { undoTrash() }
                        .font(.footnote.weight(.semibold))
                        .tint(Brand.violet)
                }
                Button("OK") {
                    self.notice = nil
                    lastTrashed = []
                }
                .font(.footnote)
            }
            .buttonStyle(.borderless)
            .padding(12)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        if let loadError {
            Label(loadError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Brand.failed)
        }
    }

    private var addButton: some View {
        Button {
            dumpDay = mode == .calendar ? selectedDay : nil
            Haptics.committed()
            showingQuickDump = true
        } label: {
            // The plus turns a quarter on its way to the sheet and back when it closes, and
            // the circle swells a little behind it, so the sheet looks like it came out of
            // the button rather than from nowhere.
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(showingQuickDump ? 90 : 0))
                .frame(width: 54, height: 54)
                .background(Brand.violet, in: Circle())
                .scaleEffect(showingQuickDump ? 1.12 : 1)
                .shadow(color: Brand.violet.opacity(0.35), radius: showingQuickDump ? 14 : 8, y: 4)
                .animation(.spring(response: 0.38, dampingFraction: 0.62), value: showingQuickDump)
        }
        .buttonStyle(PressableStyle(scale: 0.9, haptic: false))
        .accessibilityLabel("Dump something")
        .padding(.trailing, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Calendar

    private var calendar: some View {
        VStack(spacing: 12) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(Type.label(19, .semibold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(DayFilter.allCases) { option in
                            Label(option.label, systemImage: option.symbol).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .symbolVariant(filter == .all ? .none : .fill)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(filter == .all ? Brand.ink : Brand.violet)
                }
                .accessibilityLabel("Filter days")
                .onChange(of: filter) { Haptics.picked() }
                .padding(.trailing, 14)
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                    .padding(.trailing, 14)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
            }
            .font(.system(size: 16, weight: .semibold))
            .tint(Brand.ink)

            Text(filterSummary)
                .font(Type.caption(12.5))
                .foregroundStyle(filter == .all ? Brand.muted : Brand.violet)
                .frame(maxWidth: .infinity, alignment: .leading)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Self.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(Type.caption(11.5, .medium))
                        .foregroundStyle(Brand.muted)
                        .frame(height: 20)
                }
            }
            // The days slide in from the side you moved toward; the weekdays above stay put.
            ZStack(alignment: .top) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(monthCells.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day)
                        } else {
                            Color.clear.frame(height: 42)
                        }
                    }
                }
                .id(month)
                .transition(.asymmetric(
                    insertion: .move(edge: monthStep > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: monthStep > 0 ? .leading : .trailing).combined(with: .opacity)
                ))
            }
            .clipped()
            .padding(.top, -6)
        }
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.width < -40 { shiftMonth(1) }
                if value.translation.width > 40 { shiftMonth(-1) }
            }
        )
    }

    /// A day, circled when it matches the filter: a filled circle for days with entries, a
    /// dashed one for days without. A whole circle can't be misread as belonging to the day
    /// above or below, the way a small dot could.
    private func dayCell(_ day: CalendarDay) -> some View {
        let isSelected = day == selectedDay
        let isToday = day == CalendarDay.today()
        let isFuture = day > CalendarDay.today()
        let kind = dayKinds[day]
        let marked = matches(day, kind: kind)
        let showsMissing = filter == .missing
        return Button {
            Haptics.picked()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedDay = day }
        } label: {
            Text(day.representativeDate().formatted(.dateTime.day()))
                .font(Type.label(16, marked || isSelected || isToday ? .semibold : .regular))
                .foregroundStyle(
                    isSelected ? .white
                        : marked && !showsMissing ? Brand.ink
                        : isToday ? Brand.violet
                        : isFuture ? Brand.muted.opacity(0.45)
                        : Brand.muted
                )
                .frame(width: 38, height: 38)
                .background {
                    if isSelected {
                        // Slides from the day you were on to the one you tapped.
                        Circle().fill(Brand.violet)
                            .matchedGeometryEffect(id: "selectedDay", in: modeSpace)
                    } else if marked && showsMissing {
                        Circle().strokeBorder(Brand.muted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    } else if marked {
                        Circle().fill(Brand.violet.opacity(0.28))
                    } else if isToday {
                        Circle().strokeBorder(Brand.violet, lineWidth: 1.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(day.representativeDate().formatted(.dateTime.weekday(.wide).month(.wide).day())), \(describe(kind))"
        )
    }

    private func matches(_ day: CalendarDay, kind: DayKind?) -> Bool {
        switch filter {
        case .all: return kind != nil
        case .both: return kind.map { $0.words && $0.media } ?? false
        case .wordsOnly: return kind.map { $0.words && !$0.media } ?? false
        case .mediaOnly: return kind.map { !$0.words && $0.media } ?? false
        case .missing: return kind == nil && day <= CalendarDay.today()
        }
    }

    private func describe(_ kind: DayKind?) -> String {
        guard let kind else { return "no entry" }
        switch (kind.words, kind.media) {
        case (true, true): return "words and media"
        case (true, false): return "words only"
        case (false, true): return "media only"
        default: return "an empty entry"
        }
    }

    /// "9 days with entries", or what the filter found this month.
    private var filterSummary: String {
        let days = monthCells.compactMap { $0 }.filter { matches($0, kind: dayKinds[$0]) }
        let n = days.count
        let plural = n == 1 ? "day" : "days"
        switch filter {
        case .all: return "\(n) \(plural) with entries"
        case .both: return "\(n) \(plural) with words and media"
        case .wordsOnly: return "\(n) \(plural) with words only"
        case .mediaOnly: return "\(n) \(plural) with media only"
        case .missing: return "\(n) \(plural) without an entry"
        }
    }

    /// The selected day: its entries, or a quiet way to start one.
    @ViewBuilder
    private var dayEntries: some View {
        let entries = drafts.filter { $0.entryDateKey == selectedDay.rawValue }
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedDay.representativeDate().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(Type.caption(12, .semibold))
                .tracking(0.6)
                .foregroundStyle(Brand.muted)

            if entries.isEmpty {
                emptyDay
            } else {
                ForEach(entries) { entry in
                    entryButton(entry) {
                        DayEntryRow(summary: entry, art: art(entry), fileStore: services.files)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var emptyDay: some View {
        let past = selectedDay <= CalendarDay.today()
        return EmptyState(
            title: past ? "Nothing from this day yet" : "This day hasn\u{2019}t happened yet",
            message: past ? "Add a note, photo, or memory from it." : nil,
            mood: past ? .waiting : .content,
            props: past ? [.note, .photo, .mic] : [],
            mascotWidth: 120
        ) {
            if past {
                Button {
                    dumpDay = selectedDay
                    showingQuickDump = true
                } label: {
                    Label("Add note", systemImage: "plus")
                        .font(Type.label(15, .semibold))
                        .padding(.horizontal, 22)
                        .frame(height: 40)
                        .foregroundStyle(.white)
                        .background(Brand.violet, in: Capsule())
                }
                .buttonStyle(.pressablePrimary)
            }
        }
        .padding(.vertical, 18)
    }

    // MARK: - List

    /// The list: a lazy stack like the grid, under the same pinned month headers.
    ///
    /// It was a SwiftUI List, kept for swipe-to-delete. A List prepares every row before it
    /// shows any, and with a few thousand entries that took over a minute; this builds only
    /// the rows on screen. The swipe is `SwipeToTrash`.
    private var listByMonth: some View {
        ForEach(months, id: \.key) { month in
            let band = Brand.isBanded(monthKey: month.key) ? Brand.monthBandRow : Brand.surface
            Section {
                VStack(spacing: 0) {
                    ForEach(Array(month.entries.enumerated()), id: \.element.id) { index, entry in
                        entryButton(entry) {
                            ListEntryRow(summary: entry, art: art(entry), fileStore: services.files, selecting: selecting)
                                .background(band)
                        }
                        .modifier(SwipeToTrash(enabled: !selecting, began: { swallowNextTap = true }) { trash([entry.id]) })
                        if index < month.entries.count - 1 {
                            Divider().padding(.leading, 78).background(band)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, 14)
            } header: {
                monthHeader(month.label, background: Brand.ground)
                    .id(month.key)
            }
        }
    }

    private var gridByMonth: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return ForEach(months, id: \.key) { month in
            let band = Brand.isBanded(monthKey: month.key) ? Brand.monthBand : Brand.ground
            Section {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(month.entries) { entry in
                        entryButton(entry) {
                            GridEntryCard(summary: entry, art: art(entry), fileStore: services.files)
                        }
                    }
                }
                .padding(.bottom, 16)
                // Edge to edge, past the page's side margins, so it reads as a band.
                .background { band.padding(.horizontal, -18) }
            } header: {
                monthHeader(month.label, background: band)
                    .id(month.key)
            }
        }
    }

    /// A month's title, drawn on its own ground so it reads cleanly when pinned over entries.
    private func monthHeader(_ label: String, background: Color) -> some View {
        Text(label)
            .font(Type.label(17, .semibold))
            .foregroundStyle(Brand.ink)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(background)
            .padding(.horizontal, mode == .grid ? -18 : 0)
    }

    private var showsScrubber: Bool { months.count > 1 }

    /// The month column for the list and grid, jumping to a month's section as it's touched.
    @ViewBuilder
    private func scrubber(_ proxy: ScrollViewProxy) -> some View {
        if showsScrubber {
            MonthScrubber(months: scrubberMonths, tracker: scrollTracker) { key in
                proxy.scrollTo(key, anchor: .top)
            }
            // Over the content, not beside it: at rest it's only a slim handle, flush with the
            // edge like a scroll bar. Clear of the pinned header above and the + button below.
            .frame(maxWidth: 280, alignment: .trailing)
            .padding(.top, 12)
            .padding(.bottom, 96)
        }
    }

    private static func scrubberMonths(
        of months: [(key: String, label: String, entries: [DraftSummary])]
    ) -> [MonthScrubber.Month] {
        months.compactMap { month in
            guard let date = CalendarDay(rawValue: month.key + "-01")?.representativeDate() else { return nil }
            return MonthScrubber.Month(
                id: month.key,
                // "Oct '26": a journal spanning years needs the year on every label.
                short: date.formatted(.dateTime.month(.abbreviated)) + " \u{2019}" + date.formatted(.dateTime.year(.twoDigits)),
                full: date.formatted(.dateTime.month(.wide).year())
            )
        }
    }

    /// An entry's photos, read only once its row is actually drawn.
    private func art(_ entry: DraftSummary) -> EntryArtCache.Art {
        artCache.art(for: entry, store: services.store)
    }

    // MARK: - Calendar maths

    private static func startOfMonth(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }

    private func shiftMonth(_ by: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: by, to: month) {
            Haptics.tap()
            monthStep = by
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { month = Self.startOfMonth(next) }
        }
    }

    /// Short weekday names, starting wherever this locale's week starts.
    private static var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month as calendar cells: blanks before the 1st, then each day.
    private var monthCells: [CalendarDay?] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { offset -> CalendarDay? in
            calendar.date(byAdding: .day, value: offset - 1, to: month).map { CalendarDay(date: $0) }
        }
        return Array(repeating: nil, count: leading) + days.map { Optional($0) }
    }

    private var dayKinds: [CalendarDay: DayKind] { kinds }

    /// Per day, whether its entries hold words, media, or both.
    private static func kinds(of drafts: [DraftSummary]) -> [CalendarDay: DayKind] {
        var kinds: [CalendarDay: DayKind] = [:]
        for draft in drafts {
            guard let day = draft.day else { continue }
            var kind = kinds[day] ?? DayKind()
            kind.words = kind.words || draft.hasWords
            kind.media = kind.media || draft.mediaCount > 0
            kinds[day] = kind
        }
        return kinds
    }

    /// Entries by month, newest first, for the list and the grid.
    private static func months(of drafts: [DraftSummary]) -> [(key: String, label: String, entries: [DraftSummary])] {
        let buckets = Dictionary(grouping: drafts) { String($0.entryDateKey.prefix(7)) }
        return buckets.keys.sorted(by: >).map { key in
            let label = CalendarDay(rawValue: key + "-01")?.representativeDate()
                .formatted(.dateTime.month(.wide).year()) ?? key
            return (key, label, (buckets[key] ?? []).sorted { $0.entryDateKey > $1.entryDateKey })
        }
    }

    // MARK: - Actions

    /// Brings the list up to date with the store, doing only the work the change needs.
    ///
    /// Re-reading the whole journal on every return from an entry and every tab switch made
    /// both visibly lag in a journal of a few thousand entries. The store records which
    /// entries each save touched, so nothing changed costs nothing, an edit re-reads one
    /// entry, and only an entry removed for good (or the first load) reads everything.
    private func reload() {
        guard let store = services.store else { return }
        guard let since = loadedRevision else { return reloadAll(store) }
        let changes = store.changes(since: since)
        if changes.isEmpty { return }
        if changes.structural {
            // The store's log keeps the last 500 saves. Fall further behind than that and it
            // can't say which entries changed, so no cached photos can be trusted.
            if changes.revision - since >= 500 { artCache.clear() }
            artCache.forget(changes.draftIds)
            return reloadAll(store)
        }
        do {
            var fresh: [UUID: DraftSummary?] = [:]
            for id in changes.draftIds {
                if let draft = try store.draft(id: id), !draft.isTrashed {
                    fresh[id] = DraftSummary(draft)
                } else {
                    fresh[id] = .some(nil)
                }
            }
            artCache.forget(changes.draftIds)
            if !patch(fresh) {
                var byId = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
                for (id, summary) in fresh { byId[id] = summary }
                apply(byId.values.sorted {
                    ($0.entryDateKey, $0.createdAt) > ($1.entryDateKey, $1.createdAt)
                })
            }
            loadedRevision = changes.revision
        } catch {
            reloadAll(store)
        }
    }

    /// Updates entries in place when none of them moved: each still exists, is still listed,
    /// and is still on the same day. That's the common case, coming back from editing one,
    /// and it needs no re-sort of the journal and no regrouping of every month. Anything else
    /// (an entry added, removed, or moved to another day) returns false for a full rebuild,
    /// so the list is never left showing old words or an entry in the wrong place.
    private func patch(_ fresh: [UUID: DraftSummary?]) -> Bool {
        var plan: [(index: Int, summary: DraftSummary)] = []
        for (id, summary) in fresh {
            guard let summary, let index = drafts.firstIndex(where: { $0.id == id }),
                  drafts[index].entryDateKey == summary.entryDateKey,
                  drafts[index].createdAt == summary.createdAt
            else { return false }
            if drafts[index] != summary { plan.append((index, summary)) }
        }
        // Check every month bucket can take its entry before changing anything.
        var placements: [(month: Int, entry: Int, summary: DraftSummary)] = []
        for (_, summary) in plan {
            let key = String(summary.entryDateKey.prefix(7))
            guard let m = months.firstIndex(where: { $0.key == key }),
                  let e = months[m].entries.firstIndex(where: { $0.id == summary.id })
            else { return false }
            placements.append((m, e, summary))
        }
        guard !plan.isEmpty else { return true }

        for (index, summary) in plan { drafts[index] = summary }
        for placement in placements {
            months[placement.month].entries[placement.entry] = placement.summary
        }
        // Words or photos may have come or gone, which changes how the calendar marks the day.
        for day in Set(plan.compactMap { $0.summary.day }) {
            var kind = DayKind()
            let key = String(day.rawValue.prefix(7))
            for entry in months.first(where: { $0.key == key })?.entries ?? [] where entry.entryDateKey == day.rawValue {
                kind.words = kind.words || entry.hasWords
                kind.media = kind.media || entry.mediaCount > 0
            }
            kinds[day] = kind
        }
        loadError = nil
        return true
    }

    private func reloadAll(_ store: DraftStore) {
        do {
            let revision = store.revision
            let fresh = try store.allDrafts().map(DraftSummary.init)
            // Cached photos are dropped as their entries change (see `reload`), so a full read
            // only needs to let go of the ones for entries that are gone.
            artCache.keepOnly(Set(fresh.map(\.id)))
            apply(fresh)
            loadedRevision = revision
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply(_ fresh: [DraftSummary]) {
        drafts = fresh
        kinds = Self.kinds(of: fresh)
        let grouped = Self.months(of: fresh)
        // The scrubber's labels mean parsing and formatting a date per month, so only when
        // the set of months actually changed.
        if grouped.map(\.key) != months.map(\.key) || scrubberMonths.isEmpty {
            scrubberMonths = Self.scrubberMonths(of: grouped)
        }
        months = grouped
        loadError = nil
    }

    private func createDraft(on day: CalendarDay? = nil) {
        guard let store = services.store else { return }
        do {
            let draft = try store.createDraft(entryDate: day)
            reload()
            path.append(OpeningDraft(id: draft.id))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func duplicate(_ id: UUID) {
        guard let store = services.store, let files = services.files,
              let draft = try? store.draft(id: id) else { return }
        do {
            try store.duplicate(draft, fileStore: files)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Moves entries to Recently Deleted, with a way to change your mind straight away.
    private func trash(_ ids: [UUID]) {
        guard let store = services.store else { return }
        for id in ids {
            if let draft = try? store.draft(id: id) { try? store.moveToTrash(draft) }
        }
        drafts.removeAll { ids.contains($0.id) }
        path.removeAll { ids.contains($0.id) }
        lastTrashed = ids
        notice = ids.count == 1
            ? "Moved to Recently Deleted."
            : "Moved \(ids.count) entries to Recently Deleted."
        reload()
    }

    private func undoTrash() {
        guard let store = services.store else { return }
        for id in lastTrashed {
            if let draft = try? store.draft(id: id) { try? store.restore(draft) }
        }
        lastTrashed = []
        notice = nil
        reload()
    }

    private func trashSelection() {
        let ids = Array(selection)
        endSelecting()
        trash(ids)
    }
}

// MARK: - Rows

/// An entry on the selected day: a photo, its name, the start of what was written, and when.
private struct DayEntryRow: View {
    let summary: DraftSummary
    let art: EntryArtCache.Art
    let fileStore: MediaFileStore?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EntryThumb(art: art, fileStore: fileStore, size: 84)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(Type.label(15.5, .semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                if !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(Type.body(13.5))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(3)
                }
                HStack(spacing: 10) {
                    Text(summary.time)
                    if summary.mediaCount > 0 {
                        Label("\(summary.mediaCount)", systemImage: "photo")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(Type.caption(11.5))
                .foregroundStyle(Brand.muted)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// An entry in the month list: photo, name, and the day with what's attached.
private struct ListEntryRow: View {
    let summary: DraftSummary
    let art: EntryArtCache.Art
    let fileStore: MediaFileStore?
    /// The chevron makes way for the selection tick.
    var selecting = false

    var body: some View {
        HStack(spacing: 12) {
            EntryThumb(art: art, fileStore: fileStore, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(Type.label(15, .medium))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(Type.caption(12.5, .regular))
                    .foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 0)
            if selecting {
                // Room for the tick, so a long title stops short of it instead of under it.
                Color.clear.frame(width: 30, height: 1)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.muted.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var detail: String {
        let count = summary.mediaCount
        guard count > 0 else { return summary.monthDay }
        return "\(summary.monthDay) \u{00B7} \(count) \(count == 1 ? "photo" : "photos")"
    }
}

/// An entry in the grid: its covers, or first few photos, or the start of its writing, with
/// its name and day underneath.
private struct GridEntryCard: View {
    let summary: DraftSummary
    let art: EntryArtCache.Art
    let fileStore: MediaFileStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let fileStore, !art.covers.isEmpty {
                    PhotoMosaic(thumbs: art.covers, overflow: max(0, art.covers.count - 4), fileStore: fileStore)
                } else if let fileStore, !art.thumbs.isEmpty {
                    PhotoMosaic(thumbs: art.thumbs, overflow: art.hidden, fileStore: fileStore)
                } else {
                    Text(summary.preview.isEmpty ? " " : summary.preview)
                        .font(Type.journal(13))
                        .foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                        .background(Brand.panel)
                }
            }
            .frame(height: 130)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(Type.label(14, .semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Text(summary.shortDate)
                    .font(Type.caption(12, .regular))
                    .foregroundStyle(Brand.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// The entry's first cover, or first photo, or a quiet stand-in when it has neither.
private struct EntryThumb: View {
    let art: EntryArtCache.Art
    let fileStore: MediaFileStore?
    let size: CGFloat

    var body: some View {
        Group {
            if let thumb = art.covers.first ?? art.thumbs.first, let fileStore {
                // Decoded at the size it's drawn, three pixels per point, not gallery size.
                PhotoTile(thumb: thumb, fileStore: fileStore, maxPixel: size * 3)
            } else {
                Brand.panel.overlay {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: size * 0.26))
                        .foregroundStyle(Brand.muted)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Shared

/// One entry, resolved by id at the moment it's shown, so a draft deleted underneath it
/// resolves to nothing instead of trapping (ADR-009a).
struct EntryScreen: View {
    @Environment(AppServices.self) private var services
    let id: UUID
    /// Words to find and highlight, when opened from search.
    var highlight: String? = nil
    /// The draft, looked up once rather than on every redraw. Checked each time it's used, so
    /// one deleted underneath the screen still resolves to nothing instead of trapping.
    @State private var resolved = Resolved()
    private final class Resolved {
        var looked = false
        var draft: EntryDraft?
    }

    private func draft(in store: DraftStore) -> EntryDraft? {
        if !resolved.looked {
            resolved.draft = try? store.draft(id: id)
            resolved.looked = true
        }
        guard let draft = resolved.draft, draft.modelContext != nil, !draft.isDeleted else { return nil }
        return draft
    }

    var body: some View {
        if let store = services.store, let files = services.files,
           let draft = draft(in: store) {
            CaptureView(draft: draft, store: store, fileStore: files, highlight: highlight)
        } else {
            EmptyState("This entry isn\u{2019}t here anymore", message: "It may have been deleted. Look in Recently Deleted under More.", mood: .puzzled)
                .frame(maxHeight: .infinity)
        }
    }
}

/// Wrapper so a `UUID` can drive navigation without a retroactive conformance.
struct OpeningDraft: Identifiable, Hashable {
    let id: UUID
    /// Words to find in it, when opened from search.
    var highlight: String? = nil
}

/// Says what the inbox just filed, so something shared from another app is seen to arrive.
/// Tapping it shows exactly what went where.
struct InboxNotice: View {
    let message: String
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(Brand.violet)
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.footnote)
                Button("See what was added", action: onOpen)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.violet)
            }
            Spacer()
            Button("OK", action: onDismiss).font(.footnote)
        }
        .buttonStyle(.borderless)
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

/// Reports how far a scroll view is scrolled, 0 at the top to 1 at the bottom. iOS 18 and
/// later; before that the progress stays unknown and the scrubber handle doesn't track.
///
/// Rounded to a thousandth, so a slow drag doesn't report a new value for every fraction of a
/// point, and written to a tracker only the scrubber reads.
private struct ScrollProgress: ViewModifier {
    let tracker: ScrollProgressTracker

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                let range = geometry.contentSize.height + geometry.contentInsets.top
                    + geometry.contentInsets.bottom - geometry.containerSize.height
                guard range > 1 else { return 0 }
                let fraction = min(max((geometry.contentOffset.y + geometry.contentInsets.top) / range, 0), 1)
                return (fraction * 1000).rounded() / 1000
            } action: { _, value in
                tracker.progress = value
            }
        } else {
            content
        }
    }
}

/// Swipe a row either way to move it to Recently Deleted, the way List rows do, for rows
/// that aren't in a List. A red band with a bin opens behind it as it goes; past a third of
/// the way it lets go into the trash, short of that it springs back. Only clearly sideways
/// drags count, so scrolling past a row never catches on it.
private struct SwipeToTrash: ViewModifier {
    let enabled: Bool
    /// Told when a swipe starts, so the row's tap, which a sideways drag doesn't cancel,
    /// doesn't also open the entry when the finger lifts.
    let began: () -> Void
    let trash: () -> Void
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: offset >= 0 ? .leading : .trailing) {
                if offset != 0 {
                    Color.red
                        .overlay(alignment: offset >= 0 ? .leading : .trailing) {
                            Image(systemName: "trash.fill")
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                        }
                        .frame(width: abs(offset))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard enabled, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        if offset == 0 { began() }
                        offset = value.translation.width
                    }
                    .onEnded { value in
                        guard enabled, offset != 0 else { return }
                        if abs(offset) > width / 3 || abs(value.predictedEndTranslation.width) > width * 0.8 {
                            withAnimation(.easeOut(duration: 0.18)) { offset = offset > 0 ? width : -width }
                            Haptics.committed()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                trash()
                                offset = 0
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                        }
                    }
            )
    }
}
