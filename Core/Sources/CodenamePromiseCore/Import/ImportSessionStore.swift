import Foundation

/// Where an import in progress keeps its photos and its plan.
///
/// Application Support, not the temporary directory. The old import wrote every photo to
/// `temporaryDirectory`, which iOS is entitled to empty whenever it likes — including while
/// the app is suspended in the background, which is exactly when a long import is most
/// likely to be sitting half-done.
///
/// One import at a time, because that is all the screen offers. Its photos and its manifest
/// share a directory so discarding the import is one deletion and cannot leave half of it
/// behind.
public struct ImportSessionStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func makeDefault() throws -> ImportSessionStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let root = support.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ImportSessionStore(root: root)
    }

    public func directory(for session: ImportSession) -> URL {
        directory(for: session.id)
    }

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    public func url(for item: ImportSession.Item, in session: ImportSession) -> URL {
        directory(for: session).appendingPathComponent(item.filename)
    }

    private func manifestURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("manifest.json")
    }

    /// The import that was in progress, if there was one.
    ///
    /// A manifest that cannot be read is not a crash and not an empty import either: its
    /// directory is left where it is, so the photos in it are not deleted on the strength of
    /// a parse error. The newest readable one wins.
    public func current() -> ImportSession? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }

        // Default date encoding, not ISO 8601: that one drops fractional seconds, so a plan
        // read back from disk was not equal to the plan that was written.
        let decoder = JSONDecoder()
        return entries
            .compactMap { dir -> ImportSession? in
                let manifest = dir.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifest) else { return nil }
                return try? decoder.decode(ImportSession.self, from: data)
            }
            .max { $0.startedAt < $1.startedAt }
    }

    /// Makes the directory a new import will stage into.
    public func prepare(_ session: ImportSession) throws {
        try FileManager.default.createDirectory(
            at: directory(for: session), withIntermediateDirectories: true
        )
        try save(session)
    }

    /// Writes the plan, atomically, so a crash halfway through a write leaves the previous
    /// version rather than a truncated file that loses the whole import.
    public func save(_ session: ImportSession) throws {
        let data = try JSONEncoder().encode(session)
        try data.write(to: manifestURL(for: session.id), options: .atomic)
    }

    /// Moves a received file into the import. Returns the filename it was given.
    ///
    /// Moved rather than copied: the file the picker handed over is already a private copy,
    /// and five hundred photos is gigabytes to write twice.
    public func adopt(fileAt source: URL, id: UUID, into session: ImportSession) throws -> String {
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension.lowercased()
        let filename = "\(id.uuidString.lowercased()).\(ext)"
        let destination = directory(for: session).appendingPathComponent(filename)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            // Across volumes a move is a copy anyway; do it explicitly rather than lose the
            // photo over a filesystem boundary.
            try fm.copyItem(at: source, to: destination)
            try? fm.removeItem(at: source)
        }
        return filename
    }

    public func discard(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// Everything, for when an import is cancelled or finished.
    public func discardAll() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries { try? FileManager.default.removeItem(at: entry) }
    }
}
