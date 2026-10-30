import Foundation
import Testing

@testable import CodenamePromiseCore

@Suite("Inbox history")
struct InboxHistoryTests {
    private func makeHistory(limit: Int = 100) -> InboxHistory {
        InboxHistory(defaults: UserDefaults(suiteName: "inbox-history-\(UUID())")!, limit: limit)
    }

    private func filed(_ entry: UUID, notes: [String] = [], media: Int = 0) -> CaptureIngestor.Outcome {
        var outcome = CaptureIngestor.Outcome()
        var added = CaptureIngestor.Outcome.Added()
        added.notes = notes
        added.mediaIds = (0..<media).map { _ in UUID() }
        outcome.added[entry] = added
        return outcome
    }

    @Test func remembersWhatCameFromWhereNewestFirst() {
        let history = makeHistory()
        let monday = UUID(), tuesday = UUID()
        history.record(filed(monday, notes: ["bought stamps"]), from: .mac, at: Date(timeIntervalSince1970: 100))
        history.record(filed(tuesday, media: 2), from: .shareSheet, at: Date(timeIntervalSince1970: 200))
        history.record(filed(tuesday, media: 1), from: .mac, at: Date(timeIntervalSince1970: 300))

        let fromMac = history.arrivals(from: .mac)
        #expect(fromMac.map(\.entryId) == [tuesday, monday])
        #expect(fromMac.first?.media == 1)
        #expect(fromMac.first?.mediaIds.count == 1)
        #expect(fromMac.last?.notes == 1)
        #expect(history.arrivals().count == 3)
    }

    @Test func aDrainThatFiledNothingLeavesNoTrace() {
        let history = makeHistory()
        history.record(CaptureIngestor.Outcome(), from: .mac)
        history.record(filed(UUID()), from: .mac)
        #expect(history.arrivals().isEmpty)
    }

    @Test func keepsOnlyTheMostRecent() {
        let history = makeHistory(limit: 2)
        let entries = (0..<3).map { _ in UUID() }
        for (i, entry) in entries.enumerated() {
            history.record(filed(entry, notes: ["n"]), from: .mac, at: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(history.arrivals().map(\.entryId) == [entries[2], entries[1]])
    }
}
