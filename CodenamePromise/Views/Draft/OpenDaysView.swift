import CodenamePromiseCore
import SwiftUI

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
    @State private var scope: OpenDaysScope = .thisDeviceOnly
    @State private var hasEverWritten = true
    @State private var isChecking = false
    @State private var loadError: String?

    enum Window: String, CaseIterable, Identifiable {
        case week = "Week"
        case month = "Month"
        case quarter = "3 months"

        var id: String { rawValue }
        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            }
        }
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
                        Text("Every day in the last \(window.days) is written up.")
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
                ToolbarItem(placement: .primaryAction) {
                    if isChecking { ProgressView().controlSize(.small) }
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Range", selection: $window) {
                    ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .task(id: window) { await reload() }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(openDays, id: \.rawValue) { day in
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
            } footer: {
                // Says what it is without saying what you failed to do — and, crucially, says
                // what it actually checked, so a local-only answer is never mistaken for the
                // whole truth.
                Text(scopeNote)
            }
        }
    }

    /// What was actually checked. Never let a device-only answer imply it checked Notion.
    private var scopeNote: String {
        switch scope {
        case .deviceAndDestination:
            "Checked this device and your Notion database. Tap a day to start its entry."
        case .thisDeviceOnly:
            connection == nil
                ? "Checked entries on this device. Connect Notion to include days you wrote there."
                : "Couldn't reach Notion, so this only covers entries on this device."
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
            var report = JournalGaps.report(
                from: from, through: through,
                localDays: localDays, destinationDays: nil,
                localFirstEntryDay: earliest
            )
            openDays = report.days
            scope = report.scope
            hasEverWritten = earliest != nil
            loadError = nil

            guard let connection else { return }

            // Then widen it with what the destination already holds. A failure here is not
            // an error to show — it just means the answer stays device-only and says so.
            isChecking = true
            defer { isChecking = false }
            guard let remote = try? await connection.entryDays(from: from, through: through) else {
                return
            }

            report = JournalGaps.report(
                from: from, through: through,
                localDays: localDays, destinationDays: remote,
                localFirstEntryDay: earliest
            )
            openDays = report.days
            scope = report.scope
            hasEverWritten = earliest != nil || !remote.isEmpty
        } catch {
            loadError = error.localizedDescription
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
