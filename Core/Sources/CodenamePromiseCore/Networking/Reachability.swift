import Foundation
import Network

/// Used in tests and when reachability genuinely doesn't matter — the client's own error
/// mapping already turns a dropped connection into `.offline`.
public struct AlwaysReachable: NetworkReachability {
    public init() {}
    public var isReachable: Bool { true }
}

public struct NeverReachable: NetworkReachability {
    public init() {}
    public var isReachable: Bool { false }
}

/// `NWPathMonitor`-backed reachability.
///
/// This is an optimisation, not a gate: it lets the app skip a request it knows will fail and
/// say "offline" immediately rather than after a timeout. Capture never consults it.
public final class PathMonitorReachability: NetworkReachability, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _isReachable = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            _isReachable = path.status == .satisfied
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.codenamepromise.reachability"))
    }

    deinit { monitor.cancel() }

    public var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        // Defaults to true before the first path update: better to attempt a request and
        // fail than to wrongly refuse one at launch.
        return _isReachable
    }
}
