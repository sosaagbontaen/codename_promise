import CryptoKit
import Foundation

/// Reads an inbox folder and sorts what is in it.
///
/// Three kinds of thing turn up:
///
/// - **Capture folders** written by the share sheet or the Mac panel. Ready once the manifest
///   is there and every file it names is present.
/// - **Loose files** dropped straight into the folder: a Mac screenshot saved there, a photo
///   dragged in from Finder, a text file. Each becomes a capture of its own, filed by the day
///   it was taken.
/// - **iCloud placeholders** (`.name.icloud`), for files iCloud Drive knows about but hasn't
///   downloaded yet. Reported so the app can ask for them, and taken on a later pass.
///
/// Everything here is synchronous file listing. Downloading and file coordination are the
/// app's job, because they depend on where the folder lives.
public struct InboxScanner: Sendable {

    public struct Ready: Sendable, Equatable {
        public let capture: Capture
        /// The folder the capture's file names are relative to.
        public let directory: URL
        /// What to delete once it has been filed. For a loose file, the file itself.
        public let removable: URL
    }

    public struct Result: Sendable {
        public var ready: [Ready] = []
        /// Capture folders that exist but aren't complete yet.
        public var arriving: [URL] = []
        /// Files iCloud hasn't downloaded yet, as their real (not placeholder) URLs.
        public var notDownloaded: [URL] = []
    }

    /// Files whose names start with this are the app's own and never captures.
    public static let reservedPrefix = "_"

    public init() {}

    public func scan(_ inbox: URL, now: Date = Date()) -> Result {
        let fm = FileManager.default
        var result = Result()
        guard let entries = try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return result }

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent

            if let real = Self.realURL(forPlaceholder: url) {
                result.notDownloaded.append(real)
                continue
            }
            if name.hasPrefix(".") || name.hasPrefix(Self.reservedPrefix) { continue }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                switch readCaptureFolder(url) {
                case .ready(let capture):
                    result.ready.append(Ready(capture: capture, directory: url, removable: url))
                case .arriving(let missing):
                    result.arriving.append(url)
                    result.notDownloaded.append(contentsOf: missing)
                case .notACapture:
                    continue
                }
            } else if let loose = looseCapture(url, now: now) {
                result.ready.append(
                    Ready(capture: loose, directory: inbox, removable: url)
                )
            }
        }
        return result
    }

    private enum FolderState {
        case ready(Capture)
        case arriving(missing: [URL])
        case notACapture
    }

    private func readCaptureFolder(_ folder: URL) -> FolderState {
        let fm = FileManager.default
        let manifest = folder.appendingPathComponent(Capture.manifestName)

        guard fm.fileExists(atPath: manifest.path) else {
            // The manifest may simply not have synced yet.
            if fm.fileExists(atPath: Self.placeholderURL(for: manifest).path) {
                return .arriving(missing: [manifest])
            }
            // A folder with files but no manifest at all is still arriving if it looks like
            // one of ours (named by a UUID); anything else isn't ours to touch.
            return UUID(uuidString: folder.lastPathComponent) != nil
                ? .arriving(missing: []) : .notACapture
        }

        guard let data = try? Data(contentsOf: manifest),
              let capture = try? JSONDecoder.capture.decode(Capture.self, from: data)
        else {
            // Written by a newer version, or damaged. Left in place rather than deleted:
            // it may hold someone's photos.
            return .notACapture
        }

        let missing = capture.files
            .map { folder.appendingPathComponent($0.name) }
            .filter { !fm.fileExists(atPath: $0.path) }
        return missing.isEmpty ? .ready(capture) : .arriving(missing: missing)
    }

    /// A single file dropped into the folder, as a capture.
    ///
    /// Its id is derived from the file's name, size and date, so scanning the same file twice
    /// produces the same capture, and the same attachment id, and nothing is filed twice.
    func looseCapture(_ url: URL, now: Date) -> Capture? {
        guard let kind = Capture.Kind.infer(fromExtension: url.pathExtension) else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate ?? now
        let seed = "\(url.lastPathComponent)|\(size)|\(Int(modified.timeIntervalSince1970))"

        let file = Capture.File(id: Self.stableUUID(seed + "|file"), name: url.lastPathComponent, kind: kind)
        return Capture(
            id: Self.stableUUID(seed),
            createdAt: modified,
            destination: .byCaptureDate,
            text: nil,
            files: [file],
            source: "folder"
        )
    }

    // MARK: - iCloud placeholders

    /// `.photo.jpg.icloud` → `photo.jpg`, or nil if the name isn't a placeholder.
    static func realURL(forPlaceholder url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".x.icloud".count - 1
        else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        guard !real.isEmpty else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    static func stableUUID(_ seed: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
