import Foundation
import Testing
@testable import CodenamePromiseCore

/// The signal that tells a quiet open day from a loud one.
///
/// The arithmetic here is trivial; the product rules are not. An app that counts what you
/// did and shows you the number is one wording change away from scoring you, and this is the
/// place in the codebase where that would happen first. These tests pin the wording and the
/// threshold as much as the sums.
@Suite("Day activity")
struct DayActivityTests {

    private func day(_ raw: String) -> CalendarDay { CalendarDay(rawValue: raw)! }
    private func activity(_ raw: String, photos: Int = 0, videos: Int = 0) -> DayActivity {
        DayActivity(day: day(raw), photos: photos, videos: videos)
    }

    // MARK: - How it reads

    @Test("both kinds are named")
    func bothKinds() {
        #expect(activity("2026-08-17", photos: 23, videos: 4).phrase == "23 photos and 4 videos")
    }

    @Test("a kind with nothing in it is not mentioned")
    func onlyWhatIsThere() {
        #expect(activity("2026-08-17", photos: 23).phrase == "23 photos")
        #expect(activity("2026-08-17", videos: 4).phrase == "4 videos")
    }

    @Test("one of something is singular")
    func singular() {
        #expect(activity("2026-08-17", photos: 1).phrase == "1 photo")
        #expect(activity("2026-08-17", videos: 1).phrase == "1 video")
        #expect(activity("2026-08-17", photos: 1, videos: 1).phrase == "1 photo and 1 video")
    }

    @Test("a day with nothing on it says nothing")
    func empty() {
        #expect(activity("2026-08-17").phrase == "")
    }

    /// The tone rule, asserted rather than trusted to review. Every one of these words has
    /// appeared in a real journaling app, and every one of them turns a count into a verdict.
    @Test("the phrase never editorialises")
    func staysNeutral() {
        let phrase = activity("2026-08-17", photos: 23, videos: 4).phrase
        for word in ["only", "still", "missed", "forgot", "should", "!"] {
            #expect(!phrase.lowercased().contains(word), "phrase should not contain '\(word)'")
        }
    }

    // MARK: - What counts as worth surfacing

    @Test("a single stray item is not a day worth writing up")
    func oneIsNoise() {
        #expect(!activity("2026-08-17", photos: 1).isInteresting())
        #expect(!activity("2026-08-17", photos: 2).isInteresting())
    }

    @Test("photos and videos count towards the same threshold")
    func kindsAddUp() {
        // Two photos and a video is a day with something on it, however it is split.
        #expect(activity("2026-08-17", photos: 2, videos: 1).isInteresting())
    }

    @Test("three is the line")
    func theLine() {
        #expect(activity("2026-08-17", photos: 3).isInteresting())
        #expect(DayActivity.interestingThreshold == 3)
    }

    // MARK: - Feeding it into the open-days list

    @Test("only open days with enough behind them come back")
    func filtersQuietDays() {
        let open = [day("2026-08-19"), day("2026-08-18"), day("2026-08-17")]
        let found = MemoryTriggers.interesting(
            openDays: open,
            activity: [
                day("2026-08-19"): activity("2026-08-19", photos: 1),
                day("2026-08-17"): activity("2026-08-17", photos: 23, videos: 4),
            ]
        )
        #expect(found.map(\.day) == [day("2026-08-17")])
    }

    /// A loud day from months ago must not jump ahead of a quiet one from yesterday. The day
    /// someone can still write about is the recent one, so volume filters and recency sorts.
    @Test("the calendar order is kept, not re-ranked by volume")
    func recencyWinsOverVolume() {
        let open = [day("2026-08-19"), day("2026-06-02")]
        let found = MemoryTriggers.interesting(
            openDays: open,
            activity: [
                day("2026-08-19"): activity("2026-08-19", photos: 3),
                day("2026-06-02"): activity("2026-06-02", photos: 140),
            ]
        )
        #expect(found.map(\.day) == [day("2026-08-19"), day("2026-06-02")])
    }

    /// A day that is already written up is not an invitation, however many photos are on it.
    @Test("a day that is not open is never offered")
    func onlyOpenDays() {
        let found = MemoryTriggers.interesting(
            openDays: [day("2026-08-19")],
            activity: [day("2026-08-17"): activity("2026-08-17", photos: 23)]
        )
        #expect(found.isEmpty)
    }

    @Test("no library access means no suggestions, not an empty-looking day")
    func noActivityAtAll() {
        let open = [day("2026-08-19"), day("2026-08-18")]
        #expect(MemoryTriggers.interesting(openDays: open, activity: [:]).isEmpty)
    }
}
