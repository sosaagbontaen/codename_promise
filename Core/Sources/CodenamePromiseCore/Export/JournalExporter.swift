import Foundation

/// Writes the whole journal out as plain files.
///
/// This is the answer to the one thing the app promises and could not deliver: everything
/// lives on one device, and a lost phone took six years with it. It is also, incidentally,
/// the answer to "I don't use Notion" &mdash; markdown and a folder of media open anywhere.
///
/// Three rules, and the first is the reason the other two exist.
///
/// 1. **Export everything, including what isn't finished.** A recording that has not been
///    transcribed yet is the single most valuable thing in the store, because its words exist
///    nowhere else. An export that skipped it would lose exactly what the product exists to
///    protect. Un-merged audio is copied out and named in the entry that owns it.
/// 2. **Never fail the whole export for one missing file.** A media row whose bytes have
///    gone is a problem worth reporting, not a reason to abandon the other 2,000 entries.
///    Failures are collected and returned.
/// 3. **Plain text, relative links.** No archive format, no database, nothing that needs this
///    app to read it. The test of a backup is whether it survives the thing that made it.
public struct JournalExporter: Sendable {

    /// What an export produced, including what it could not.
    public struct Summary: Sendable, Equatable {
        public var entries: Int = 0
        public var mediaFiles: Int = 0
        public var audioFiles: Int = 0
        /// Relative paths whose bytes were missing. Reported, never fatal.
        public var missingFiles: [String] = []

        public var isCompleteRecord: Bool { missingFiles.isEmpty }
    }

    /// One entry, flattened to values so the writer never touches a `@Model`.
    ///
    /// Keeps the file-writing half testable without a store, and honours the rule that
    /// models do not cross into code that might outlive them (ADR-009a).
    public struct Entry: Sendable {
        public let id: UUID
        public let entryDateKey: String
        public let title: String?
        public let rawText: String
        public let formattedText: String?
        public let createdAt: Date
        public let updatedAt: Date
        public let destinationURL: URL?
        public let media: [Attachment]
        /// Recordings whose transcript has not been merged. See rule 1.
        public let pendingAudio: [Attachment]

        public struct Attachment: Sendable {
            public let relativePath: String
            public let suggestedName: String

            public init(relativePath: String, suggestedName: String) {
                self.relativePath = relativePath
                self.suggestedName = suggestedName
            }
        }

        public init(
            id: UUID,
            entryDateKey: String,
            title: String?,
            rawText: String,
            formattedText: String?,
            createdAt: Date,
            updatedAt: Date,
            destinationURL: URL?,
            media: [Attachment],
            pendingAudio: [Attachment]
        ) {
            self.id = id
            self.entryDateKey = entryDateKey
            self.title = title
            self.rawText = rawText
            self.formattedText = formattedText
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.destinationURL = destinationURL
            self.media = media
            self.pendingAudio = pendingAudio
        }
    }

    private let fileStore: MediaFileStore

    public init(fileStore: MediaFileStore) {
        self.fileStore = fileStore
    }

    /// Writes `entries` into `directory`, which is created if needed.
    ///
    /// Layout, chosen so a person can find one day without tooling:
    /// ```
    /// <directory>/
    ///   README.md
    ///   2026-08-14 What went well.md
    ///   media/2026-08-14 What went well/photo-1.jpg
    /// ```
    @discardableResult
    public func write(_ entries: [Entry], to directory: URL) throws -> Summary {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var summary = Summary()
        var usedNames: Set<String> = []

        for entry in entries {
            let base = Self.fileBaseName(for: entry, avoiding: &usedNames)
            let assetFolder = directory
                .appendingPathComponent("media", isDirectory: true)
                .appendingPathComponent(base, isDirectory: true)

            var copiedMedia: [(name: String, isAudio: Bool)] = []
            let attachments = entry.media.map { ($0, false) } + entry.pendingAudio.map { ($0, true) }

            if !attachments.isEmpty {
                try fm.createDirectory(at: assetFolder, withIntermediateDirectories: true)
            }

            for (attachment, isAudio) in attachments {
                let source = fileStore.url(for: attachment.relativePath)
                guard fm.fileExists(atPath: source.path) else {
                    // Rule 2: note it and keep going.
                    summary.missingFiles.append(attachment.relativePath)
                    continue
                }
                let destination = assetFolder.appendingPathComponent(attachment.suggestedName)
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)
                copiedMedia.append((attachment.suggestedName, isAudio))
                if isAudio { summary.audioFiles += 1 } else { summary.mediaFiles += 1 }
            }

            let markdown = Self.markdown(for: entry, base: base, attachments: copiedMedia)
            try Data(markdown.utf8).write(
                to: directory.appendingPathComponent("\(base).md"), options: .atomic
            )
            summary.entries += 1
        }

        try Data(Self.readme(summary).utf8).write(
            to: directory.appendingPathComponent("README.md"), options: .atomic
        )
        return summary
    }

    // MARK: - Naming

    /// `2026-08-14 What went well` &mdash; sorts chronologically in any file browser, and is
    /// still recognisable when the folder is opened by a person years later.
    static func fileBaseName(for entry: Entry, avoiding used: inout Set<String>) -> String {
        let cleanedTitle = (entry.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = entry.rawText
            .split(separator: "\n", omittingEmptySubsequences: true).first
            .map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = cleanedTitle.isEmpty ? fallback : cleanedTitle

        var name = entry.entryDateKey
        let slug = Self.slug(subject)
        if !slug.isEmpty { name += " \(slug)" }

        // Several entries can share a day, and two can share a title.
        var candidate = name
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(name) (\(suffix))"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// Keeps letters, numbers and spaces; drops everything a filesystem or a person would
    /// trip over. Capped so a rambling first line cannot produce an unopenable path.
    static func slug(_ text: String) -> String {
        let allowed = text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        let collapsed = String(allowed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Markdown

    static func markdown(
        for entry: Entry,
        base: String,
        attachments: [(name: String, isAudio: Bool)]
    ) -> String {
        var out = ""
        let iso = ISO8601DateFormatter()

        // Front matter, so a tool can read this back without parsing prose.
        out += "---\n"
        out += "date: \(entry.entryDateKey)\n"
        if let title = entry.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            out += "title: \(title.replacingOccurrences(of: "\n", with: " "))\n"
        }
        out += "created: \(iso.string(from: entry.createdAt))\n"
        out += "updated: \(iso.string(from: entry.updatedAt))\n"
        if let url = entry.destinationURL { out += "notion: \(url.absoluteString)\n" }
        out += "---\n\n"

        out += "# \(entry.title ?? entry.entryDateKey)\n\n"

        let raw = entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            out += raw + "\n\n"
        }

        if let formatted = entry.formattedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !formatted.isEmpty {
            // Labelled, and second. The user's own words are the record; this is a
            // derivative and the file should not let anyone forget which is which.
            out += "## Structured\n\n" + formatted + "\n\n"
        }

        let photos = attachments.filter { !$0.isAudio }
        if !photos.isEmpty {
            out += "## Attachments\n\n"
            for item in photos {
                out += "![\(item.name)](media/\(Self.urlEncode(base))/\(Self.urlEncode(item.name)))\n"
            }
            out += "\n"
        }

        let audio = attachments.filter(\.isAudio)
        if !audio.isEmpty {
            out += "## Recordings not yet transcribed\n\n"
            out += "These were captured but never turned into text. The audio is here.\n\n"
            for item in audio {
                out += "- [\(item.name)](media/\(Self.urlEncode(base))/\(Self.urlEncode(item.name)))\n"
            }
            out += "\n"
        }

        return out
    }

    /// Spaces and the like, encoded so the links work in a markdown viewer.
    static func urlEncode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )) ?? component
    }

    static func readme(_ summary: Summary) -> String {
        var out = "# Your journal\n\n"
        out += "\(summary.entries) "
        out += summary.entries == 1 ? "entry" : "entries"
        out += ", \(summary.mediaFiles) attachment\(summary.mediaFiles == 1 ? "" : "s")"
        if summary.audioFiles > 0 {
            out += ", \(summary.audioFiles) recording\(summary.audioFiles == 1 ? "" : "s") "
            out += "that were never transcribed"
        }
        out += ".\n\n"
        out += "One markdown file per entry, named by the day it is about so they sort in "
        out += "order. Attachments sit in `media/` beside the entry that owns them, linked "
        out += "relatively \u{2014} keep the folder together and the links keep working.\n\n"
        out += "Nothing here needs the app that wrote it. That is the point.\n"

        if !summary.missingFiles.isEmpty {
            out += "\n## Files that could not be found\n\n"
            out += "These were referenced by an entry but their bytes were missing, so the "
            out += "rest of the export continued without them:\n\n"
            for path in summary.missingFiles { out += "- `\(path)`\n" }
        }
        return out
    }
}
