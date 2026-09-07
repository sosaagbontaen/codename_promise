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
    /// Where new bytes are written.
    public let root: URL

    /// Older roots that may still hold bytes, newest first.
    ///
    /// Turning on iCloud backup moves where media *goes*, and the tempting next step is to
    /// sweep everything already on disk into the new root. That sweep is a bulk move of the
    /// one category of data in this app that cannot be regenerated, and there is no version
    /// of it that is safe to get wrong. So nothing moves. New files are written to the
    /// current root, old files are read from wherever they already are, and a path resolves
    /// against every root the app has ever used.
    ///
    /// The cost is that a file written before the switch is not backed up by the new
    /// mechanism until something rewrites it. That is a smaller price than a migration that
    /// can lose photos, and it is honest: the settings screen says which files are covered
    /// rather than implying all of them are.
    public let previousRoots: [URL]

    /// `FileManager` is not `Sendable`, so it is deliberately not stored — this type has to
    /// cross actor boundaries and `FileManager.default` is documented as safe to use
    /// concurrently for the single-file operations here.
    private var fileManager: FileManager { .default }

    public init(root: URL, previousRoots: [URL] = []) {
        self.root = root
        self.previousRoots = previousRoots
    }

    /// Default location: `Application Support/Media`, excluded from nothing — journal
    /// media *should* be backed up, and relative paths make restore work.
    public static func makeDefault(backup: BackupMode = .thisPhoneOnly) throws -> MediaFileStore {
        let local = try localRoot()

        guard backup == .iCloud, let cloud = cloudRoot() else {
            return MediaFileStore(root: local)
        }
        // The local root stays readable rather than being emptied into the cloud one. See
        // `previousRoots`.
        return MediaFileStore(root: cloud, previousRoots: [local])
    }

    static func localRoot() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent("Media", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The iCloud location, or nil when iCloud is not usable on this device right now.
    ///
    /// Deliberately **not** under `Documents`. Everything a ubiquity container keeps there
    /// shows up in the Files app, where somebody tidying up can delete their own journal's
    /// photographs without ever opening this app. Outside `Documents` it syncs just the same
    /// and is not presented as loose files to be managed.
    static func cloudRoot() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        else { return nil }
        let root = container.appendingPathComponent("Media", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return root
    }

    // MARK: - Resolving

    /// Where this path lives.
    ///
    /// Resolves against the current root first, then anywhere the app used to write. Falls
    /// back to the current root when the file exists nowhere, so this stays the right answer
    /// for a caller about to *write* rather than read.
    public func url(for relativePath: String) -> URL {
        let primary = root.appendingPathComponent(relativePath, isDirectory: false)
        guard !previousRoots.isEmpty, !fileManager.fileExists(atPath: primary.path) else {
            return primary
        }
        for previous in previousRoots {
            let candidate = previous.appendingPathComponent(relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return primary
    }

    /// Makes sure the bytes are actually on this device.
    ///
    /// iCloud keeps a placeholder rather than the file when space is short, so a photo that
    /// exists as far as the database is concerned can be absent from the disk. Asking for it
    /// starts the download; this returns whether the file is readable *now*, so a caller can
    /// show "fetching from iCloud" instead of a broken thumbnail.
    ///
    /// Harmless for a file that was never in iCloud: `isUbiquitousItem` is false and this
    /// answers from the file system.
    @discardableResult
    public func ensureDownloaded(_ relativePath: String) -> Bool {
        let fileURL = url(for: relativePath)
        if fileManager.fileExists(atPath: fileURL.path) { return true }
        try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
        return false
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

    /// Makes a place in the store for something that is about to be written *by someone
    /// else*, and returns where it goes.
    ///
    /// Everything else here takes bytes that already exist. A recorder cannot work that way:
    /// it streams to a file over minutes, and the whole point is that what it has written so
    /// far survives the app dying. Handing it a temporary file and copying afterwards would
    /// put every recording in a purgeable directory for the length of the recording, which is
    /// the exact shape of the bug this store was built to prevent for photos.
    ///
    /// So the recorder writes straight into the container, and the returned relative path is
    /// what the model stores (ADR-007). Nothing is created but the directory: if the caller
    /// never writes, `reapOrphans` collects it.
    public func reserve(
        id: UUID = UUID(),
        preferredName: String = "original",
        extension ext: String
    ) throws -> ReservedFile {
        let directory = "media/\(id.uuidString.lowercased())"
        let relativePath = "\(directory)/\(preferredName).\(ext)"
        try fileManager.createDirectory(
            at: root.appendingPathComponent(directory, isDirectory: true),
            withIntermediateDirectories: true
        )
        return ReservedFile(id: id, relativePath: relativePath, url: url(for: relativePath))
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

/// A path the store has made room for, not yet written to.
public struct ReservedFile: Sendable {
    public let id: UUID
    public let relativePath: String
    /// Where to write. Never persist this; persist `relativePath`. See ADR-007.
    public let url: URL
}
