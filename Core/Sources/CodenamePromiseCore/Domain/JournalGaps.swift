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
}
