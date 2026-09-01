import Foundation
import Testing
@testable import CodenamePromiseCore

/// Getting the journal out of the app.
///
/// This closes the one hole the product could not defend: everything lived on one device,
/// and a lost phone took all of it. The tests that matter here are not "does it write a
/// file" &mdash; they are the ones about what an export is allowed to leave behind.
@Suite("Exporting the journal")
@MainActor
struct ExportTests {

    private func makeStore() throws -> (DraftStore, MediaFileStore, URL) {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DraftStore(container: container), MediaFileStore(root: root), root)
    }

    private func outDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-out-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    private func source(_ marker: String, ext: String = "jpg") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("in-\(UUID().uuidString).\(ext)")
        try Data(marker.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - The words

    @Test("the user's own words are written out verbatim")
    func rawTextSurvives() throws {
        let (store, files, _) = try makeStore()
        let draft = try store.createDraft(entryDate: CalendarDay(rawValue: "2026-08-14")!)
        try store.updateTitle("What went well", for: draft)
        try store.updateRawText("Howdy\nwent to the airport", for: draft)

        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let summary = try store.exportAll(to: out, fileStore: files)

        #expect(summary.entries == 1)
        let text = try read(out.appendingPathComponent("2026-08-14 What went well.md"))
        #expect(text.contains("Howdy\nwent to the airport"))
        #expect(text.contains("date: 2026-08-14"))
        #expect(text.contains("title: What went well"))
    }

    /// The structured version is a derivative. The file must not let anyone mistake it for
    /// the record.
    @Test("structured text is included but labelled as secondary")
    func formattedIsLabelled() throws {
        let (store, files, _) = try makeStore()
        let draft = try store.createDraft()
        try store.updateRawText("i went to teh shops", for: draft)
        draft.applyFormatting("- I went to the shops", formatterVersion: "wwwt-1")
        try store.flush()

        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        try store.exportAll(to: out, fileStore: files)

        let file = try FileManager.default
            .contentsOfDirectory(atPath: out.path)
            .first { $0.hasSuffix(".md") && $0 != "README.md" }
        let text = try read(out.appendingPathComponent(try #require(file)))

        #expect(text.contains("i went to teh shops"), "the original must be there")
        #expect(text.contains("## Structured"))
        #expect(text.range(of: "i went to teh shops")!.lowerBound
                < text.range(of: "## Structured")!.lowerBound,
                "the user's words come first")
    }

    // MARK: - The rule that matters most

    /// A recording waiting in the queue holds words that exist nowhere else. An export that
    /// skipped it would lose exactly what this app promises to protect.
    @Test("a recording that was never transcribed is carried out with the entry")
    func untranscribedAudioIsExported() throws {
        let (store, files, _) = try makeStore()
        let draft = try store.createDraft()
        try store.attachAudioCapture(
            data: Data("spoken words nobody has read".utf8),
            fileExtension: "m4a", durationSeconds: 12, to: draft, fileStore: files
        )

        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let summary = try store.exportAll(to: out, fileStore: files)

        #expect(summary.audioFiles == 1, "un-merged audio must leave with the export")

        let folder = try FileManager.default.contentsOfDirectory(
            atPath: out.appendingPathComponent("media").path
        ).first
        let audio = out.appendingPathComponent("media")
            .appendingPathComponent(try #require(folder))
            .appendingPathComponent("recording-1.m4a")
        #expect(try read(audio) == "spoken words nobody has read")

        let file = try FileManager.default.contentsOfDirectory(atPath: out.path)
            .first { $0.hasSuffix(".md") && $0 != "README.md" }
        let text = try read(out.appendingPathComponent(try #require(file)))
        #expect(text.contains("Recordings not yet transcribed"),
                "and the entry has to say the words are in there")
    }

    @Test("audio already merged into the entry is not carried out again")
    func mergedAudioIsNotDuplicated() throws {
        let (store, files, _) = try makeStore()
        let draft = try store.createDraft()
        let capture = try store.attachAudioCapture(
            data: Data("hello".utf8), fileExtension: "m4a",
            durationSeconds: 3, to: draft, fileStore: files
        )
        capture.markTranscribed("hello")
        _ = try store.mergeTranscript("hello", from: capture, into: draft)

        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let summary = try store.exportAll(to: out, fileStore: files)

        #expect(summary.audioFiles == 0, "its words are already in the text")
    }

    // MARK: - Media

    @Test("photos are copied out and linked relatively")
    func mediaIsCopiedAndLinked() throws {
        let (store, files, _) = try makeStore()
        let draft = try store.createDraft(entryDate: CalendarDay(rawValue: "2026-08-14")!)
        try store.updateTitle("Beach", for: draft)
        try store.attachMedia(from: try source("photo bytes"), kind: .photo, to: draft, fileStore: files)

        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let summary = try store.exportAll(to: out, fileStore: files)

        #expect(summary.mediaFiles == 1)
        let copied = out.appendingPathComponent("media/2026-08-14 Beach/photo-1.jpg")
        #expect(try read(copied) == "photo bytes")

        let text = try read(out.appendingPathComponent("2026-08-14 Beach.md"))
        #expect(text.contains("media/2026-08-14%20Beach/photo-1.jpg"),
                "links are relative and percent-encoded so they resolve in a viewer")
    }

    /// Rule 2: one missing file must not cost you the other two thousand entries.
    @Test("a missing file is reported, not fatal")
    func missingBytesAreSurvivable() throws {
        let (store, files, root) = try makeStore()
        let draft = try store.createDraft()
        try store.updateRawText("still here", for: draft)
        let item = try store.attachMedia(from: try source("x"), kind: .photo, to: draft, fileStore: files)

        // The bytes vanish from under the row.
        try FileManager.default.removeItem(at: root.appendingPathComponent(item.relativePath))

        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let summary = try store.exportAll(to: out, fileStore: files)

        #expect(summary.entries == 1, "the entry still exports")
        #expect(summary.missingFiles.count == 1)
        #expect(summary.isCompleteRecord == false)
        #expect(try read(out.appendingPathComponent("README.md"))
            .contains("could not be found"), "and the export says so in writing")
    }

    // MARK: - Naming

    @Test("two entries on the same day get distinct files")
    func sameDayEntriesDoNotCollide() throws {
        let (store, files, _) = try makeStore()
        let day = CalendarDay(rawValue: "2026-08-14")!
        for _ in 0..<3 {
            let d = try store.createDraft(entryDate: day)
            try store.updateTitle("Morning", for: d)
        }

        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        try store.exportAll(to: out, fileStore: files)

        let files_ = try FileManager.default.contentsOfDirectory(atPath: out.path)
            .filter { $0.hasSuffix(".md") && $0 != "README.md" }
        #expect(files_.count == 3, "three entries, three files, none overwritten")
        #expect(Set(files_).count == 3)
    }

    @Test("a title full of punctuation still produces an openable filename")
    func awkwardTitles() {
        var used: Set<String> = []
        let entry = JournalExporter.Entry(
            id: UUID(), entryDateKey: "2026-08-14",
            title: "What / went \\ well: today?! *****",
            rawText: "", formattedText: nil,
            createdAt: Date(), updatedAt: Date(), destinationURL: nil,
            media: [], pendingAudio: []
        )
        let name = JournalExporter.fileBaseName(for: entry, avoiding: &used)
        #expect(!name.contains("/"))
        #expect(!name.contains("\\"))
        #expect(!name.contains(":"))
        #expect(name.hasPrefix("2026-08-14"))
    }

    @Test("an untitled entry falls back to its first line, then to the date")
    func untitledFallback() {
        var used: Set<String> = []
        let withText = JournalExporter.Entry(
            id: UUID(), entryDateKey: "2026-08-14", title: nil,
            rawText: "airport run\nthen groceries", formattedText: nil,
            createdAt: Date(), updatedAt: Date(), destinationURL: nil,
            media: [], pendingAudio: []
        )
        #expect(JournalExporter.fileBaseName(for: withText, avoiding: &used) == "2026-08-14 airport run")

        var used2: Set<String> = []
        let empty = JournalExporter.Entry(
            id: UUID(), entryDateKey: "2026-08-14", title: nil,
            rawText: "", formattedText: nil,
            createdAt: Date(), updatedAt: Date(), destinationURL: nil,
            media: [], pendingAudio: []
        )
        #expect(JournalExporter.fileBaseName(for: empty, avoiding: &used2) == "2026-08-14")
    }

    // MARK: - The whole thing

    @Test("an export of the whole journal needs nothing but a file browser")
    func selfContained() throws {
        let (store, files, _) = try makeStore()
        for i in 0..<5 {
            let d = try store.createDraft(entryDate: CalendarDay(rawValue: "2026-08-0\(i + 1)")!)
            try store.updateRawText("day \(i)", for: d)
            try store.attachMedia(from: try source("p\(i)"), kind: .photo, to: d, fileStore: files)
        }

        let out = try outDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let summary = try store.exportAll(to: out, fileStore: files)

        #expect(summary.entries == 5)
        #expect(summary.mediaFiles == 5)
        #expect(summary.isCompleteRecord)

        let readme = try read(out.appendingPathComponent("README.md"))
        #expect(readme.contains("5 entries"))
        #expect(readme.contains("Nothing here needs the app that wrote it"))
    }
}
