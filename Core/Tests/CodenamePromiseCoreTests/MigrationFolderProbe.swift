import Foundation
import Testing
@testable import CodenamePromiseCore

/// Reads a folder produced by the Notes migration exporter. Off unless DUMPNOTES_IMPORT_DIR is set.
@Suite("Migration folder probe", .enabled(if: ProcessInfo.processInfo.environment["DUMPNOTES_IMPORT_DIR"] != nil))
struct MigrationFolderProbe {
    @Test func everyFileParses() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DUMPNOTES_IMPORT_DIR"]!)
        for year in try FileManager.default.contentsOfDirectory(atPath: root.path) where !year.hasPrefix(".") {
            let reading = try JournalImporter().read(directory: root.appendingPathComponent(year))
            print("PROBE \(year): \(reading.entries.count) entries, \(reading.unreadable.count) unreadable, \(reading.entries.reduce(0) { $0 + $1.attachments.count }) attachments")
            #expect(reading.unreadable.isEmpty)
            for entry in reading.entries {
                for path in entry.attachments {
                    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(year).appendingPathComponent(path).path), "\(path)")
                }
            }
        }
    }
}
