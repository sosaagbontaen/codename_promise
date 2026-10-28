import Foundation
import SwiftData

/// Where the journal's store lives, chosen explicitly rather than left to SwiftData.
///
/// SwiftData's default location moves into the App Group container as soon as the app has
/// an App Group entitlement, which it gained for the share extension. Left implicit, that
/// silently opened a new, empty store beside the old one: every entry still on disk, none
/// of them shown. The rule here makes the choice visible and keeps both histories:
///
/// - If a store already exists in the App Group container, it is the one in use (builds
///   with the entitlement have been writing there).
/// - Otherwise the app's own Application Support store is used, as it always was.
/// - If both exist, entries only the old one has are copied across, then the old store is
///   set aside (renamed, never deleted) so a later delete can't be undone by a re-copy.
///
/// Media and recordings live in the app's own container either way, by relative path, so
/// nothing about their bytes changes. See ADR-007.
public struct StoreLocation: Sendable {
    public static let fileName = "default.store"

    public let legacy: URL
    public let group: URL?

    public init(legacy: URL, group: URL?) {
        self.legacy = legacy
        self.group = group
    }

    /// The app's real locations. `groupIdentifier` nil means no App Group, as in tests.
    public static func standard(groupIdentifier: String?) throws -> StoreLocation {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let group = groupIdentifier
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            .map { $0.appending(path: "Library/Application Support/\(fileName)") }
        return StoreLocation(legacy: support.appending(path: fileName), group: group)
    }

    /// The store to open.
    public var active: URL {
        if let group, Self.exists(group) { return group }
        return legacy
    }

    /// The store whose entries should be brought across, if there is one.
    public var pendingMerge: URL? {
        guard let group, Self.exists(group), Self.exists(legacy), group != legacy else { return nil }
        return legacy
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The SQLite store and its sidecars, which have to move together.
    static func files(of store: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(filePath: store.path(percentEncoded: false) + $0) }
    }
}

public struct StoreMergeReport: Equatable, Sendable {
    public var copied = 0
    public var alreadyPresent = 0
    public var setAsideAt: URL?
}

extension ModelContainerFactory {

    /// Copies every entry in `legacy` that `container` doesn't have, by id, then renames
    /// the legacy files so they're never read again.
    ///
    /// Additive only: an entry present in both is left exactly as the active store has it,
    /// since that's the one the person has been editing. If anything throws, the legacy
    /// files stay where they are and the next launch tries again; nothing is lost either way.
    @MainActor
    public static func mergeLegacyStore(at legacy: URL, into container: ModelContainer) throws -> StoreMergeReport {
        var report = StoreMergeReport()
        do {
            let old = try makeAppContainer(url: legacy, cloudKitDatabase: .none)
            let source = ModelContext(old)
            let target = container.mainContext
            let present = Set(try target.fetch(FetchDescriptor<EntryDraft>()).map(\.id))
            for draft in try source.fetch(FetchDescriptor<EntryDraft>()) {
                if present.contains(draft.id) {
                    report.alreadyPresent += 1
                    continue
                }
                target.insert(draft.copyForAnotherStore())
                report.copied += 1
            }
            if target.hasChanges { try target.save() }
        }
        // The old container is gone by here, so its files are closed.
        report.setAsideAt = try setAside(legacy)
        return report
    }

    /// Renames the store and its sidecars with a `.merged` suffix. Kept, not deleted:
    /// they're the last copy of anything a bug above might have missed.
    static func setAside(_ store: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let manager = FileManager.default
        var renamed = store
        for file in StoreLocation.files(of: store) where StoreLocation.exists(file) {
            let name = file.lastPathComponent.replacingOccurrences(
                of: StoreLocation.fileName, with: "\(StoreLocation.fileName).merged-\(stamp)"
            )
            let destination = file.deletingLastPathComponent().appending(path: name)
            try manager.moveItem(at: file, to: destination)
            if file == store { renamed = destination }
        }
        return renamed
    }
}
