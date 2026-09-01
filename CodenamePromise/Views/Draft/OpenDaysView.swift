import CodenamePromiseCore
import SwiftUI

/// How the check against the destination is going, in the user's terms.
///
/// Separated from `OpenDaysScope` because that answers "what was this based on" while this
/// answers "what is happening right now", and the second is what earns trust while a network
/// call is in flight.
///
/// The colours are deliberate, and `notConnected` is deliberately **not** red. Red has to
/// mean something went wrong; a person who simply has not connected Notion has nothing wrong
/// with their setup, and an app that shows them an alarm colour for it is crying wolf. That
/// state is neutral and tells them what it would take to include Notion.
enum DestinationCheck: Equatable {
    /// No destination configured. Nothing is broken.
    case notConnected(String)
    /// Asking the destination now.
    case checking
    /// Answer includes the destination.
    case included
    /// Tried, and could not.
    case failed(String)

    var tint: Color {
        switch self {
        case .notConnected: .secondary
        case .checking: Brand.waiting
        case .included: Brand.reached
        case .failed: Brand.failed
        }
    }

    var symbol: String {
        switch self {
        case .notConnected: "icloud.slash"
        case .checking: "arrow.triangle.2.circlepath"
        case .included: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .notConnected(let why): why
        case .checking: "Checking your Notion database\u{2026}"
        case .included: "Checked this device and Notion"
        case .failed(let why): why
        }
    }

    var isChecking: Bool { self == .checking }
}

/// The days you haven't written up yet, offered rather than counted.
///
/// The tone here is load-bearing. A reflection app that reports a score, a streak, or a
/// number of days missed converts a prompt into an accusation, and guilt is what makes people
/// stop journaling — so the feature meant to bring someone back would be the one driving them
/// away. Hence: no counts of failure, no streak, nothing before the day they started (see
/// `JournalGaps`), and an empty state that reads as a good outcome rather than an absence.
struct OpenDaysView: View {
    let store: DraftStore
    /// Optional on purpose: with no destination connected this still works, it just says so.
    let connection: (any NotionConnectionService)?
    /// Which question the opener was asking. The screen answers both, but arriving on the
    /// wrong one makes the other look missing.
    var initialMode: Mode = .missingDays
    /// Called with a brand-new draft for the chosen day, so the list can open it.
    let onStartDay: (EntryDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var window: Window = .month
    @State private var mode: Mode = .missingDays
    @State private var openDays: [CalendarDay] = []
    @State private var thinEntries: [ThinEntry] = []
    /// The unfiltered inputs, kept so toggling a chip does not re-read Notion. Classifying
    /// costs one request per page over there; narrowing a list already on screen is free.
    @State private var localEntries: [LocalEntryRow] = []
    @State private var destinationEntries: [DestinationEntryRow]?
    /// Which kinds of unfinished count. All three by default - narrowing is for when you
    /// have come here to do one specific job, like putting photos on last month's writing.
    @State private var shortfalls: Set<EntryShortfall> = Set(EntryShortfall.allCases)
    @State private var check: DestinationCheck = .checking
    @State private var hasEverWritten = true
    @State private var loadError: String?

    /// The two ways a journal has holes in it.
    ///
    /// Deliberately one screen rather than two features. Both answer "what have I not
    /// finished", both are bounded by the same window, and both are checked against the same
    /// two places - the split is only in what counts as a hole. Someone who opens this is
    /// asking one question; making them find two menu items to answer it would be worse.
    enum Mode: String, CaseIterable, Identifiable {
        /// Days with no entry at all.
        case missingDays
        /// Entries that exist and are not finished.
        case unfinished

        var id: String { rawValue }

        var label: String {
            switch self {
            case .missingDays: "Missing days"
            case .unfinished: "Unfinished"
            }
        }
    }

    /// Both inputs to a reload, so changing either re-runs it exactly once.
    private struct ReloadKey: Equatable {
        let window: Window
        let mode: Mode
    }

    /// How far back to look.
    ///
    /// Longer ranges are cheap to compute — Notion returns 100 pages per request, so a year
    /// is a handful of calls, and the day-by-day walk is a few hundred iterations. What they
    /// cost is *tone*: a year of sparse journaling is a very long list of days you did not
    /// write. That is why anything past a month groups by month below, so the answer reads
    /// as "August has a gap" rather than as three hundred individual reproaches.
    ///
    /// Deliberately stops at a year rather than offering "all time". The window is already
    /// clamped to the first entry, so "all time" would mean *every day since you started* —
    /// for someone with years of history that is thousands of rows and no way to act on
    /// them. A year is the longest span anyone audits in practice.
    enum Window: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90
        case halfYear = 182
        case year = 365

        var id: Int { rawValue }
        var days: Int { rawValue }

        /// Phrased as a span, because "Month" alone could mean this month or the last 30
        /// days and the difference matters when you are hunting a gap.
        var label: String {
            switch self {
            case .week: "Past 7 days"
            case .month: "Past 30 days"
            case .quarter: "Past 3 months"
            case .halfYear: "Past 6 months"
            case .year: "Past year"
            }
        }

        /// Past a month, a flat list stops being readable.
        var groupsByMonth: Bool { days > 31 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't read your journal", systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if !hasEverWritten {
                    ContentUnavailableView {
                        Label("Nothing to catch up on", systemImage: "sun.horizon")
                    } description: {
                        Text("Once you've written a few entries, the days you haven't filled in yet will show up here.")
                    }
                } else if mode == .missingDays {
                    if openDays.isEmpty {
                        ContentUnavailableView {
                            Label("You're all caught up", systemImage: "checkmark.circle")
                        } description: {
                            Text("Every day in the \(window.label.lowercased()) is written up.")
                        }
                    } else {
                        list
                    }
                } else {
                    if shortfalls.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing selected", systemImage: "line.3.horizontal.decrease")
                        } description: {
                            Text("Turn on at least one kind above.")
                        }
                    } else if thinEntries.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing left half-done", systemImage: "checkmark.circle")
                        } description: {
                            Text("Every entry in the \(window.label.lowercased()) has both words and photos.")
                        }
                    } else {
                        unfinishedList
                    }
                }
            }
            .navigationTitle("Fill in the gaps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    // Segmented here and a menu below, on purpose: two modes fit across a
                    // phone and want to be visible at once, five date spans do not.
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if mode == .unfinished { shortfallFilter }

                    Menu {
                        Picker("Range", selection: $window) {
                            ForEach(Window.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(window.label).font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                    }

                    statusBanner
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .onAppear { mode = initialMode }
            .task(id: ReloadKey(window: window, mode: mode)) { await reload() }
            // Chips re-filter, they do not re-fetch. Re-reading Notion because somebody
            // narrowed a list they are already looking at would be a page request per entry
            // for no new information.
            .onChange(of: shortfalls) { _, _ in refilter() }
        }
    }

    /// Says what is happening, in colour, with a way to ask again.
    ///
    /// Retry is always offered, not only after a failure: the destination can change
    /// underneath the app at any time — a page written on a laptop five minutes ago is
    /// invisible here until something asks Notion again.
    private var statusBanner: some View {
        HStack(spacing: 8) {
            Group {
                if check.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: check.symbol)
                }
            }
            .foregroundStyle(check.tint)
            .frame(width: 16)

            Text(check.label)
                .font(.caption)
                .foregroundStyle(check == .included ? .secondary : check.tint)
                .lineLimit(2)

            Spacer(minLength: 4)

            if connection != nil {
                Button {
                    Task { await reload() }
                } label: {
                    Label(retryLabel, systemImage: "arrow.clockwise")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .disabled(check.isChecking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var retryLabel: String {
        if case .failed = check { return "Retry" }
        return "Check again"
    }

    private var list: some View {
        List {
            if window.groupsByMonth {
                ForEach(monthGroups, id: \.key) { group in
                    Section {
                        ForEach(group.days, id: \.rawValue) { dayRow($0) }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            // A locating count, not a score: the whole point of a long range
                            // is finding *which* month has the gap.
                            Text("\(group.days.count) open")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(openDays, id: \.rawValue) { dayRow($0) }
                }
            }

            Section {
                // Says what it is without saying what you failed to do. What was *checked*
                // lives in the banner, where it is visible before you scroll.
                Text("Tap a day to start its entry. Photos from that day can be added with Import.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        // Pull-to-refresh as well as the button: this is a list that goes stale by nature.
        .refreshable { await reload() }
    }

    /// Three toggles, and turning them all off is allowed.
    ///
    /// Chips rather than a menu because the filter changes what the list *means* - a list of
    /// entries missing photos and a list of everything unfinished look identical otherwise,
    /// and a filter you cannot see is one you forget you set.
    private var shortfallFilter: some View {
        HStack(spacing: 6) {
            ForEach(EntryShortfall.allCases) { kind in
                let on = shortfalls.contains(kind)
                Button {
                    if on { shortfalls.remove(kind) } else { shortfalls.insert(kind) }
                    Haptics.picked()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: kind.symbol).font(.system(size: 10, weight: .semibold))
                        Text(kind.label)
                    }
                    .font(Type.caption(11.5, .semibold))
                    .foregroundStyle(on ? Self.tint(for: kind) : Brand.muted)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        Capsule().fill(
                            on ? Self.tint(for: kind).opacity(0.16) : Color.primary.opacity(0.06)
                        )
                    )
                }
                .buttonStyle(.pressable)
            }
            Spacer(minLength: 0)
        }
    }

    /// The badge wears the colour of the thing that is missing, borrowed from the capture
    /// buttons - so "no photos yet" is green because Photo is green. One vocabulary.
    private static func tint(for kind: EntryShortfall) -> Color {
        switch kind {
        case .empty: Brand.Mode.extra
        case .noText: Brand.Mode.text
        case .noMedia: Brand.Mode.photo
        }
    }

    private var unfinishedList: some View {
        List {
            Section {
                ForEach(thinEntries) { unfinishedRow($0) }
            }

            Section {
                Text("Tap one to finish it. Entries already in Notion are added to, never replaced.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .refreshable { await reload() }
    }

    private func unfinishedRow(_ entry: ThinEntry) -> some View {
        Button {
            finish(entry)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayTitle)
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        // Only when the title is not already the date. An untitled entry is
                        // named after its day on the line above, and seeing the same date
                        // twice in two formats read as a bug rather than as detail.
                        if entry.hasOwnTitle {
                            Text(entry.day.representativeDate()
                                .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.secondary)
                        }
                        Image(systemName: entry.shortfall.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(entry.shortfall.rowLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(Self.tint(for: entry.shortfall))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                // Says what tapping will do. An entry that only exists in Notion gets a draft
                // bound to its page, so the words land on the page that is already there.
                Image(systemName: entry.isInDestinationOnly ? "text.append" : "square.and.pencil")
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }

    /// Opens the local draft, or makes one bound to the existing page.
    private func finish(_ entry: ThinEntry) {
        do {
            switch entry.source {
            case .local(let id):
                guard let draft = try store.draft(id: id) else {
                    // Deleted while the list was on screen. Re-read rather than trap.
                    reloadSoon()
                    return
                }
                Haptics.picked()
                dismiss()
                onStartDay(draft)
            case .destination(let pageId):
                let draft = try store.createDraft(entryDate: entry.day)
                try store.attachToExistingPage(pageId, title: entry.title, for: draft)
                Haptics.picked()
                dismiss()
                onStartDay(draft)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Re-runs the rule over what has already been fetched.
    private func refilter() {
        thinEntries = JournalCompleteness.thinEntries(
            local: localEntries, destination: destinationEntries, matching: shortfalls
        )
    }

    /// Kicks a reload without making the caller async.
    private func reloadSoon() {
        Task { await reload() }
    }

    private func dayRow(_ day: CalendarDay) -> some View {
        Button {
            start(day)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.representativeDate()
                        .formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.body)
                    Text(relativeLabel(for: day))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }

    private struct MonthGroup {
        let key: String
        let title: String
        let days: [CalendarDay]
    }

    /// Newest month first, preserving the newest-first order within each.
    private var monthGroups: [MonthGroup] {
        var order: [String] = []
        var buckets: [String: [CalendarDay]] = [:]
        for day in openDays {
            let key = String(day.rawValue.prefix(7))   // yyyy-MM sorts chronologically
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(day)
        }
        return order.map { key in
            let days = buckets[key] ?? []
            return MonthGroup(
                key: key,
                title: days.first?.representativeDate()
                    .formatted(.dateTime.month(.wide).year()) ?? key,
                days: days
            )
        }
    }

    private func relativeLabel(for day: CalendarDay) -> String {
        let today = CalendarDay.today()
        if day == today { return "Today" }
        if day == today.adding(days: -1) { return "Yesterday" }
        return day.representativeDate().formatted(.relative(presentation: .named))
    }

    private func reload() async {
        do {
            let through = CalendarDay.today()
            let from = through.adding(days: -(window.days - 1))
            let localDays = try store.entryDays(from: from, through: through)
            let earliest = try store.earliestEntryDay()

            localEntries = try store.entryCompleteness(from: from, through: through)
            destinationEntries = nil

            // Local answer first, so the list is never blocked on the network. Both modes
            // follow the same shape: answer from the device, then widen if the destination
            // can be reached, then say in the banner which of the two you are looking at.
            func apply(days destinationDays: Set<CalendarDay>?) {
                let report = JournalGaps.report(
                    from: from, through: through,
                    localDays: localDays, destinationDays: destinationDays,
                    localFirstEntryDay: earliest
                )
                openDays = report.days
                hasEverWritten = earliest != nil || !(destinationDays ?? []).isEmpty
            }
            func apply(entries rows: [DestinationEntryRow]?) {
                destinationEntries = rows
                refilter()
                hasEverWritten = earliest != nil || !(rows ?? []).isEmpty
            }

            switch mode {
            case .missingDays: apply(days: nil)
            case .unfinished: apply(entries: nil)
            }
            loadError = nil

            guard let connection else {
                check = .notConnected("Notion isn't connected — showing this device only")
                return
            }

            check = .checking
            do {
                switch mode {
                case .missingDays:
                    apply(days: try await connection.entryDays(from: from, through: through))
                case .unfinished:
                    // Costs a request per page, so it is only asked for in the mode that
                    // needs it - a day-level check never reads a page at all.
                    apply(entries: try await connection.entryCoverage(from: from, through: through))
                }
                check = .included
            } catch let error {
                // A failure here is never an error page. The local answer stands; the banner
                // says what it is worth, and offers to try again.
                let state = Self.checkState(for: error)
                if case .failed = state { Haptics.failed() }
                check = state
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Distinguishes "not set up" from "went wrong", because only the second deserves red.
    private static func checkState(for error: Error) -> DestinationCheck {
        guard let apiError = error as? APIError else {
            return .failed("Couldn't check Notion — showing this device only")
        }
        switch apiError {
        case .notConfigured:
            return .notConnected("No backend configured — showing this device only")
        case .server(let status, let message) where status == 409:
            // "Pick a Notion database first" is a setup step, not a fault.
            return .notConnected(message ?? "Pick a Notion database to include it")
        case .offline:
            return .failed("Offline — showing this device only")
        default:
            return .failed("Couldn't reach Notion — showing this device only")
        }
    }

    private func start(_ day: CalendarDay) {
        do {
            let draft = try store.createDraft(entryDate: day)
            Haptics.picked()
            dismiss()
            onStartDay(draft)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// The row that offers the feature from the top of the draft list.
///
/// Always present, with the copy changing rather than the row disappearing: when there is
/// nothing open, "you're caught up" is a small good moment, and a feature that vanishes on
/// success is one nobody learns exists.
///
/// It names **the most recent open day** rather than counting them. "28 open days in the last
/// 30" is a report card — accurate, discouraging, and impossible to act on. "Yesterday is
/// still open" is a specific day the person can still remember, which is the only one they
/// were realistically going to write anyway.
struct OpenDaysPrompt: View {
    /// The newest day with nothing written for it, or nil when everything is filled in.
    let mostRecentOpenDay: CalendarDay?
    /// Handed the mode the row was offering, so tapping "Unfinished" does not open on
    /// "Missing days" and read as a dead end.
    let action: (OpenDaysView.Mode) -> Void

    /// A line with a button on it, rather than a line that happens to be tappable.
    ///
    /// This was a full card, and flattening it to plain text went one step too far: the row
    /// still opened the gap finder, but nothing about it said so, and the feature behind it
    /// became something people found by accident. Coloured text is not an affordance - a
    /// tinted capsule with a chevron is.
    ///
    /// So the container comes back at the size of the *action* rather than the size of the
    /// row. The nudge stays a footnote; the thing you can press looks pressable.
    ///
    /// It is also the only violet here, which is the palette rule: violet marks what you can
    /// act on right now.
    var body: some View {
        Button {
            action(mostRecentOpenDay == nil ? .unfinished : .missingDays)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mostRecentOpenDay == nil
                      ? "checkmark.circle.fill" : "calendar.badge.plus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(mostRecentOpenDay == nil ? Brand.reached : Brand.muted)
                Text(title)
                    .font(Type.caption(12.5, .medium))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 6)

                HStack(spacing: 2) {
                    Text(callToAction)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .font(Type.caption(11.5, .semibold))
                .foregroundStyle(Brand.violet)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Brand.violet.opacity(0.14)))
                .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }

    /// Says what is behind the row, and there is something behind it either way.
    ///
    /// Being caught up on *days* does not mean there is nothing to do - the same screen also
    /// finds entries that were started and never finished, which is the more common backlog.
    /// A row that goes inert on success would hide the half of the feature people need most.
    private var callToAction: String {
        mostRecentOpenDay == nil ? "Unfinished" : "Fill it in"
    }

    private var title: String {
        guard let day = mostRecentOpenDay else { return "You're caught up" }
        let today = CalendarDay.today()
        if day == today { return "Today isn't written up yet" }
        if day == today.adding(days: -1) { return "Yesterday is still open" }
        return "\(day.representativeDate().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) is still open"
    }

}
