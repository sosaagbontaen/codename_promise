import Foundation
import Testing
@testable import CodenamePromiseCore

/// Which days the app offers to fill in.
///
/// The rules here are product rules, not arithmetic. A reflection app that tells someone they
/// have missed eighty-nine days has turned a prompt into an accusation, and guilt is the
/// thing that makes people stop journaling — so the feature meant to bring them back would
/// be the one driving them away. These tests pin the kind behaviour.
@Suite("Open days")
struct JournalGapsTests {

    private let utc = TimeZone(identifier: "UTC")!
    private func day(_ raw: String) -> CalendarDay { CalendarDay(rawValue: raw)! }
    private func days(_ raws: String...) -> Set<CalendarDay> { Set(raws.map { day($0) }) }

    // MARK: - Day arithmetic

    @Test("adding days crosses a month boundary")
    func crossesMonths() {
        #expect(day("2026-01-31").adding(days: 1, timeZone: utc) == day("2026-02-01"))
        #expect(day("2026-03-01").adding(days: -1, timeZone: utc) == day("2026-02-28"))
    }

    @Test("adding days handles a leap year")
    func leapYear() {
        #expect(day("2028-02-28").adding(days: 1, timeZone: utc) == day("2028-02-29"))
        #expect(day("2028-02-29").adding(days: 1, timeZone: utc) == day("2028-03-01"))
    }

    // MARK: - The window

    @Test("only days with nothing written come back")
    func reportsOnlyEmptyDays() {
        let open = JournalGaps.openDays(
            from: day("2026-08-01"), through: day("2026-08-05"),
            covered: days("2026-08-02", "2026-08-04"),
            firstEntryDay: day("2026-08-01"), timeZone: utc
        )
        #expect(open == [day("2026-08-05"), day("2026-08-03"), day("2026-08-01")])
    }

    @Test("newest first, because that is the day you can still remember")
    func newestFirst() {
        let open = JournalGaps.openDays(
            from: day("2026-08-01"), through: day("2026-08-03"),
            covered: [], firstEntryDay: day("2026-08-01"), timeZone: utc
        )
        #expect(open == [day("2026-08-03"), day("2026-08-02"), day("2026-08-01")])
    }

    @Test("a fully written window offers nothing")
    func nothingToOffer() {
        let open = JournalGaps.openDays(
            from: day("2026-08-01"), through: day("2026-08-03"),
            covered: days("2026-08-01", "2026-08-02", "2026-08-03"),
            firstEntryDay: day("2026-08-01"), timeZone: utc
        )
        #expect(open.isEmpty)
    }

    // MARK: - The kindness rules

    /// The one that matters most. A person who started yesterday has not missed a year.
    @Test("days before the first entry are never called open")
    func neverInventsABacklog() {
        let open = JournalGaps.openDays(
            from: day("2026-01-01"), through: day("2026-08-05"),
            covered: days("2026-08-04"),
            firstEntryDay: day("2026-08-03"), timeZone: utc
        )
        #expect(open == [day("2026-08-05"), day("2026-08-03")],
                "a window opened before someone started journaling must not become a backlog")
    }

    @Test("someone who has never written anything is shown nothing")
    func newInstallIsNotScolded() {
        let open = JournalGaps.openDays(
            from: day("2026-08-01"), through: day("2026-08-30"),
            covered: [], firstEntryDay: nil, timeZone: utc
        )
        #expect(open.isEmpty, "a fresh install has no backlog, it has a blank page")
    }

    @Test("a first entry after the window ends leaves nothing open")
    func firstEntryAfterWindow() {
        let open = JournalGaps.openDays(
            from: day("2026-01-01"), through: day("2026-01-31"),
            covered: [], firstEntryDay: day("2026-06-01"), timeZone: utc
        )
        #expect(open.isEmpty)
    }

    @Test("an inverted window is empty rather than infinite")
    func invertedWindow() {
        let open = JournalGaps.openDays(
            from: day("2026-08-10"), through: day("2026-08-01"),
            covered: [], firstEntryDay: day("2026-01-01"), timeZone: utc
        )
        #expect(open.isEmpty)
    }

    @Test("a single-day window works")
    func singleDay() {
        #expect(JournalGaps.openDays(
            from: day("2026-08-05"), through: day("2026-08-05"),
            covered: [], firstEntryDay: day("2026-01-01"), timeZone: utc
        ) == [day("2026-08-05")])

        #expect(JournalGaps.openDays(
            from: day("2026-08-05"), through: day("2026-08-05"),
            covered: days("2026-08-05"), firstEntryDay: day("2026-01-01"), timeZone: utc
        ).isEmpty)
    }

    @Test("the window spans a month boundary correctly")
    func spansMonths() {
        let open = JournalGaps.openDays(
            from: day("2026-01-30"), through: day("2026-02-02"),
            covered: days("2026-01-31"),
            firstEntryDay: day("2026-01-01"), timeZone: utc
        )
        #expect(open == [day("2026-02-02"), day("2026-02-01"), day("2026-01-30")])
    }
}

/// The store side of the same feature.
@Suite("Open days from the store")
@MainActor
struct OpenDaysStoreTests {

    private func makeStore() throws -> DraftStore {
        DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
    }
    private func day(_ raw: String) -> CalendarDay { CalendarDay(rawValue: raw)! }

    @Test("entryDays reports exactly the days inside the window")
    func entryDaysInWindow() throws {
        let store = try makeStore()
        for raw in ["2026-07-30", "2026-08-01", "2026-08-01", "2026-08-04", "2026-08-20"] {
            _ = try store.createDraft(entryDate: day(raw))
        }

        let found = try store.entryDays(from: day("2026-08-01"), through: day("2026-08-10"))
        #expect(found == Set([day("2026-08-01"), day("2026-08-04")]),
                "two entries on one day count once, and days outside the window don't count")
    }

    @Test("earliestEntryDay finds the first day written about, not the first created")
    func earliestDay() throws {
        let store = try makeStore()
        // Created in the opposite order to their entry dates, on purpose.
        _ = try store.createDraft(entryDate: day("2026-08-20"))
        _ = try store.createDraft(entryDate: day("2019-03-04"))
        _ = try store.createDraft(entryDate: day("2026-01-01"))

        #expect(try store.earliestEntryDay() == day("2019-03-04"))
    }

    @Test("an empty store has no earliest day")
    func emptyStore() throws {
        #expect(try makeStore().earliestEntryDay() == nil)
    }

    /// End to end: the store's answers feed the pure rule and produce the offer.
    @Test("the days offered are the ones genuinely unwritten")
    func endToEnd() throws {
        let store = try makeStore()
        _ = try store.createDraft(entryDate: day("2026-08-01"))
        _ = try store.createDraft(entryDate: day("2026-08-03"))

        let from = day("2026-07-01"), through = day("2026-08-04")
        let open = JournalGaps.openDays(
            from: from, through: through,
            covered: try store.entryDays(from: from, through: through),
            firstEntryDay: try store.earliestEntryDay(),
            timeZone: TimeZone(identifier: "UTC")!
        )

        #expect(open == [day("2026-08-04"), day("2026-08-02")],
                "July is before they started, so it is not a backlog")
    }
}
