import Foundation

/// How much of a day already exists in the camera roll.
///
/// `JournalGaps` can say "the 17th is empty". It cannot say whether the 17th was *worth*
/// writing about, so every open day arrives looking identical and a list of thirty of them
/// is thirty equally weightless invitations. The camera roll knows the difference: a day
/// with twenty-three photos and four videos on it was a day something happened.
///
/// This is the one new signal — the direction document's #2 — and it feeds the machinery
/// that is already there rather than starting a second one beside it.
///
/// **Counts, never pixels.** Producing one of these needs to know how many items a day
/// holds and nothing about what is in them. The photos themselves are read only later, and
/// only for a day the person has actually opened. Keeping that line sharp is what lets the
/// permission be explained honestly.
public struct DayActivity: Hashable, Sendable {
    public let day: CalendarDay
    public let photos: Int
    public let videos: Int

    public init(day: CalendarDay, photos: Int, videos: Int) {
        self.day = day
        self.photos = photos
        self.videos = videos
    }

    public var total: Int { photos + videos }

    /// Whether there is enough here to be worth putting in front of someone.
    ///
    /// The threshold exists because the alternative is worse in both directions. Surfacing
    /// every day with a single item on it turns the list back into undifferentiated noise —
    /// one photo is a parking bay, a receipt, a shopping list — and the signal that was
    /// supposed to rank the days stops ranking anything. Setting it high would drop the
    /// quiet-but-real day: three photos at dinner is an evening someone might want back.
    ///
    /// Three is the smallest number that reads as "I was taking pictures of something"
    /// rather than "I photographed a thing I needed to remember".
    public static let interestingThreshold = 3

    public func isInteresting(threshold: Int = interestingThreshold) -> Bool {
        total >= threshold
    }

    /// "23 photos and 4 videos", "1 photo", "4 videos".
    ///
    /// Stated as a fact and nothing else. No "you only", no "still no entry", no exclamation
    /// mark — the tone rule from `JournalGaps` is that this whole area offers rather than
    /// accuses, and a count is the easiest place in the app to accidentally start scoring
    /// somebody. It says what is on the phone. What that is worth is the reader's call.
    public var phrase: String {
        switch (photos, videos) {
        case (0, 0): ""
        case (let p, 0): Self.count(p, "photo")
        case (0, let v): Self.count(v, "video")
        case (let p, let v): "\(Self.count(p, "photo")) and \(Self.count(v, "video"))"
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

public enum MemoryTriggers {

    /// The open days that have something behind them, newest first.
    ///
    /// Order is inherited from `openDays` rather than being re-sorted by count, and that is
    /// deliberate. Ranking by volume would put a forty-photo day from March above yesterday,
    /// and the day someone can still actually write about is the recent one — the same
    /// reasoning that makes `JournalGaps` return newest first. The counts are here to tell
    /// the quiet days from the loud ones, not to reorder the calendar.
    public static func interesting(
        openDays: [CalendarDay],
        activity: [CalendarDay: DayActivity],
        threshold: Int = DayActivity.interestingThreshold
    ) -> [DayActivity] {
        openDays.compactMap { day in
            guard let found = activity[day], found.isInteresting(threshold: threshold)
            else { return nil }
            return found
        }
    }
}
