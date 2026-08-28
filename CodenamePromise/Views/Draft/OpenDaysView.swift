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
        case .checking: .orange
        case .included: .green
        case .failed: .red
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
    /// Called with a brand-new draft for the chosen day, so the list can open it.
    let onStartDay: (EntryDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var window: Window = .month
    @State private var openDays: [CalendarDay] = []
    @State private var check: DestinationCheck = .checking
    @State private var hasEverWritten = true
    @State private var loadError: String?

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
                } else if openDays.isEmpty {
                    ContentUnavailableView {
                        Label("You're all caught up", systemImage: "checkmark.circle")
                    } description: {
                        Text("Every day in the \(window.label.lowercased()) is written up.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Fill in a day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    // A menu rather than a segmented control: five spans do not fit across a
                    // phone, and they would only get shorter and less readable as more are
                    // added.
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
            .task(id: window) { await reload() }
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
        .buttonStyle(.plain)
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

            // Local answer first, so the list is never blocked on the network.
            func apply(_ destinationDays: Set<CalendarDay>?) {
                let report = JournalGaps.report(
                    from: from, through: through,
                    localDays: localDays, destinationDays: destinationDays,
                    localFirstEntryDay: earliest
                )
                openDays = report.days
                hasEverWritten = earliest != nil || !(destinationDays ?? []).isEmpty
            }
            apply(nil)
            loadError = nil

            guard let connection else {
                check = .notConnected("Notion isn't connected — showing this device only")
                return
            }

            check = .checking
            do {
                let remote = try await connection.entryDays(from: from, through: through)
                apply(remote)
                check = .included
            } catch {
                // A failure here is never an error page. The local answer stands; the banner
                // says what it is worth, and offers to try again.
                check = Self.checkState(for: error)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mostRecentOpenDay == nil
                      ? "checkmark.circle.fill" : "calendar.badge.plus")
                    .foregroundStyle(mostRecentOpenDay == nil ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        guard let day = mostRecentOpenDay else { return "You're caught up" }
        let today = CalendarDay.today()
        if day == today { return "Today isn't written up yet" }
        if day == today.adding(days: -1) { return "Yesterday is still open" }
        return "\(day.representativeDate().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) is still open"
    }

    private var subtitle: String {
        mostRecentOpenDay == nil
            ? "Nothing waiting on you."
            : "Tap to fill it in, or pick another day."
    }
}
