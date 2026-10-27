import Foundation

/// Empties an inbox folder into the journal: scan, file, then delete what was filed.
///
/// A capture is deleted only after everything in it is in the journal and saved. If filing
/// fails partway, the capture stays where it is and the next pass tries again, which files
/// nothing twice (see `CaptureIngestor`).
///
/// The ledger covers the gap between filing and deleting. If the app dies in between, or the
/// delete fails because iCloud is busy with the folder, the next pass sees the capture is
/// already done and only deletes it. Without that, a jot the person had since edited out of
/// their entry would come back.
@MainActor
public final class InboxDrainer {
    private let ingestor: CaptureIngestor
    private let ledger: IngestLedger
    private let scanner = InboxScanner()

    public init(ingestor: CaptureIngestor, ledger: IngestLedger) {
        self.ingestor = ingestor
        self.ledger = ledger
    }

    public struct Report: Sendable {
        public var filed = CaptureIngestor.Outcome()
        /// Captures seen but not complete yet, typically still syncing.
        public var waiting = 0
        /// Captures that couldn't be read and were left for another try.
        public var failed = 0
    }

    public func drain(_ inbox: URL) async -> Report {
        var report = Report()
        // Listing the folder is file system work, possibly against iCloud Drive, so it runs
        // off the main thread. Only filing, which touches the journal, comes back to it.
        let scanner = self.scanner
        let scan = await Task.detached(priority: .utility) { scanner.scan(inbox) }.value
        report.waiting = scan.arriving.count + scan.notDownloaded.count

        // Asking is harmless for a folder that isn't in iCloud Drive; it just fails.
        for url in scan.notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        for ready in scan.ready {
            if ledger.contains(ready.capture.id) {
                Self.remove(ready.removable)
                continue
            }
            do {
                report.filed += try await ingestor.ingest(ready)
                ledger.record(ready.capture.id)
                Self.remove(ready.removable)
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    /// Deletes through a file coordinator, so iCloud Drive hears about it rather than
    /// re-downloading the folder a moment later.
    static func remove(_ url: URL) {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            try? FileManager.default.removeItem(at: target)
        }
    }
}

/// The ids of captures already filed. Small, and kept outside the journal on purpose: it is
/// bookkeeping about the inbox, not part of anyone's entries.
public final class IngestLedger: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "inbox.filedCaptureIds", limit: Int = 2_000) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
    }

    public func contains(_ id: UUID) -> Bool {
        lock.withLock { ids.contains(id.uuidString) }
    }

    public func record(_ id: UUID) {
        lock.withLock {
            var list = ids
            guard !list.contains(id.uuidString) else { return }
            list.append(id.uuidString)
            // Oldest first out. A capture this old is long gone from the inbox.
            if list.count > limit { list.removeFirst(list.count - limit) }
            defaults.set(list, forKey: key)
        }
    }

    private var ids: [String] { defaults.stringArray(forKey: key) ?? [] }
}
