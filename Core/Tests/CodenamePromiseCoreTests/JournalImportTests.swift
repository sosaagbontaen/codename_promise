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
        let store = DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
        // Tests run in parallel; each import keeps its own note of unfinished entries.
        store.importBookkeeping = UserDefaults(suiteName: "import-tests-\(UUID().uuidString)")!
        return store
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
    func roundTrip() async throws {
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
        let report = try await destination.importJournal(from: folder, fileStore: files)

        #expect(report.added == 1)
        #expect(report.importedIds == [draft.id], "the screen lists what arrived")
        let restored = try #require(try destination.allDrafts().first)
        #expect(restored.content.title == "The sea")
        #expect(restored.content.rawText == "It was colder than it looked.\n\nWe stayed anyway.")
        #expect(restored.entryDateKey == "2026-08-14")
    }

    /// The failure that would make import unusable: run it twice and get two journals.
    @Test("importing the same folder twice does not duplicate anything")
    func importIsIdempotent() async throws {
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
        #expect(try await destination.importJournal(from: folder, fileStore: files).added == 2)

        let second = try await destination.importJournal(from: folder, fileStore: files)
        #expect(second.added == 0)
        #expect(second.alreadyPresent == 2)
        #expect(try destination.allDrafts().count == 2, "two runs must not make four entries")
    }

    /// An import cut off partway (the app closed, iOS ended it) has made an entry without all
    /// of its photos. Running it again must finish that entry, not skip it as already here.
    @Test("an interrupted import finishes the entry it was on")
    func interruptedImportResumes() async throws {
        let source = try makeStore()
        let files = try MediaFileStore(root: tempDirectory())
        let draft = try source.createDraft(entryDate: CalendarDay(rawValue: "2026-08-12")!)
        try source.updateRawText("Beach day.", for: draft)
        for name in ["a", "b"] {
            let photo = tempDirectory().appendingPathExtension("jpg")
            try Data("photo \(name)".utf8).write(to: photo)
            try source.attachMedia(from: photo, kind: .photo, to: draft, fileStore: files)
        }
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try source.exportAll(to: folder, fileStore: files)

        let destination = try makeStore()
        let destinationFiles = try MediaFileStore(root: tempDirectory())
        _ = try await destination.importJournal(from: folder, fileStore: destinationFiles)
        let imported = try #require(try destination.draft(id: draft.id))
        #expect(imported.media.count == 2)

        // As if the first run had stopped after one photo.
        let lost = try #require(imported.orderedMedia.last)
        try destination.removeMedia(id: lost.id, from: imported, fileStore: destinationFiles)
        destination.importBookkeeping.set([draft.id.uuidString], forKey: "journalImport.unfinishedEntries")

        let second = try await destination.importJournal(from: folder, fileStore: destinationFiles)
        #expect(second.alreadyPresent == 0)
        #expect(second.attachments == 1, "only the missing photo comes in")
        #expect(try destination.draft(id: draft.id)?.media.count == 2)

        // Finished now, so a third run leaves it alone.
        let third = try await destination.importJournal(from: folder, fileStore: destinationFiles)
        #expect(third.alreadyPresent == 1)
        #expect(third.attachments == 0)
    }

    /// Photos brought back after an entry was imported arrive in an "adds" file. They join
    /// the entry already here, change nothing else, and wait if the entry isn't here yet.
    @Test("an additions file adds photos to an entry that's here, and only then")
    func additionsJoinExistingEntries() async throws {
        let store = try makeStore()
        let files = try MediaFileStore(root: tempDirectory())
        let here = try store.createDraft(entryDate: CalendarDay(rawValue: "2021-10-01")!)
        try store.updateRawText("Photoshoot day.", for: here)
        let notHere = UUID()

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("media/x"), withIntermediateDirectories: true)
        try Data("raw photo".utf8).write(to: folder.appendingPathComponent("media/x/001 IMG_0515.jpg"))
        for (id, name) in [(here.id, "a"), (notHere, "b")] {
            let md = "---\nid: \(id.uuidString)\ndate: 2021-10-01\nadds: attachments\ntitle: Should not rename\n---\n\n# Title\n\n## Attachments\n\n![p](media/x/001%20IMG_0515.jpg)\n"
            try md.write(to: folder.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }

        let report = try await store.importJournal(from: folder, fileStore: files)
        #expect(report.added == 0)
        #expect(report.attachments == 1)
        #expect(report.additionsWaiting == 1)
        let updated = try #require(try store.draft(id: here.id))
        #expect(updated.media.count == 1)
        #expect(updated.content.rawText == "Photoshoot day.", "words untouched")
        #expect(updated.content.title == nil, "title untouched")
        #expect(try store.draft(id: notHere) == nil, "never creates an entry")

        // Running it again adds nothing more.
        let again = try await store.importJournal(from: folder, fileStore: files)
        #expect(again.attachments == 0)
        #expect(try store.draft(id: here.id)?.media.count == 1)
    }

    @Test("merging keeps every phone line the update doesn't contain")
    func mergingNeverDropsWords() {
        let incoming = "Went to **church** with mom.\n- Lunch at the buffet\n- Long nap"
        // Same words, different wrapping and markup: nothing to keep.
        #expect(JournalImporter.merging(phone: "Went to church with mom.\nLunch at the buffet", incoming: incoming) == incoming)
        // A line written on the phone after importing survives, once.
        let merged = JournalImporter.merging(phone: "Went to church with mom.\nCalled Aaron later.", incoming: incoming)
        #expect(merged == incoming + "\n\nCalled Aaron later.")
        #expect(JournalImporter.merging(phone: merged, incoming: incoming) == merged, "running it again changes nothing")
    }

    @Test("an update replaces an imported entry's words, keeps phone-only lines, and adds photos")
    func updatesMergeIntoExistingEntries() async throws {
        let store = try makeStore()
        let files = try MediaFileStore(root: tempDirectory())
        let entry = try store.createDraft(entryDate: CalendarDay(rawValue: "2025-03-23")!)
        try store.updateRawText("Church with mom.\nWrote this on the phone.", for: entry)
        let fresh = UUID()

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("media/n"), withIntermediateDirectories: true)
        try Data("notion photo".utf8).write(to: folder.appendingPathComponent("media/n/IMG_3714.jpg"))
        for (id, name) in [(entry.id, "a"), (fresh, "b")] {
            let md = "---\nid: \(id.uuidString)\ndate: 2025-03-23\nupdates: content\ntitle: WWWT 3/23/25\n---\n\n# WWWT 3/23/25\n\nChurch with mom. Healing conversation first.\n\n## Attachments\n\n![p](media/n/IMG_3714.jpg)\n"
            try md.write(to: folder.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }

        let report = try await store.importJournal(from: folder, fileStore: files)
        #expect(report.updated == 1)
        #expect(report.added == 1, "an update for an entry that isn't here comes in as new")
        let updated = try #require(try store.draft(id: entry.id))
        #expect(updated.content.rawText == "Church with mom. Healing conversation first.\n\nWrote this on the phone.")
        #expect(updated.content.title == "WWWT 3/23/25", "an untitled entry takes the title")
        #expect(updated.media.count == 1)

        let again = try await store.importJournal(from: folder, fileStore: files)
        #expect(again.updated == 0 && again.added == 0 && again.attachments == 0, "a second run changes nothing")
    }

    @Test("progress counts every entry and file")
    func reportsProgress() async throws {
        let source = try makeStore()
        let files = try MediaFileStore(root: tempDirectory())
        for day in ["2026-08-12", "2026-08-13"] {
            let draft = try source.createDraft(entryDate: CalendarDay(rawValue: day)!)
            let photo = tempDirectory().appendingPathExtension("jpg")
            try Data("photo \(day)".utf8).write(to: photo)
            try source.attachMedia(from: photo, kind: .photo, to: draft, fileStore: files)
        }
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try source.exportAll(to: folder, fileStore: files)

        var seen: [JournalImportProgress] = []
        _ = try await makeStore().importJournal(from: folder, fileStore: try MediaFileStore(root: tempDirectory())) {
            seen.append($0)
        }
        // Reading the folder shows before anything is added, so the bar moves from the start.
        #expect(seen.first == JournalImportProgress(readTotal: 2))
        #expect(seen.contains { $0.readDone == 2 && $0.entriesDone == 0 })
        #expect(seen.last == JournalImportProgress(
            readDone: 2, readTotal: 2, entriesDone: 2, entriesTotal: 2, filesDone: 2, filesTotal: 2))
        #expect(seen.last?.fraction == 1)
        // Never goes backwards.
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
    }

    /// Import must never be able to lose what is already here.
    @Test("import adds and never touches what is already on the device")
    func importIsAdditive() async throws {
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

        _ = try await store.importJournal(from: folder, fileStore: files)

        let texts = try store.allDrafts().map(\.content.rawText).sorted()
        #expect(texts == ["Written on this phone.", "Written somewhere else."])
    }

    /// Rule 3, and the one that matters most: a missing photo must not cost the writing.
    @Test("an entry whose attachment is gone still arrives with its text")
    func missingAttachmentDoesNotLoseWords() async throws {
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
        let report = try await store.importJournal(from: folder, fileStore: files)

        #expect(report.added == 1)
        #expect(report.missingAttachments == ["media/2026-08-14/gone.jpg"])
        #expect(try store.allDrafts().first?.content.rawText == "The words that must survive.")
    }

    @Test("one unreadable file does not abandon the rest")
    func oneBadFileIsSurvivable() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("this is not an entry".utf8)
            .write(to: folder.appendingPathComponent("broken.md"))
        try Data("---\ndate: 2026-08-14\n---\n\nFine.".utf8)
            .write(to: folder.appendingPathComponent("good.md"))

        let report = try await makeStore().importJournal(
            from: folder, fileStore: MediaFileStore(root: tempDirectory())
        )
        #expect(report.added == 1)
        #expect(report.unreadable == ["broken.md"])
    }

    @Test("the exporter's own README is not mistaken for an entry")
    func readmeIsIgnored() async throws {
        let store = try makeStore()
        let draft = try store.createDraft(entryDate: CalendarDay(rawValue: "2026-08-14")!)
        try store.updateRawText("Words.", for: draft)

        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try MediaFileStore(root: tempDirectory())
        _ = try store.exportAll(to: folder, fileStore: files)

        let report = try await makeStore().importJournal(from: folder, fileStore: files)
        #expect(report.unreadable.isEmpty, "README.md is a note to a human, not a failure")
        #expect(report.added == 1)
    }

    // MARK: - Exporting a subset

    @Test("only the chosen entries are written")
    func exportsASubset() async throws {
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
        let days = try await makeStore()
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
