import Foundation

/// The "WWWT 10/27/26" title: a prefix someone uses over and over, then the entry's day.
///
/// The prefix is learned from titles already written rather than assumed, so a journal kept
/// as "Day 10/27/26" gets "Day" suggested. With nothing to learn from it's "WWWT".
public enum TitleSuggestion {
    public static let defaultPrefix = "WWWT"

    /// The most common "<prefix> M/D/YY" prefix among `titles`.
    public static func prefix(from titles: some Sequence<String>) -> String {
        var counts: [String: Int] = [:]
        for title in titles {
            guard let match = title.firstMatch(of: /^(.+?)\s+\d{1,2}\/\d{1,2}\/\d{2,4}$/) else { continue }
            counts[String(match.1), default: 0] += 1
        }
        // Ties break alphabetically so the suggestion doesn't flicker between launches.
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? defaultPrefix
    }

    public static func title(prefix: String, day: CalendarDay) -> String {
        let date = day.representativeDate()
            .formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year(.twoDigits))
        return "\(prefix) \(date)"
    }
}
