import Foundation

/// A short list of recent entries, written by the phone for the places that capture without
/// access to the journal: the share sheet and the Mac panel. It is what lets them offer "add
/// to this entry" rather than only "add to this day".
///
/// A convenience, not a source of truth. If it is stale or missing, they offer days only, and
/// a capture aimed at an entry that has since been deleted falls back to its day.
public struct EntryIndex: Codable, Sendable, Equatable {
    public static let fileName = "_entries.dumpnotes.json"

    public struct Entry: Codable, Sendable, Equatable, Identifiable, Hashable {
        public let id: UUID
        public let day: CalendarDay
        public let title: String
        public let updatedAt: Date

        public init(id: UUID, day: CalendarDay, title: String, updatedAt: Date) {
            self.id = id
            self.day = day
            self.title = title
            self.updatedAt = updatedAt
        }
    }

    public var generatedAt: Date
    public var entries: [Entry]

    public init(generatedAt: Date = Date(), entries: [Entry]) {
        self.generatedAt = generatedAt
        self.entries = entries
    }

    /// Entries on one day, most recently edited first.
    public func entries(on day: CalendarDay) -> [Entry] {
        entries.filter { $0.day == day }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @MainActor
    public static func make(from store: DraftStore, days: Int = 60, now: Date = Date()) throws -> EntryIndex {
        let cutoff = CalendarDay(date: now.addingTimeInterval(-Double(days) * 86_400), timeZone: .current)
        let entries = try store.drafts(from: cutoff, through: CalendarDay(date: now, timeZone: .current))
            .map { draft in
                Entry(
                    id: draft.id,
                    day: draft.entryDate,
                    title: Self.title(for: draft),
                    updatedAt: draft.updatedAt
                )
            }
        return EntryIndex(generatedAt: now, entries: entries)
    }

    /// The entry's title, or the start of what it says.
    @MainActor
    static func title(for draft: EntryDraft) -> String {
        if let title = draft.content.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let firstLine = RichDocument.words(ofMarkdown: draft.content.rawText)
            .split(whereSeparator: \.isNewline)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.isEmpty {
            let count = draft.media.count
            return count == 0 ? "Untitled entry" : "\(count) attachment\(count == 1 ? "" : "s")"
        }
        return firstLine.count > 60 ? String(firstLine.prefix(57)) + "..." : firstLine
    }

    public func write(to url: URL) throws {
        try JSONEncoder.capture.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> EntryIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.capture.decode(EntryIndex.self, from: data)
    }
}
