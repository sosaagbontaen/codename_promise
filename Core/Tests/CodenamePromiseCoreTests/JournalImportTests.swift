import Foundation
import Testing
@testable import CodenamePromiseCore

/// Getting a journal back in.
///
/// The export exists so a lost phone does not take six years with it, and until now it was
/// half of that promise: markdown you can read is not a journal you can restore. These tests
/// are mostly about the round trip, because being the exporter's exact inverse is the design.
@Suite("Journal import")
@MainActor
struct JournalImportTests {

    private func makeStore() throws -> DraftStore {
        DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Parsing

    @Test("front matter and body come back")
    func parsesAnEntry() throws {
        let id = UUID()
        let text = """
        ---
        id: \(id.uuidString)
        date: 2026-08-14
        title: The sea
        ---

        # The sea

        It was colder than it looked.
        """
        let parsed = try #require(JournalImporter.parse(text))
        #expect(parsed.id == id)
        #expect(parsed.entryDateKey == "2026-08-14")
        #expect(parsed.title == "The sea")
        #expect(parsed.rawText == "It was colder than it looked.")
    }

    /// The exporter opens the body with the title as an H1. Keeping it would add a line of
    /// markdown to the person's writing on every round trip.
    @Test("the repeated title heading is not treated as writing")
    func dropsTheTitleHeading() throws {
        let parsed = try #require(JournalImporter.parse("""
        ---
        date: 2026-08-14
        title: Day one
        ---

        # Day one

        Actual words.
        """))
        #expect(parsed.rawText == "Actual words.")
    }

    /// ...but only the first one. A heading further down is the person's own.
    @Test("a heading inside the entry is kept")
    func keepsLaterHeadings() throws {
        let parsed = try #require(JournalImporter.parse("""
        ---
        date: 2026-08-14
        ---

        # 2026-08-14

        Morning.

        # Evening

        Later.
        """))
        #expect(parsed.rawText.contains("# Evening"))
    }

    @Test("a file with no date is refused rather than guessed at")
    func refusesUndatedFiles() {
        #expect(JournalImporter.parse("---\ntitle: Nowhere\n---\n\nWords.") == nil)
        #expect(JournalImporter.parse("Just a note with no front matter.") == nil)
        #expect(JournalImporter.parse("---\ndate: not-a-date\n---\n") == nil)
    }

    @Test("attachment and recording links are read, and separately")
    func readsLinks() throws {
        let parsed = try #require(JournalImporter.parse("""
        ---
        date: 2026-08-14
        ---

        Words.

        ## Attachments

        ![one.jpg](media/2026-08-14/one.jpg)

        ## Recordings not yet transcribed

        - [take.m4a](media/2026-08-14/take.m4a)
        """))
        #expect(parsed.attachments == ["media/2026-08-14/one.jpg"])
        #expect(parsed.untranscribedAudio == ["media/2026-08-14/take.m4a"])
    }

    @Test("percent-encoded names come back as the filenames they are")
    func decodesLinkTargets() {
        #expect(
            JournalImporter.linkTarget(in: "![a](media/x/a%20photo.jpg)")
                == "media/x/a photo.jpg"
        )
    }

    // MARK: - The round trip

    @Test("an exported journal imports back with its words intact")
    func roundTrip() throws {
        let source = try makeStore()
        let draft = try source.createDraft(entryDate: CalendarDay(rawValue: "2026-08-14")!)
        try source.updateTitle("The sea", for: draft)
        try source.updateRawText("It was colder than it looked.\n\nWe stayed anyway.", for: draft)

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try MediaFileStore(root: tempDirectory())
        _ = try source.exportAll(to: folder, fileStore: files)

        // A different device: a new store that has never seen any of this.
        let destination = try makeStore()
        let report = try destination.importJournal(from: folder, fileStore: files)

        #expect(report.added == 1)
        let restored = try #require(try destination.allDrafts().first)
        #expect(restored.content.title == "The sea")
        #expect(restored.content.rawText == "It was colder than it looked.\n\nWe stayed anyway.")
        #expect(restored.entryDateKey == "2026-08-14")
    }

    /// The failure that would make import unusable: run it twice and get two journals.
    @Test("importing the same folder twice does not duplicate anything")
    func importIsIdempotent() throws {
        let source = try makeStore()
        for day in ["2026-08-12", "2026-08-13"] {
            let draft = try source.createDraft(entryDate: CalendarDay(rawValue: day)!)
            try source.updateRawText("Something on \(day).", for: draft)
        }

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try MediaFileStore(root: tempDirectory())
        _ = try source.exportAll(to: folder, fileStore: files)

        let destination = try makeStore()
        #expect(try destination.importJournal(from: folder, fileStore: files).added == 2)

        let second = try destination.importJournal(from: folder, fileStore: files)
        #expect(second.added == 0)
        #expect(second.alreadyPresent == 2)
        #expect(try destination.allDrafts().count == 2, "two runs must not make four entries")
    }

    /// Import must never be able to lose what is already here.
    @Test("import adds and never touches what is already on the device")
    func importIsAdditive() throws {
        let store = try makeStore()
        let mine = try store.createDraft(entryDate: CalendarDay(rawValue: "2026-01-01")!)
        try store.updateRawText("Written on this phone.", for: mine)

        let other = try makeStore()
        let theirs = try other.createDraft(entryDate: CalendarDay(rawValue: "2026-08-14")!)
        try other.updateRawText("Written somewhere else.", for: theirs)

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try MediaFileStore(root: tempDirectory())
        _ = try other.exportAll(to: folder, fileStore: files)

        _ = try store.importJournal(from: folder, fileStore: files)

        let texts = try store.allDrafts().map(\.content.rawText).sorted()
        #expect(texts == ["Written on this phone.", "Written somewhere else."])
    }

    /// Rule 3, and the one that matters most: a missing photo must not cost the writing.
    @Test("an entry whose attachment is gone still arrives with its text")
    func missingAttachmentDoesNotLoseWords() throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("""
        ---
        date: 2026-08-14
        title: Beach
        ---

        # Beach

        The words that must survive.

        ## Attachments

        ![gone.jpg](media/2026-08-14/gone.jpg)
        """.utf8).write(to: folder.appendingPathComponent("2026-08-14 Beach.md"))

        let store = try makeStore()
        let files = try MediaFileStore(root: tempDirectory())
        let report = try store.importJournal(from: folder, fileStore: files)

        #expect(report.added == 1)
        #expect(report.missingAttachments == ["media/2026-08-14/gone.jpg"])
        #expect(try store.allDrafts().first?.content.rawText == "The words that must survive.")
    }

    @Test("one unreadable file does not abandon the rest")
    func oneBadFileIsSurvivable() throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("this is not an entry".utf8)
            .write(to: folder.appendingPathComponent("broken.md"))
        try Data("---\ndate: 2026-08-14\n---\n\nFine.".utf8)
            .write(to: folder.appendingPathComponent("good.md"))

        let report = try makeStore().importJournal(
            from: folder, fileStore: MediaFileStore(root: tempDirectory())
        )
        #expect(report.added == 1)
        #expect(report.unreadable == ["broken.md"])
    }

    @Test("the exporter's own README is not mistaken for an entry")
    func readmeIsIgnored() throws {
        let store = try makeStore()
        let draft = try store.createDraft(entryDate: CalendarDay(rawValue: "2026-08-14")!)
        try store.updateRawText("Words.", for: draft)

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try MediaFileStore(root: tempDirectory())
        _ = try store.exportAll(to: folder, fileStore: files)

        let report = try makeStore().importJournal(from: folder, fileStore: files)
        #expect(report.unreadable.isEmpty, "README.md is a note to a human, not a failure")
        #expect(report.added == 1)
    }

    // MARK: - Exporting a subset

    @Test("only the chosen entries are written")
    func exportsASubset() throws {
        let store = try makeStore()
        var ids: [UUID] = []
        for day in ["2026-08-12", "2026-08-13", "2026-08-14"] {
            let draft = try store.createDraft(entryDate: CalendarDay(rawValue: day)!)
            try store.updateRawText("Something on \(day).", for: draft)
            ids.append(draft.id)
        }

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try MediaFileStore(root: tempDirectory())
        let summary = try store.export(
            ids: [ids[0], ids[2]], to: folder, fileStore: files
        )

        #expect(summary.entries == 2)
        let days = try makeStore()
            .importJournal(from: folder, fileStore: files)
        #expect(days.added == 2)
    }

    @Test("an id that no longer exists is skipped, not fatal")
    func missingIdIsSkipped() throws {
        let store = try makeStore()
        let draft = try store.createDraft(entryDate: CalendarDay(rawValue: "2026-08-14")!)
        try store.updateRawText("Here.", for: draft)

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let summary = try store.export(
            ids: [draft.id, UUID()], to: folder,
            fileStore: MediaFileStore(root: tempDirectory())
        )
        #expect(summary.entries == 1)
    }
}
