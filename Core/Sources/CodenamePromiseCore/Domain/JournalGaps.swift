import Foundation

extension CalendarDay {
    /// The day `days` after this one (negative counts go backwards).
    ///
    /// Goes through the calendar rather than through string arithmetic, so month ends,
    /// leap days and DST are somebody else's problem.
    public func adding(days: Int, timeZone: TimeZone = .current) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shifted = calendar.date(
            byAdding: .day, value: days, to: representativeDate(in: timeZone)
        )!
        return CalendarDay(date: shifted, timeZone: timeZone)
    }
}

/// Which days in a window have nothing written for them.
///
/// The point of this is an invitation, not an audit. Two deliberate consequences:
///
/// - **Nothing before the first entry counts as open.** A person who installed the app
///   yesterday has not "missed" the previous eighty-nine days, and showing them a backlog of
///   days they were never going to write is how a reflection app becomes a source of guilt.
///   Guilt is what makes people stop journaling, so the feature meant to bring them back
///   would drive them away.
/// - **Days are returned newest first**, because the most recent open day is the one someone
///   can actually still remember.
///
/// Pure and value-typed so the rule above can be tested without a store or a simulator.
/// What an open-days answer was actually based on.
///
/// The distinction is the whole safety story. The device only knows about entries it
/// captured itself; someone arriving with years of journal in Notion has a history the app
/// has never seen. Reporting "you missed this week" from the local store alone would be
/// confidently wrong about most of it &mdash; and telling someone they skipped a week they
/// actually wrote is precisely the guilt this feature exists to avoid causing.
///
/// So the answer carries its own scope, and the UI says which one it got.
public enum OpenDaysScope: Hashable, Sendable {
    /// Local entries only: the destination was not connected, or could not be reached.
    case thisDeviceOnly
    /// Local entries plus the days already present in the destination.
    case deviceAndDestination
}

/// An answer, and what it was based on.
public struct OpenDaysReport: Hashable, Sendable {
    public let days: [CalendarDay]
    public let scope: OpenDaysScope

    public init(days: [CalendarDay], scope: OpenDaysScope) {
        self.days = days
        self.scope = scope
    }
}

public enum JournalGaps {

    /// Days between `from` and `through` (inclusive) with no entry filed against them.
    ///
    /// - Parameters:
    ///   - covered: days that already have at least one entry.
    ///   - firstEntryDay: the earliest day the user has ever written about. Days before it
    ///     are never reported. `nil` means they have never written anything, in which case
    ///     there is no backlog to report at all.
    public static func openDays(
        from: CalendarDay,
        through: CalendarDay,
        covered: Set<CalendarDay>,
        firstEntryDay: CalendarDay?,
        timeZone: TimeZone = .current
    ) -> [CalendarDay] {
        guard from <= through, let firstEntryDay else { return [] }

        let start = Swift.max(from, firstEntryDay)
        guard start <= through else { return [] }

        var open: [CalendarDay] = []
        var day = start
        while day <= through {
            if !covered.contains(day) { open.append(day) }
            day = day.adding(days: 1, timeZone: timeZone)
        }
        return open.reversed()
    }

    /// The same question, answered against the device *and* the destination.
    ///
    /// `destinationDays` is nil when the destination is not connected or could not be
    /// reached. The window is still answered — a local-only answer is useful — but it comes
    /// back marked `.thisDeviceOnly` so the UI can say so rather than implying it checked
    /// everywhere.
    ///
    /// `firstEntryDay` widens to whichever is earlier, since a day written in Notion long
    /// before the app existed proves the practice started earlier than the local store shows.
    public static func report(
        from: CalendarDay,
        through: CalendarDay,
        localDays: Set<CalendarDay>,
        destinationDays: Set<CalendarDay>?,
        localFirstEntryDay: CalendarDay?,
        timeZone: TimeZone = .current
    ) -> OpenDaysReport {
        let covered = localDays.union(destinationDays ?? [])

        // Earliest evidence of journaling from either side.
        let earliestRemote = destinationDays?.min()
        let earliest: CalendarDay? = switch (localFirstEntryDay, earliestRemote) {
        case let (local?, remote?): Swift.min(local, remote)
        case let (local?, nil): local
        case let (nil, remote?): remote
        case (nil, nil): nil
        }

        return OpenDaysReport(
            days: openDays(
                from: from, through: through,
                covered: covered,
                firstEntryDay: earliest,
                timeZone: timeZone
            ),
            scope: destinationDays == nil ? .thisDeviceOnly : .deviceAndDestination
        )
    }
}
