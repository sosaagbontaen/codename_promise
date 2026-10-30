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
        // A folder in iCloud Drive lists only what iOS last fetched of it, which can be
        // minutes behind: a dump the Mac had finished uploading went unseen, and "Check now"
        // said nothing was waiting. Asking for the folder through a file coordinator makes
        // iCloud bring the listing up to date first.
        await Self.refreshListing(of: inbox)
        // Listing the folder is file system work, possibly against iCloud Drive, so it runs
        // off the main thread. Only filing, which touches the journal, comes back to it.
        let scanner = self.scanner
        var scan = await Task.detached(priority: .utility) { scanner.scan(inbox) }.value

        // A capture folder iCloud knows about but hasn't downloaded lists as empty: on the
        // phone it showed in the Files app with a download button, and the inbox read it as
        // still arriving and never asked for it, so it waited forever. Asking for each such
        // folder downloads its contents; then the inbox looks again.
        if !scan.arriving.isEmpty {
            let folders = scan.arriving
            await withTaskGroup(of: Void.self) { group in
                for folder in folders {
                    group.addTask { await Self.refreshListing(of: folder) }
                }
            }
            scan = await Task.detached(priority: .utility) { scanner.scan(inbox) }.value
        }
        // One per capture: a folder still arriving, plus loose files not inside one. A folder's
        // own missing files are part of it, not more captures.
        // Compared by the capture folder's name: paths can differ by a symlink (/var and
        // /private/var) while naming the same folder.
        let arrivingNames = Set(scan.arriving.map(\.lastPathComponent))
        let looseWaiting = scan.notDownloaded.filter { url in
            !arrivingNames.contains(url.deletingLastPathComponent().lastPathComponent)
        }
        report.waiting = scan.arriving.count + looseWaiting.count

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

    /// Asks iCloud Drive for the folder's current contents and waits for them, up to
    /// `timeout`. Harmless for a folder that isn't in iCloud Drive: access is granted at once.
    /// The limit is there because coordination waits on the file provider, and an inbox
    /// that can't be refreshed is still worth scanning as it stands.
    nonisolated static func refreshListing(of folder: URL, timeout: Double = 10) async {
        try? FileManager.default.startDownloadingUbiquitousItem(at: folder)
        let coordinator = CoordinatorBox(NSFileCoordinator())
        let intent = NSFileAccessIntent.readingIntent(with: folder, options: [])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            coordinator.value.coordinate(with: [intent], queue: OperationQueue()) { _ in once.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.resume() { coordinator.value.cancel() }
            }
        }
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

/// A file coordinator shared between the request and its time limit. It's only ever asked
/// to coordinate once and to cancel, which it allows from any thread.
private final class CoordinatorBox: @unchecked Sendable {
    let value: NSFileCoordinator
    init(_ value: NSFileCoordinator) { self.value = value }
}

/// Resumes a continuation once, from whichever side gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    /// True if this call was the one that resumed it.
    @discardableResult
    func resume() -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
        return pending != nil
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
