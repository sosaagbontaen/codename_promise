import Foundation
import Testing

@testable import CodenamePromiseCore

@Suite("Search")
struct SearchIndexTests {
    private func makeIndex() throws -> SearchIndex {
        try SearchIndex(url: FileManager.default.temporaryDirectory.appending(path: "search-\(UUID()).sqlite"))
    }

    @Test func findsWordsWrittenWithPrefixesAndNoAccents() async throws {
        let index = try makeIndex()
        let a = UUID(), b = UUID()
        await index.indexEntries([
            (a, "2020-07-14", "WWWT 7/14/20", "Had a driving lesson at the café. Running later."),
            (b, "2021-01-02", "New year", "Went running by the lake"),
        ])
        let running = await index.search("run")
        #expect(running.entries.map(\.draftId) == [b, a], "newest first, prefix match")
        #expect(await index.search("cafe").entries.map(\.draftId) == [a])
        #expect(await index.search("driving lake").entries.isEmpty, "every word must match")
        #expect(await index.search("run", day: "2020-07-14").entries.map(\.draftId) == [a])
    }

    @Test func photoWordsAndContentsAreSeparate() async throws {
        let index = try makeIndex()
        let draft = UUID(), sign = UUID(), park = UUID()
        await index.indexEntries([(draft, "2022-05-01", "Walk", "")])
        await index.indexMedia(id: sign, draftId: draft, day: "2022-05-01", words: "TREE NURSERY open daily", labels: ["sign", "text"])
        await index.indexMedia(id: park, draftId: draft, day: "2022-05-02", words: "", labels: ["tree", "grass", "sky"])
        let tree = await index.search("tree")
        #expect(tree.photoText.map(\.mediaId) == [sign], "the word on the sign")
        #expect(tree.photoContents.map(\.mediaId) == [park], "the picture of a tree")
        #expect(tree.entries.isEmpty)
    }

    @Test func aDeletedEntrysPhotosComeBackWithItWithoutBeingReadAgain() async throws {
        let index = try makeIndex()
        let draft = UUID(), photo = UUID()
        await index.indexEntries([(draft, "2022-05-01", "Day", "words")])
        await index.indexMedia(id: photo, draftId: draft, day: "2022-05-01", words: "hello", labels: [])
        #expect(await index.readMediaIds() == [photo])
        await index.removeEntries([draft])
        #expect(await index.search("hello").photoText.isEmpty, "hidden while its entry is deleted")
        #expect(await index.indexedEntryIds().isEmpty)
        await index.indexEntries([(draft, "2022-05-01", "Day", "words")])
        #expect(await index.search("hello").photoText.map(\.mediaId) == [photo])
        #expect(await index.readMediaIds() == [photo], "not read again")
    }

    @Test func aPartReadingIsSearchableButReadAgain() async throws {
        let index = try makeIndex()
        let draft = UUID(), photo = UUID()
        await index.indexEntries([(draft, "2022-05-01", "Day", "")])
        await index.indexMedia([.init(id: photo, draftId: draft, day: "2022-05-01", words: "open daily", labels: [], complete: false)])
        #expect(await index.search("daily").photoText.map(\.mediaId) == [photo])
        #expect(await index.readMediaIds().isEmpty, "the failed part is tried again")
        await index.indexMedia([.init(id: photo, draftId: draft, day: "2022-05-01", words: "open daily", labels: ["sign"])])
        #expect(await index.search("daily").photoText.count == 1, "replaced, not doubled")
        #expect(await index.readMediaIds() == [photo])
    }

    @Test func aMovedPhotoIsFoundUnderItsNewDay() async throws {
        let index = try makeIndex()
        let first = UUID(), second = UUID(), photo = UUID()
        await index.indexEntries([(first, "2022-05-01", "A", ""), (second, "2023-06-02", "B", "")])
        await index.indexMedia(id: photo, draftId: first, day: "2022-05-01", words: "", labels: ["dog"])
        await index.placeMedia([(photo, second, "2023-06-02")])
        #expect(await index.search("dog", day: "2023-06-02").photoContents.map(\.draftId) == [second])
        #expect(await index.mediaPlacements()[photo]?.day == "2023-06-02")
    }

    @Test func punctuationCantBreakAQuery() async throws {
        let index = try makeIndex()
        await index.indexEntries([(UUID(), "2022-05-01", "Day", "It's done")])
        #expect(await index.search("it's \"done").entries.count == 1)
        #expect(await index.search("   ").isEmpty)
    }
}
