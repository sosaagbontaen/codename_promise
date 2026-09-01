import Foundation
import Testing
@testable import CodenamePromiseCore

/// When to nudge somebody, and when to leave them alone.
///
/// A reminder is the one feature that can make a person delete a journaling app, so the rules
/// are conservative on purpose: don't guess from thin history, don't fire at an hour nobody
/// writes, and don't nudge someone who is not actually idle.
@Suite("Writing rhythm")
struct WritingRhythmTests {

    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ raw: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = utc
        return f.date(from: raw)!
    }

    // MARK: - Finding the hour

    @Test("the usual hour is the one they write in most")
    func findsTheCommonHour() {
        let times = [
            at("2026-08-01 21:10"), at("2026-08-02 21:40"),
            at("2026-08-03 22:05"), at("2026-08-04 21:55"),
            at("2026-08-05 09:00"),
        ]
        #expect(WritingRhythm.usualHour(of: times, timeZone: utc) == 21)
    }

    /// Guessing from two entries and then buzzing at the wrong hour every evening is worse
    /// than not buzzing at all.
    @Test("thin history produces no guess at all")
    func refusesToGuess() {
        let times = [at("2026-08-01 21:10"), at("2026-08-02 07:00")]
        #expect(WritingRhythm.usualHour(of: times, timeZone: utc) == nil)
        #expect(WritingRhythm.usualHour(of: [], timeZone: utc) == nil)
    }

    @Test("an even split favours the later hour")
    func tiesGoLate() {
        let times = [
            at("2026-08-01 08:00"), at("2026-08-02 08:30"),
            at("2026-08-03 22:00"), at("2026-08-04 22:30"),
        ]
        #expect(WritingRhythm.usualHour(of: times, timeZone: utc) == 22,
                "an even split is more likely someone writing up a finished day")
    }

    // MARK: - Deciding whether to nudge

    @Test("someone who has never written is not idle, they are new")
    func neverWrittenIsNotIdle() {
        #expect(WritingRhythm.nextNudge(
            lastWrote: nil, idleDays: 7, preferredHour: 21,
            now: at("2026-08-10 12:00"), timeZone: utc
        ) == nil, "that is onboarding's job, not a notification's")
    }

    @Test("the nudge lands at their hour, after the idle period")
    func schedulesAtTheRightHour() {
        let when = WritingRhythm.nextNudge(
            lastWrote: at("2026-08-01 21:00"), idleDays: 7, preferredHour: 21,
            now: at("2026-08-02 10:00"), timeZone: utc
        )
        #expect(when == at("2026-08-08 21:00"))
    }

    @Test("a long-idle person is nudged today, not retroactively")
    func doesNotFireInThePast() {
        let when = WritingRhythm.nextNudge(
            lastWrote: at("2026-01-01 21:00"), idleDays: 7, preferredHour: 21,
            now: at("2026-08-10 12:00"), timeZone: utc
        )
        #expect(when == at("2026-08-10 21:00"),
                "months of idleness produce one nudge at the next good hour, not a backlog")
    }

    /// The rule that keeps this from being hated.
    @Test("a nudge is never scheduled for the middle of the night")
    func neverAtThreeAM() {
        let when = WritingRhythm.nextNudge(
            lastWrote: at("2026-01-01 21:00"), idleDays: 7, preferredHour: 21,
            now: at("2026-08-10 23:30"), timeZone: utc
        )
        #expect(when == at("2026-08-11 21:00"),
                "their hour has already passed today, so it waits for tomorrow's")
    }

    @Test("a zero or negative idle period schedules nothing")
    func noNaggingLoop() {
        #expect(WritingRhythm.nextNudge(
            lastWrote: at("2026-08-01 21:00"), idleDays: 0, preferredHour: 21,
            now: at("2026-08-02 10:00"), timeZone: utc
        ) == nil)
    }
}
