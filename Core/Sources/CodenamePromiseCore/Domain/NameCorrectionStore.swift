import Foundation

/// Where the name corrections live.
///
/// On the device, in `UserDefaults`, and nowhere else. Two reasons, and the second is the one
/// that matters: a list of the people in somebody's life is exactly the sort of thing this app
/// promises not to put on a server, and a hosted free tier that wipes its disk when it sleeps
/// would lose it by Tuesday anyway.
///
/// Keeping it local also means corrections work with no backend at all, which is how the app
/// ships and what every new user has.
public struct NameCorrectionStore: @unchecked Sendable {
    private static let key = "nameCorrections"

    /// `UserDefaults` is thread-safe and documented as such; it is simply not annotated
    /// `Sendable`. `BackendSettings` next door solves the same problem by refusing to be
    /// `Sendable` at all, which works there because it is only ever read on the main actor.
    /// This one is read from the transcription queue, so it says what it means instead.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> NameCorrections {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(NameCorrections.self, from: data)
        else { return NameCorrections() }
        return stored
    }

    public func save(_ corrections: NameCorrections) {
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func add(heard: String, meant: String) -> NameCorrections {
        var current = load()
        current.add(NameCorrection(heard: heard, meant: meant))
        save(current)
        return current
    }

    public func remove(_ id: String) -> NameCorrections {
        var current = load()
        current.remove(id)
        save(current)
        return current
    }
}
