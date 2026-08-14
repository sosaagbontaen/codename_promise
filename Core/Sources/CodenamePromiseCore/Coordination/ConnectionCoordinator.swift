import Foundation
import Observation

/// Drives the Notion connect-and-pick flow.
///
/// Lives in `Core` rather than the view so the state machine is testable without a browser:
/// the interesting behaviour is what happens when the user cancels, when the server has no
/// integration configured, or when they pick a database that turns out to be unusable.
///
/// The web session itself stays in the app — this type produces the URL and reacts to the
/// outcome, but never opens anything.
@MainActor
@Observable
public final class ConnectionCoordinator {
    public enum Phase: Equatable {
        case idle
        case loading
        /// A web authentication session is open.
        case authorizing
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var status: NotionConnectionStatus = .disconnected
    public private(set) var databases: [NotionDatabase] = []
    /// Set while a specific database is being chosen, so the row can show a spinner.
    public private(set) var selectingDatabaseId: String?

    private let service: any NotionConnectionService

    public init(service: any NotionConnectionService) {
        self.service = service
    }

    public var authorizationURL: URL? { service.authorizationURL }

    /// True when the backend can't offer sign-in at all, so the UI should explain that rather
    /// than showing a button that will fail.
    public var isUnavailable: Bool { !status.configurable && !status.connected }

    public func refresh() async {
        phase = .loading
        do {
            status = try await service.status()
            if status.connected {
                databases = try await service.databases()
            } else {
                databases = []
            }
            phase = .idle
        } catch let error as APIError {
            phase = .failed(error.userFacingMessage)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func beginAuthorizing() {
        phase = .authorizing
    }

    /// Called when the web session finishes, whatever the outcome.
    ///
    /// Cancellation is not a failure — the user changed their mind, and presenting an error
    /// for that would be wrong. Either way the truth comes from re-reading server state
    /// rather than from what the browser handed back.
    public func finishAuthorizing(cancelled: Bool) async {
        if cancelled {
            phase = .idle
            return
        }
        await refresh()
    }

    public func authorizationFailed(_ message: String) {
        phase = .failed(message)
    }

    public func selectDatabase(_ database: NotionDatabase) async {
        selectingDatabaseId = database.id
        defer { selectingDatabaseId = nil }
        do {
            status = try await service.selectDatabase(id: database.id)
            phase = .idle
        } catch let error as APIError {
            // A 422 here means the database is unusable — no date column, say. The server's
            // own message is more specific than anything this layer could invent.
            if case .server(_, let detail) = error, let detail, !detail.isEmpty {
                phase = .failed(Self.readableDetail(detail))
            } else {
                phase = .failed(error.userFacingMessage)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func disconnect() async {
        phase = .loading
        do {
            try await service.disconnect()
            status = .disconnected
            databases = []
            phase = .idle
        } catch let error as APIError {
            phase = .failed(error.userFacingMessage)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    /// FastAPI wraps errors as `{"detail": "..."}`. Show the sentence, not the JSON.
    static func readableDetail(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String
        else { return body }
        return detail
    }
}
