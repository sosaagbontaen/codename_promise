import Foundation
import Testing
@testable import CodenamePromiseCore

/// Finding entries that were started and never finished.
///
/// The day-level gap finder is structurally blind to these: the day has a page on it, so the
/// day is covered. Every case below is one the old check would report as fine.
@Suite("Unfinished entries")
struct JournalCompletenessTests {

    private func day(_ raw: String) -> CalendarDay { CalendarDay(rawValue: raw)! }

    private func local(
        _ raw: String, title: String? = nil,
        words: Bool, media: Bool, page: String? = nil
    ) -> LocalEntryRow {
        LocalEntryRow(
            id: UUID(), day: day(raw), title: title,
            hasWords: words, hasMedia: media, linkedPageId: page
        )
    }

    private func remote(
        _ raw: String, page: String, title: String? = nil, words: Bool, media: Bool
    ) -> DestinationEntryRow {
        DestinationEntryRow(
            pageId: page, day: day(raw), title: title, hasWords: words, hasMedia: media
        )
    }

    // MARK: - Classification

    @Test("an entry with both is not reported at all")
    func completeEntriesAreSilent() {
        #expect(EntryShortfall.of(hasWords: true, hasMedia: true) == nil)
    }

    @Test("each half-finished shape gets its own name")
    func shapes() {
        #expect(EntryShortfall.of(hasWords: false, hasMedia: false) == .empty)
        #expect(EntryShortfall.of(hasWords: false, hasMedia: true) == .noText)
        #expect(EntryShortfall.of(hasWords: true, hasMedia: false) == .noMedia)
    }

    // MARK: - The two real use cases

    @Test("photos dropped in with the writing left for later")
    func photosWithoutWords() {
        let found = JournalCompleteness.thinEntries(
            local: [local("2026-08-14", words: false, media: true)], destination: nil
        )
        #expect(found.map(\.shortfall) == [.noText])
    }

    @Test("written up with the pictures left for later")
    func wordsWithoutPhotos() {
        let found = JournalCompleteness.thinEntries(
            local: [local("2026-08-14", words: true, media: false)], destination: nil
        )
        #expect(found.map(\.shortfall) == [.noMedia])
    }

    @Test("an entry opened and abandoned")
    func abandoned() {
        let found = JournalCompleteness.thinEntries(
            local: [local("2026-08-14", words: false, media: false)], destination: nil
        )
        #expect(found.map(\.shortfall) == [.empty])
    }

    // MARK: - Folding the two sides of one entry

    /// The failure that would make the feature untrustworthy: an entry that has synced exists
    /// on both sides, and listing it twice makes the worklist look twice as bad as it is.
    @Test("a synced entry is listed once, not once per side")
    func syncedEntryIsNotDoubled() {
        let row = local("2026-08-14", words: true, media: false, page: "page-1")
        let found = JournalCompleteness.thinEntries(
            local: [row],
            destination: [remote("2026-08-14", page: "page-1", words: true, media: false)]
        )
        #expect(found.map(\.source) == [.local(row.id)])
    }

    /// The one that would actively lie. Photos added in Notion never come back to the device,
    /// so the local half looks bare while the user is looking at a page full of pictures.
    @Test("photos added in Notion count, even though the device never saw them")
    func remoteMediaSatisfiesALocalEntry() {
        let found = JournalCompleteness.thinEntries(
            local: [local("2026-08-14", words: true, media: false, page: "page-1")],
            destination: [remote("2026-08-14", page: "page-1", words: true, media: true)]
        )
        #expect(found.isEmpty, "the entry has photos - they are just not on this phone")
    }

    @Test("words added in Notion count too")
    func remoteWordsSatisfyALocalEntry() {
        let found = JournalCompleteness.thinEntries(
            local: [local("2026-08-14", words: false, media: true, page: "page-1")],
            destination: [remote("2026-08-14", page: "page-1", words: true, media: true)]
        )
        #expect(found.isEmpty)
    }

    @Test("a folded entry keeps the local source, because that is the one you can edit")
    func foldedEntryStaysEditable() {
        let row = local("2026-08-14", words: false, media: false, page: "page-1")
        let found = JournalCompleteness.thinEntries(
            local: [row],
            destination: [remote("2026-08-14", page: "page-1", words: false, media: false)]
        )
        #expect(found.map(\.source) == [.local(row.id)])
    }

    /// Years of journal written before the app existed. These have no local half at all.
    @Test("an entry that only exists in Notion is still offered")
    func destinationOnlyEntry() {
        let found = JournalCompleteness.thinEntries(
            local: [], destination: [remote("2024-03-02", page: "old", words: true, media: false)]
        )
        #expect(found.map(\.source) == [.destination(pageId: "old")])
        #expect(found.map(\.shortfall) == [.noMedia])
    }

    @Test("a local entry pointing at a page outside the window is judged on its own")
    func unmatchedLinkIsNotFolded() {
        let found = JournalCompleteness.thinEntries(
            local: [local("2026-08-14", words: true, media: false, page: "elsewhere")],
            destination: [remote("2026-08-14", page: "different", words: false, media: true)]
        )
        #expect(found.count == 2, "two unrelated entries, each short of something")
        #expect(Set(found.map(\.shortfall)) == [.noMedia, .noText])
    }

    // MARK: - Filtering and order

    @Test("only the selected kinds come back")
    func filtering() {
        let rows = [
            local("2026-08-14", words: false, media: true),
            local("2026-08-13", words: true, media: false),
            local("2026-08-12", words: false, media: false),
        ]
        let onlyMissingPhotos = JournalCompleteness.thinEntries(
            local: rows, destination: nil, matching: [.noMedia]
        )
        #expect(onlyMissingPhotos.map(\.shortfall) == [.noMedia])

        #expect(JournalCompleteness.thinEntries(
            local: rows, destination: nil, matching: []
        ).isEmpty)
    }

    @Test("newest first, like the open-days list")
    func ordering() {
        let found = JournalCompleteness.thinEntries(
            local: [
                local("2026-08-12", words: false, media: false),
                local("2026-08-20", words: false, media: false),
                local("2026-08-16", words: false, media: false),
            ],
            destination: nil
        )
        #expect(found.map(\.day.rawValue) == ["2026-08-20", "2026-08-16", "2026-08-12"])
    }

    @Test("several entries on one day are judged one by one")
    func multipleEntriesPerDay() {
        let found = JournalCompleteness.thinEntries(
            local: [
                local("2026-08-14", words: true, media: true),
                local("2026-08-14", words: false, media: true),
            ],
            destination: nil
        )
        #expect(found.map(\.shortfall) == [.noText], "the finished one is left alone")
    }

    // MARK: - Tone

    /// The list is an offer, not an accusation. An entry with no title is usually exactly the
    /// abandoned one being surfaced, and calling it "Untitled" reads like a reprimand for a
    /// second thing.
    @Test("an untitled entry is named by its day, not called Untitled")
    func untitledEntriesAreNamedByDay() {
        let entry = ThinEntry(
            source: .destination(pageId: "p"), day: day("2026-08-14"),
            title: "  ", shortfall: .empty
        )
        #expect(!entry.displayTitle.isEmpty)
        #expect(!entry.displayTitle.localizedCaseInsensitiveContains("untitled"))
    }
}
