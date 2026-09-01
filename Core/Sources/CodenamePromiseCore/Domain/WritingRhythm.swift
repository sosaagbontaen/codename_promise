import Foundation

/// When this person actually writes.
///
/// A nudge that arrives at a time nobody journals is an interruption; the same words at the
/// hour they already sit down are a reminder. Since the app holds a record of every entry
/// they have ever made, the hour is knowable rather than guessable — and knowing it is the
/// difference between a notification people keep and one they switch off.
///
/// Pure and value-typed, so the rule can be tested without a store, a device, or waiting a
/// day for a notification to fire.
public enum WritingRhythm {

    /// The hour of day this person most often writes, in their own timezone.
    ///
    /// Returns nil when there is not enough history to be confident. Guessing from two
    /// entries and then buzzing someone at the wrong hour every evening is worse than not
    /// buzzing at all, so the caller is expected to fall back to a sensible default rather
    /// than to a bad inference.
    public static func usualHour(
        of entryTimes: [Date],
        minimumSamples: Int = 4,
        timeZone: TimeZone = .current
    ) -> Int? {
        guard entryTimes.count >= minimumSamples else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var counts: [Int: Int] = [:]
        for time in entryTimes {
            counts[calendar.component(.hour, from: time), default: 0] += 1
        }

        // Ties go to the later hour: someone whose entries split evenly between morning and
        // evening is more likely writing up a finished day than starting one.
        return counts
            .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
            .last?
            .key
    }

    /// When the next nudge should fire, given the last time they wrote.
    ///
    /// Nil means don't schedule one: they wrote recently enough that a reminder would just
    /// be noise.
    public static func nextNudge(
        lastWrote: Date?,
        idleDays: Int,
        preferredHour: Int,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Date? {
        guard idleDays > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Someone who has never written is not idle, they are new. Onboarding's job, not a
        // notification's.
        guard let lastWrote else { return nil }

        let earliest = calendar.date(byAdding: .day, value: idleDays, to: lastWrote) ?? now
        let target = Swift.max(earliest, now)

        var components = calendar.dateComponents([.year, .month, .day], from: target)
        components.hour = preferredHour
        components.minute = 0
        guard let atHour = calendar.date(from: components) else { return nil }

        // If that hour has already gone by today, take tomorrow's rather than firing
        // immediately — a nudge at 3am helps nobody.
        return atHour > now
            ? atHour
            : calendar.date(byAdding: .day, value: 1, to: atHour)
    }
}
