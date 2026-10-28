import Foundation
import SQLite3

/// Search across the journal: the words written, the words in photos (read by OCR), and what
/// photos show (an object or scene).
///
/// A separate SQLite full-text index rather than part of the journal's store. It holds nothing
/// that can't be made again from the journal and its photos, so it can be deleted and rebuilt
/// at any time, never needs a schema migration, and can't put an entry at risk. Reading photos
/// is slow (seconds each, for tens of thousands), so what has been read is remembered here and
/// only new photos are read later.
public actor SearchIndex {
    /// Bumped when what's stored per photo changes, so photos read under an older version are
    /// read again.
    public static let mediaVersion = 1

    public struct EntryHit: Sendable, Equatable, Identifiable {
        public let draftId: UUID
        public let day: String
        public let title: String
        public let snippet: String
        public var id: UUID { draftId }
    }

    public struct MediaHit: Sendable, Equatable, Identifiable {
        public let mediaId: UUID
        public let draftId: UUID
        public let day: String
        /// The words matched in the photo, or the label it was recognised as.
        public let snippet: String
        public var id: UUID { mediaId }
    }

    public struct Results: Sendable, Equatable {
        public var entries: [EntryHit] = []
        public var photoText: [MediaHit] = []
        public var photoContents: [MediaHit] = []
        public var isEmpty: Bool { entries.isEmpty && photoText.isEmpty && photoContents.isEmpty }
        public init() {}
    }

    private nonisolated(unsafe) var db: OpaquePointer?

    public init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SearchIndexError.cannotOpen
        }
        db = handle
        for sql in [
            "PRAGMA journal_mode=WAL",
            // Words: `unicode61` with diacritics removed, so "cafe" finds "café".
            "CREATE VIRTUAL TABLE IF NOT EXISTS entries USING fts5(draft_id UNINDEXED, day UNINDEXED, title, body, tokenize='unicode61 remove_diacritics 2')",
            "CREATE VIRTUAL TABLE IF NOT EXISTS media USING fts5(media_id UNINDEXED, draft_id UNINDEXED, day UNINDEXED, words, labels, tokenize='unicode61 remove_diacritics 2')",
            "CREATE TABLE IF NOT EXISTS media_read (media_id TEXT PRIMARY KEY, version INTEGER NOT NULL)",
        ] {
            sqlite3_exec(handle, sql, nil, nil, nil)
        }
    }

    /// The app's index, in Application Support beside the journal.
    public static func makeDefault() throws -> SearchIndex {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try SearchIndex(url: folder.appendingPathComponent("SearchIndex.sqlite"))
    }

    deinit { sqlite3_close(db) }

    // MARK: - Writing

    /// Replaces what's indexed for these entries. Plain words, not Markdown.
    public func indexEntries(_ entries: [(id: UUID, day: String, title: String, body: String)]) {
        transaction {
            for entry in entries {
                run("DELETE FROM entries WHERE draft_id = ?", entry.id.uuidString)
                run("INSERT INTO entries (draft_id, day, title, body) VALUES (?, ?, ?, ?)",
                    entry.id.uuidString, entry.day, entry.title, entry.body)
            }
        }
    }

    /// Takes entries out of results. What was read from their photos stays, so restoring one
    /// from Recently Deleted brings its photos back into search without reading them again;
    /// photos only show for entries that are indexed.
    public func removeEntries(_ ids: [UUID]) {
        transaction {
            for id in ids {
                run("DELETE FROM entries WHERE draft_id = ?", id.uuidString)
            }
        }
    }

    /// Everything currently indexed as an entry, to work out what's gone.
    public func indexedEntryIds() -> Set<UUID> {
        Set(column("SELECT draft_id FROM entries").compactMap(UUID.init(uuidString:)))
    }

    /// What was read from a photo: the words in it, and what it was recognised as ("tree",
    /// "beach"), most confident first.
    public struct MediaReading: Sendable {
        public let id: UUID
        public let draftId: UUID
        public let day: String
        public let words: String
        public let labels: [String]
        /// False when part of the reading failed: what was found is searchable now, and the
        /// photo is read again on a later pass rather than counted as done.
        public let complete: Bool
        public init(id: UUID, draftId: UUID, day: String, words: String, labels: [String], complete: Bool = true) {
            self.id = id
            self.draftId = draftId
            self.day = day
            self.words = words
            self.labels = labels
            self.complete = complete
        }
    }

    public func indexMedia(_ readings: [MediaReading]) {
        transaction {
            for reading in readings {
                run("DELETE FROM media WHERE media_id = ?", reading.id.uuidString)
                run("INSERT INTO media (media_id, draft_id, day, words, labels) VALUES (?, ?, ?, ?, ?)",
                    reading.id.uuidString, reading.draftId.uuidString, reading.day, reading.words,
                    reading.labels.joined(separator: " "))
                if reading.complete {
                    run("INSERT OR REPLACE INTO media_read (media_id, version) VALUES (?, ?)",
                        reading.id.uuidString, String(Self.mediaVersion))
                }
            }
        }
    }

    public func indexMedia(id: UUID, draftId: UUID, day: String, words: String, labels: [String]) {
        indexMedia([MediaReading(id: id, draftId: draftId, day: day, words: words, labels: labels)])
    }

    /// Which entry and day each read photo is filed under.
    public func mediaPlacements() -> [UUID: (draftId: UUID, day: String)] {
        var out: [UUID: (draftId: UUID, day: String)] = [:]
        for row in rows("SELECT media_id, draft_id, day FROM media", []) {
            guard let media = UUID(uuidString: row[0]), let draft = UUID(uuidString: row[1]) else { continue }
            out[media] = (draft, row[2])
        }
        return out
    }

    /// Refiles photos that were moved to another entry or day since they were read.
    public func placeMedia(_ moves: [(id: UUID, draftId: UUID, day: String)]) {
        transaction {
            for move in moves {
                run("UPDATE media SET draft_id = ?, day = ? WHERE media_id = ?",
                    move.draftId.uuidString, move.day, move.id.uuidString)
            }
        }
    }

    /// Photos already read under the current version.
    public func readMediaIds() -> Set<UUID> {
        Set(column("SELECT media_id FROM media_read WHERE version >= \(Self.mediaVersion)").compactMap(UUID.init(uuidString:)))
    }

    public func removeMedia(_ ids: [UUID]) {
        transaction {
            for id in ids {
                run("DELETE FROM media WHERE media_id = ?", id.uuidString)
                run("DELETE FROM media_read WHERE media_id = ?", id.uuidString)
            }
        }
    }

    // MARK: - Searching

    /// Matches for `query`. Every word must appear (prefixes count: "run" finds
    /// "running"). `from` and `to`, as yyyy-MM-dd, keep results to those days, inclusive;
    /// either can be left open.
    public func search(_ query: String, from: String? = nil, to: String? = nil,
                       newestFirst: Bool = true, limit: Int = 200) -> Results {
        var results = Results()
        guard let match = Self.ftsQuery(query) else { return results }
        // yyyy-MM-dd compares as text in date order.
        var dayClause = ""
        var dayArgs: [String] = []
        if let from { dayClause += " AND day >= ?"; dayArgs.append(from) }
        if let to { dayClause += " AND day <= ?"; dayArgs.append(to) }
        let order = newestFirst ? "DESC" : "ASC"

        results.entries = rows(
            "SELECT draft_id, day, title, snippet(entries, 3, '', '', '…', 14) FROM entries WHERE entries MATCH ?\(dayClause) ORDER BY day \(order) LIMIT \(limit)",
            [match] + dayArgs
        ).compactMap { row in
            guard let id = UUID(uuidString: row[0]) else { return nil }
            return EntryHit(draftId: id, day: row[1], title: row[2], snippet: row[3])
        }
        results.photoText = mediaRows(column: "words", index: 3, match: match, dayClause: dayClause, dayArgs: dayArgs, order: order, limit: limit)
        results.photoContents = mediaRows(column: "labels", index: 4, match: match, dayClause: dayClause, dayArgs: dayArgs, order: order, limit: limit)
        return results
    }

    private func mediaRows(column: String, index: Int, match: String, dayClause: String, dayArgs: [String], order: String, limit: Int) -> [MediaHit] {
        rows(
            "SELECT media_id, draft_id, day, snippet(media, \(index), '', '', '…', 10) FROM media WHERE media MATCH ?\(dayClause) AND draft_id IN (SELECT draft_id FROM entries) ORDER BY day \(order) LIMIT \(limit)",
            ["{\(column)} : (\(match))"] + dayArgs
        ).compactMap { row in
            guard let media = UUID(uuidString: row[0]), let draft = UUID(uuidString: row[1]) else { return nil }
            return MediaHit(mediaId: media, draftId: draft, day: row[2], snippet: row[3])
        }
    }

    /// The user's words as an FTS query: each word quoted (so punctuation can't break the
    /// query) and matched as a prefix, all required.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    // MARK: - SQLite

    private func transaction(_ body: () -> Void) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        body()
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [String]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (index, arg) in args.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), arg, -1, Self.transient)
        }
        return statement
    }

    private func run(_ sql: String, _ args: String...) {
        guard let statement = prepare(sql, args) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func rows(_ sql: String, _ args: [String]) -> [[String]] {
        guard let statement = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [[String]] = []
        let count = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((0..<count).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }

    private func column(_ sql: String) -> [String] {
        rows(sql, []).compactMap(\.first)
    }
}

public enum SearchIndexError: Error {
    case cannotOpen
}
