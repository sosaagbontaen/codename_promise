import CodenamePromiseCore
import Foundation

/// Where things dumped in from outside the app wait to be filed, and the filing of them.
///
/// Two folders feed it:
///
/// - **The share sheet's**, in the App Group container shared with the extension. Always
///   there once the entitlement is.
/// - **The Mac's**, a folder in iCloud Drive the Mac capture panel writes to. The phone can
///   only read it once the person has picked it in Settings, which hands the app a
///   security-scoped bookmark. No iCloud entitlement is involved: this is the same access
///   any file a person opens from the Files app grants.
///
/// The recent-entries index is written back to both, so the share sheet and the Mac can offer
/// "add to this entry" as well as "add to this day".
@MainActor
enum CaptureInbox {
    nonisolated static let appGroup = "group.com.codenamepromise.journal"
    static let bookmarkKey = "inbox.macFolderBookmark"
    /// Debug only: a plain path to read as the Mac folder. Lets the simulator, which can see
    /// the Mac's file system, be tested end to end without a folder picker.
    static let pathOverrideKey = "CaptureInboxPathOverride"

    /// The share extension's inbox, or nil in a build without the App Group.
    nonisolated static var shareInbox: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Where captures made on this phone wait: the share sheet's inbox, or a folder of the
    /// app's own if the App Group isn't available. The quick dump sheet writes here too, so
    /// everything is filed by one path.
    nonisolated static var appInbox: URL {
        if let shareInbox { return shareInbox }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Inbox", isDirectory: true)
    }

    nonisolated static var sharedIndexURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(EntryIndex.fileName)
    }

    // MARK: - The Mac folder

    static var isMacFolderConnected: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil || debugOverride != nil
    }

    /// The connected folder's name, for Settings.
    static var macFolderName: String? {
        if let debugOverride { return debugOverride.lastPathComponent }
        return withMacFolder { $0.lastPathComponent }
    }

    /// Saves access to a folder picked in the document picker. The URL is only readable
    /// inside the security scope the picker granted, so the bookmark is made inside it too.
    static func connectMacFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func disconnectMacFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private static var debugOverride: URL? {
        #if DEBUG
        UserDefaults.standard.string(forKey: pathOverrideKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        nil
        #endif
    }

    /// Runs `body` with the Mac folder readable, or returns nil if it isn't connected or the
    /// bookmark no longer resolves (the folder was deleted or renamed).
    private static func withMacFolder<T>(_ body: (URL) throws -> T) rethrows -> T? {
        if let debugOverride { return try body(debugOverride) }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return try body(url)
    }

    // MARK: - Filing

    /// Files everything waiting in both inboxes, then refreshes the index they read.
    static func drain(store: DraftStore, files: MediaFileStore) async -> CaptureIngestor.Outcome {
        let drainer = InboxDrainer(
            ingestor: CaptureIngestor(store: store, fileStore: files),
            ledger: IngestLedger()
        )
        var filed = CaptureIngestor.Outcome()

        filed += await drainer.drain(appInbox).filed
        clearAbandonedStaging(in: appInbox)

        // The scope has to stay open across the await, so this can't use `withMacFolder`.
        if let mac = resolvedMacFolder() {
            filed += await drainer.drain(mac.url).filed
            if mac.scoped { mac.url.stopAccessingSecurityScopedResource() }
        }

        await writeIndex(store: store)
        return filed
    }

    /// The share sheet copies into `.staging` before it writes a capture. If iOS ended it
    /// partway, those copies are of things still in the person's photo library and nothing
    /// was promised about them, so a day later they go.
    private static func clearAbandonedStaging(in inbox: URL) {
        let staging = inbox.appendingPathComponent(".staging", isDirectory: true)
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    private static func resolvedMacFolder() -> (url: URL, scoped: Bool)? {
        if let debugOverride { return (debugOverride, false) }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, url.startAccessingSecurityScopedResource())
    }

    /// What the index was last written from: the journal's revision, which folder it went to,
    /// and the day (it lists the last sixty days, so it shifts at midnight on its own).
    private struct IndexStamp: Equatable {
        let revision: Int
        let macFolder: Data?
        let macOverride: URL?
        let day: CalendarDay
    }
    private static var lastIndexed: IndexStamp?

    /// Rewrites the recent-entries list. Cheap, and wrong only in the harmless direction.
    ///
    /// Skipped when nothing it's built from has changed, which is most drains: every launch
    /// and every return to the app runs one. When it does run, the list is built here, on the
    /// main actor where the store lives, and the files are written off it. A coordinated
    /// write into iCloud Drive can wait on the file provider, and it used to wait with the
    /// interface frozen.
    static func writeIndex(store: DraftStore) async {
        let stamp = IndexStamp(
            revision: store.revision,
            macFolder: UserDefaults.standard.data(forKey: bookmarkKey),
            macOverride: debugOverride,
            day: CalendarDay.today()
        )
        guard stamp != lastIndexed else { return }
        guard let index = try? EntryIndex.make(from: store) else { return }
        lastIndexed = stamp
        let shared = sharedIndexURL
        let mac = resolvedMacFolder()
        await Task.detached(priority: .utility) {
            if let shared { try? index.write(to: shared) }
            if let mac {
                defer { if mac.scoped { mac.url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                let target = mac.url.appendingPathComponent(EntryIndex.fileName)
                NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) {
                    try? index.write(to: $0)
                }
            }
        }.value
    }

    /// "2 photos and a note", for the notice the list shows.
    static func describe(_ outcome: CaptureIngestor.Outcome) -> String {
        var parts: [String] = []
        func add(_ n: Int, _ one: String, _ many: String) {
            guard n > 0 else { return }
            parts.append(n == 1 ? "a \(one)" : "\(n) \(many)")
        }
        add(outcome.photos, "photo", "photos")
        add(outcome.videos, "video", "videos")
        add(outcome.recordings, "recording", "recordings")
        add(outcome.jots, "note", "notes")
        let list: String
        switch parts.count {
        case 0: list = "nothing"
        case 1: list = parts[0]
        default: list = parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
        let entries = outcome.entryIds.count
        return "Added \(list) from your inbox to \(entries == 1 ? "an entry" : "\(entries) entries")."
    }
}
