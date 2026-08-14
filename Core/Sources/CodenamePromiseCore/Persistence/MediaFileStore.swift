import Foundation

/// Owns the bytes. Models only ever hold paths *relative* to this store's root.
///
/// Two failure modes this exists to prevent, both of which the original spec walked into:
///
///  1. `PhotosPicker` hands over a URL in a temp directory. Store that path and iOS will
///     purge the file out from under you — the photo is simply gone on next launch. So
///     `adopt(fileAt:)` copies the bytes into the app container *before* anything is
///     persisted, and that copy is what the model references.
///  2. Absolute container paths break on restore-from-backup, because the container UUID
///     changes. Every reference is relative and resolved against `root` at read time, so
///     the whole library survives the container moving. See ADR-007.
public struct MediaFileStore: Sendable {
    public let root: URL

    /// `FileManager` is not `Sendable`, so it is deliberately not stored — this type has to
    /// cross actor boundaries and `FileManager.default` is documented as safe to use
    /// concurrently for the single-file operations here.
    private var fileManager: FileManager { .default }

    public init(root: URL) {
        self.root = root
    }

    /// Default location: `Application Support/Media`, excluded from nothing — journal
    /// media *should* be backed up, and relative paths make restore work.
    public static func makeDefault() throws -> MediaFileStore {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent("Media", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return MediaFileStore(root: root)
    }

    // MARK: - Resolving

    public func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    public func exists(_ relativePath: String) -> Bool {
        fileManager.fileExists(atPath: url(for: relativePath).path)
    }

    public func sizeBytes(of relativePath: String) -> Int? {
        try? fileManager.attributesOfItem(atPath: url(for: relativePath).path)[.size] as? Int
    }

    // MARK: - Writing

    /// Copies an external file into the store and returns its relative path.
    ///
    /// This is the moment "never lose work" becomes true for media. Call it before
    /// creating the `MediaItem`, not after.
    @discardableResult
    public func adopt(
        fileAt source: URL,
        id: UUID = UUID(),
        preferredName: String = "original"
    ) throws -> AdoptedFile {
        let directory = "media/\(id.uuidString.lowercased())"
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension.lowercased()
        let relativePath = "\(directory)/\(preferredName).\(ext)"

        try fileManager.createDirectory(
            at: root.appendingPathComponent(directory, isDirectory: true),
            withIntermediateDirectories: true
        )

        let destination = url(for: relativePath)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)

        let size = sizeBytes(of: relativePath) ?? 0
        return AdoptedFile(id: id, relativePath: relativePath, sizeBytes: size)
    }

    /// Writes in-memory data (a finished audio chunk, a compressed derivative) into the
    /// store and returns its relative path.
    @discardableResult
    public func write(
        _ data: Data,
        id: UUID = UUID(),
        preferredName: String = "original",
        extension ext: String
    ) throws -> AdoptedFile {
        let directory = "media/\(id.uuidString.lowercased())"
        let relativePath = "\(directory)/\(preferredName).\(ext)"

        try fileManager.createDirectory(
            at: root.appendingPathComponent(directory, isDirectory: true),
            withIntermediateDirectories: true
        )
        // .atomic so a crash mid-write leaves either the old file or the new one, never
        // a half-written one that would transcribe or upload as garbage.
        try data.write(to: url(for: relativePath), options: .atomic)

        return AdoptedFile(id: id, relativePath: relativePath, sizeBytes: data.count)
    }

    // MARK: - Deleting

    /// Removes bytes for the given relative paths, and prunes now-empty item directories.
    /// Cascade delete rules remove rows, never files — this is the other half. See ADR-018a.
    public func delete(relativePaths: [String]) {
        for path in relativePaths where !path.isEmpty {
            let fileURL = url(for: path)
            try? fileManager.removeItem(at: fileURL)

            let directory = fileURL.deletingLastPathComponent()
            if directory != root,
               let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path),
               remaining.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    /// Deletes any file in the store not claimed by a live record.
    ///
    /// Crashes between `adopt` and the model save leave bytes with no owner. Deliberately a
    /// separate maintenance pass rather than something inline: an unreferenced file wastes
    /// space, while deleting a referenced one loses work, so this errs toward keeping.
    public func reapOrphans(claimedRelativePaths: Set<String>) -> [String] {
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var removed: [String] = []
        let rootPath = root.standardizedFileURL.path

        for case let fileURL as URL in walker {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            let full = fileURL.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            let relative = String(full.dropFirst(rootPath.count).drop(while: { $0 == "/" }))

            if !claimedRelativePaths.contains(relative) {
                try? fileManager.removeItem(at: fileURL)
                removed.append(relative)
            }
        }
        return removed
    }
}

public struct AdoptedFile: Sendable, Hashable {
    public let id: UUID
    public let relativePath: String
    public let sizeBytes: Int
}
