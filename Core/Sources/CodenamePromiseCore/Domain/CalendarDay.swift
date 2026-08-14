import Foundation

/// The calendar day an entry is *about*, which is not the instant it was created.
///
/// WWWT is a daily practice, so "which day" is domain data, not a derived view of a
/// timestamp. Journaling at 00:30 on Wednesday about Tuesday must file under Tuesday,
/// and travelling across timezones must not silently re-file old entries. See ADR-006.
///
/// Stored as a `yyyy-MM-dd` string so that lexicographic order equals chronological
/// order — sorting and `#Predicate` range queries work without date arithmetic.
public struct CalendarDay: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    /// Fails for anything that is not a well-formed `yyyy-MM-dd` date.
    public init?(rawValue: String) {
        guard Self.parse(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    /// The calendar day that `date` falls on *in the given timezone*.
    /// Defaults to `.current` because "today" is always the user's today.
    public init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.rawValue = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func today(timeZone: TimeZone = .current) -> CalendarDay {
        CalendarDay(date: Date(), timeZone: timeZone)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Noon on this day in `timeZone` — a safe instant for display formatting that
    /// cannot roll over a day boundary under DST shifts.
    public func representativeDate(in timeZone: TimeZone = .current) -> Date {
        var components = Self.parse(rawValue)!
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)!
    }

    private static func parse(_ raw: String) -> DateComponents? {
        let fields = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        // Reject 2025-02-30 and friends: round-trip through the calendar.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let resolved = calendar.date(from: components),
              calendar.component(.day, from: resolved) == day,
              calendar.component(.month, from: resolved) == month
        else { return nil }

        return components
    }
}
