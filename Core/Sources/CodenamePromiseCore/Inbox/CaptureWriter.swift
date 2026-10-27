import Foundation

/// Writes a capture into an inbox folder. Used by the share extension and the Mac panel.
///
/// Files first, manifest last, and the manifest atomically. A reader treats a folder with no
/// manifest, or with a manifest naming files that aren't there yet, as still arriving. That
/// ordering is what makes it safe for the folder to be in iCloud Drive, where the phone can
/// see a capture while it is still halfway through syncing.
public struct CaptureWriter: Sendable {
    public let inbox: URL

    public init(inbox: URL) {
        self.inbox = inbox
    }

    /// A file to include, and whether to move it (it was a temporary copy) or copy it (it
    /// belongs to someone, such as a photo dragged out of Finder).
    public struct Source: Sendable {
        public let url: URL
        public let kind: Capture.Kind
        public let move: Bool
        /// Becomes the attachment's id. Supplied when a `CapturePlan` already refers to it.
        public let id: UUID

        public init(url: URL, kind: Capture.Kind, move: Bool = false, id: UUID = UUID()) {
            self.url = url
            self.kind = kind
            self.move = move
            self.id = id
        }
    }

    /// Writes a capture arranged by day.
    @discardableResult
    public func write(
        plan: CapturePlan,
        sources: [Source],
        source: String,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> Capture {
        try write(text: nil, sources: sources, destination: .byCaptureDate, groups: plan.groups,
                  source: source, id: id, now: now)
    }

    /// Writes the capture and returns it as written.
    @discardableResult
    public func write(
        text: String?,
        sources: [Source],
        destination: Capture.Destination,
        groups: [Capture.Group]? = nil,
        source: String,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> Capture {
        let fm = FileManager.default
        let folder = inbox.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var files: [Capture.File] = []
        do {
            for item in sources {
                let fileId = item.id
                let ext = item.url.pathExtension.isEmpty ? "dat" : item.url.pathExtension.lowercased()
                let name = "\(fileId.uuidString.lowercased()).\(ext)"
                let target = folder.appendingPathComponent(name)
                if item.move {
                    do { try fm.moveItem(at: item.url, to: target) } catch {
                        try fm.copyItem(at: item.url, to: target)
                        try? fm.removeItem(at: item.url)
                    }
                } else {
                    try fm.copyItem(at: item.url, to: target)
                }
                files.append(Capture.File(id: fileId, name: name, kind: item.kind))
            }

            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let capture = Capture(
                id: id, createdAt: now, destination: destination,
                text: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                files: files, groups: groups, source: source
            )
            let data = try JSONEncoder.capture.encode(capture)
            try data.write(to: folder.appendingPathComponent(Capture.manifestName), options: .atomic)
            return capture
        } catch {
            // Half a capture is worse than none: it would sit in the inbox forever, never
            // complete. The originals are untouched unless they were temporary copies.
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}

extension JSONEncoder {
    /// ISO 8601 rather than the default, because this file is read by a different program
    /// from the one that wrote it and is meant to be legible if anyone opens it.
    static var capture: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var capture: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
