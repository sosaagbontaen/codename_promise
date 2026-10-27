import Foundation
import SwiftData
import Testing

@testable import CodenamePromiseCore

/// Timing for the journal's hot path. Off by default; run with DUMPNOTES_PERF=1.
@Suite("Performance probe", .enabled(if: ProcessInfo.processInfo.environment["DUMPNOTES_PERF"] == "1"))
@MainActor
struct PerformanceProbe {
    private func time(_ label: String, _ body: () throws -> Void) rethrows {
        let start = ContinuousClock.now
        try body()
        print("PERF \(label): \(ContinuousClock.now - start)")
    }

    @Test func journalReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID()).store")
        let store = DraftStore(container: try ModelContainerFactory.makeAppContainer(url: url))
        let text = String(repeating: "Today was a good day with friends and a long walk. ", count: 40)
        for i in 0..<1000 {
            let draft = try store.createDraft(entryDate: CalendarDay(date: Date().addingTimeInterval(Double(-i) * 86_400)))
            draft.content.rawText = text
            for j in 0..<3 {
                let item = MediaItem(id: UUID(), kind: .photo, relativePath: "media/\(i)-\(j).jpg", originalSizeBytes: 1, createdAt: Date())
                item.sortIndex = j
                draft.media.append(item)
            }
        }
        try store.flush()

        // A fresh store, as on launch, so nothing is already faulted in.
        let cold = DraftStore(container: try ModelContainerFactory.makeAppContainer(url: url))
        var drafts: [EntryDraft] = []
        try time("allDrafts (cold)") { drafts = try cold.allDrafts() }
        time("media relationship read") { for d in drafts { _ = d.media.count } }
        time("media relationship read again") { for d in drafts { _ = d.media.count } }
        time("media ids") { for d in drafts { for m in d.media { _ = m.id } } }
        time("media sortIndex") { for d in drafts { for m in d.media { _ = m.sortIndex } } }
        time("orderedMedia") { for d in drafts { _ = d.orderedMedia } }
        time("orderedMedia again") { for d in drafts { _ = d.orderedMedia } }
        time("covers") { for d in drafts { _ = d.covers } }
        time("coverMediaIds read") { for d in drafts { _ = d.coverMediaIds } }
        time("sortIndex reads") { for d in drafts { for m in d.media { _ = m.sortIndex } } }
        time("needsSync (content hash)") { for d in drafts { _ = d.needsSync(to: .notion) } }
        time("rawText read") { for d in drafts { _ = d.content.rawText.count } }
        try time("allDrafts (warm)") { drafts = try cold.allDrafts() }
    }
}
