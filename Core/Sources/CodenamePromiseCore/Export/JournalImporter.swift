import Foundation

/// Reads a journal back in from the files `JournalExporter` wrote.
///
/// The export existed so a lost phone would not take six years with it, and it was only half
/// of that: markdown you can read is not the same as a journal you can get back. A backup you
/// cannot restore is a keepsake. This is the other half, and it is also the answer to moving
/// between phones without relying on Apple's backup, and to arriving from another app whose
/// output can be reshaped into this folder layout.
///
/// It mirrors the exporter's rules, because being its inverse is the whole design:
///
/// 1. **Never fail everything for one bad file.** A markdown file that will not parse is
///    reported and skipped, exactly as a missing attachment is on the way out.
/// 2. **Import is additive and never destructive.** Nothing already on the device is
///    modified or deleted. An entry whose `id` is already present is skipped, so running the
///    same import twice leaves you with one copy rather than two.
/// 3. **Take the words even when the rest is broken.** An entry whose attachments have gone
///    missing still comes in with its text. Losing a photo is a shame; losing the writing
///    because of a photo is the thing this product exists to prevent.
///
/// Pure parsing, no store and no file adoption, so the format can be tested from a string.
public struct JournalImporter: Sendable {

    /// One entry recovered from a file, still as values.
    public struct ParsedEntry: Sendable, Equatable {
        /// From the front matter. Nil for exports written before ids were recorded, in which
        /// case the caller cannot dedupe and has to treat it as new.
        public let id: UUID?
        public let entryDateKey: String
        public let title: String?
        public let rawText: String
        public let formattedText: String?
        public let createdAt: Date?
        /// Paths relative to the folder being imported, in the order the entry listed them.
        public let attachments: [String]
        /// Recordings the export marked as never transcribed. Kept apart because they are
        /// the one thing whose words exist nowhere else (ADR-002).
        public let untranscribedAudio: [String]

        public init(
            id: UUID?, entryDateKey: String, title: String?, rawText: String,
            formattedText: String?, createdAt: Date?,
            attachments: [String], untranscribedAudio: [String]
        ) {
            self.id = id
            self.entryDateKey = entryDateKey
            self.title = title
            self.rawText = rawText
            self.formattedText = formattedText
            self.createdAt = createdAt
            self.attachments = attachments
            self.untranscribedAudio = untranscribedAudio
        }
    }

    /// What a read of the folder found, including what it could not read.
    public struct Reading: Sendable {
        public var entries: [ParsedEntry] = []
        /// File names that could not be parsed. Reported, never fatal.
        public var unreadable: [String] = []
    }

    public init() {}

    /// Every entry file in a folder, newest-first by day.
    ///
    /// `README.md` is skipped by name: the exporter writes it as a note to a human, and it
    /// has no front matter, so it would only ever land in `unreadable` and worry somebody.
    public func read(directory: URL) throws -> Reading {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.lowercased().hasSuffix(".md") && $0.lowercased() != "readme.md" }
            .sorted()

        var reading = Reading()
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let entry = Self.parse(text) else {
                reading.unreadable.append(name)
                continue
            }
            reading.entries.append(entry)
        }
        reading.entries.sort { $0.entryDateKey > $1.entryDateKey }
        return reading
    }

    // MARK: - Parsing

    /// One markdown file back into values. Nil when it has no usable front matter.
    ///
    /// Deliberately tolerant about the body and strict about the date. Somebody may well have
    /// opened these files and edited them - that is the point of exporting plain text - so
    /// headings can move and prose can change. What cannot be guessed is which day an entry
    /// belongs to, and an entry filed under the wrong day is worse than one not imported.
    public static func parse(_ text: String) -> ParsedEntry? {
        var lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        var front: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { front[key] = value }
        }

        guard let date = front["date"], CalendarDay(rawValue: date) != nil else { return nil }

        let body = Array(lines[index...])
        let sections = Self.split(body)

        return ParsedEntry(
            id: front["id"].flatMap(UUID.init(uuidString:)),
            entryDateKey: date,
            title: front["title"].flatMap { $0.isEmpty ? nil : $0 },
            rawText: sections.raw,
            formattedText: sections.formatted,
            createdAt: front["created"].flatMap { ISO8601DateFormatter().date(from: $0) },
            attachments: sections.attachments,
            untranscribedAudio: sections.audio
        )
    }

    private struct Sections {
        var raw = ""
        var formatted: String?
        var attachments: [String] = []
        var audio: [String] = []
    }

    /// Walks the body once, switching on the headings the exporter writes.
    private static func split(_ lines: [String]) -> Sections {
        enum Where { case body, formatted, attachments, audio }

        var section = Where.body
        var sections = Sections()
        var raw: [String] = []
        var formatted: [String] = []
        var sawTitleHeading = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "## Structured" { section = .formatted; continue }
            if trimmed == "## Attachments" { section = .attachments; continue }
            if trimmed == "## Recordings not yet transcribed" { section = .audio; continue }

            switch section {
            case .body:
                // The exporter opens with "# <title or date>", which is the title repeated
                // rather than part of what was written. Only the first one is dropped: a
                // heading further down belongs to the person's own text.
                if !sawTitleHeading, trimmed.hasPrefix("# ") {
                    sawTitleHeading = true
                    continue
                }
                raw.append(line)
            case .formatted:
                formatted.append(line)
            case .attachments:
                if let path = Self.linkTarget(in: trimmed) { sections.attachments.append(path) }
            case .audio:
                if let path = Self.linkTarget(in: trimmed) { sections.audio.append(path) }
            }
        }

        sections.raw = raw.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let joinedFormatted = formatted.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sections.formatted = joinedFormatted.isEmpty ? nil : joinedFormatted
        return sections
    }

    /// The path out of `![name](media/x/y.jpg)` or `- [name](media/x/y.m4a)`.
    ///
    /// Percent-decoded, because the exporter encodes names that contain spaces and the
    /// filesystem wants them back the way they were.
    static func linkTarget(in line: String) -> String? {
        guard let open = line.lastIndex(of: "("),
              let close = line.lastIndex(of: ")"),
              open < close else { return nil }
        let target = String(line[line.index(after: open)..<close])
        guard !target.isEmpty, !target.hasPrefix("http") else { return nil }
        return target.removingPercentEncoding ?? target
    }
}
