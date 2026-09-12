import Foundation

/// What a connection test found.
///
/// The point is telling the two failures apart. "It doesn't work" was the only answer the
/// app could give, so a wrong address and a wrong key looked identical, and the way to find
/// out which was to record something and watch it fail. These are the four things that can
/// actually be true, and each one says what to do next.
public enum BackendCheck: Equatable, Sendable {
    /// No address at all. Not an error: the app works this way by design (ADR-019a).
    case noAddress
    /// Nothing answered at that address.
    case unreachable(String)
    /// The address is right and the key is not.
    case keyRejected
    /// The server wants a key and none is stored.
    case keyMissing
    /// Reached, accepted, and here is what it can do.
    case ready(transcription: String, formatting: String)

    /// Whether dictation and organising will actually work.
    public var isWorking: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Whether the server is real rather than answering from deterministic stubs.
    ///
    /// A stub server responds happily to everything and transcribes nothing useful, so
    /// "connected" on its own would be a misleading thing to tell somebody.
    public var hasRealProviders: Bool {
        if case .ready(let transcription, let formatting) = self {
            return transcription != "stub" && formatting != "stub"
        }
        return false
    }

    public var message: String {
        switch self {
        case .noAddress:
            "No server address yet. Entries are saved on this device."
        case .unreachable(let why):
            why
        case .keyRejected:
            "That address works, but the key was rejected. Check it and save again."
        case .keyMissing:
            "This server needs an API key. Add one above."
        case .ready(let transcription, let formatting)
            where transcription == "stub" || formatting == "stub":
            "Connected, but this server has no AI provider configured, so dictation and arranging will not work."
        case .ready:
            "Connected. Dictation and arranging are working."
        }
    }
}

/// The shape of `/health` this app cares about. Deliberately partial: the endpoint reports
/// more, and a client that decodes every field breaks when the server grows one.
public struct BackendHealth: Decodable, Sendable {
    public let authRequired: Bool
    public let transcription: String
    public let formatting: String

    enum CodingKeys: String, CodingKey {
        case authRequired = "auth_required"
        case transcription
        case formatting
    }
}

private struct AuthCheck: Decodable { let ok: Bool }

/// Asks the backend two questions: are you there, and do you accept this key.
///
/// Two calls rather than one because they fail differently and the difference is the whole
/// value. `/health` needs no key, so it isolates "is this address real"; `/auth/check` does
/// nothing but authenticate, so it isolates the key without transcribing anything.
public struct BackendChecker: Sendable {
    private let client: APIClient
    private let hasStoredKey: @Sendable () -> Bool

    public init(client: APIClient, hasStoredKey: @escaping @Sendable () -> Bool) {
        self.client = client
        self.hasStoredKey = hasStoredKey
    }

    public func check() async -> BackendCheck {
        guard client.isConfigured else { return .noAddress }

        let health: BackendHealth
        do {
            health = try await client.get(path: "health", expecting: BackendHealth.self)
        } catch let error as APIError {
            return .unreachable(error.userFacingMessage)
        } catch {
            return .unreachable(error.localizedDescription)
        }

        // Asked before the key is tried, so "this server wants a key and you have none" is
        // its own answer rather than an indistinguishable rejection.
        if health.authRequired && !hasStoredKey() { return .keyMissing }

        do {
            _ = try await client.get(path: "auth/check", expecting: AuthCheck.self)
        } catch APIError.unauthorized {
            return .keyRejected
        } catch let error as APIError {
            // A server too old to have /auth/check answers 404. The address and the key are
            // as proven as they can be, so report what health said rather than inventing a
            // failure the user cannot act on.
            if case .server(let status, _) = error, status == 404 {
                return .ready(transcription: health.transcription, formatting: health.formatting)
            }
            return .unreachable(error.userFacingMessage)
        } catch {
            return .unreachable(error.localizedDescription)
        }

        return .ready(transcription: health.transcription, formatting: health.formatting)
    }
}
