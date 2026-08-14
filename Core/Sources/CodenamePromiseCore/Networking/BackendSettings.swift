import Foundation

/// Where the backend lives, resolvable at runtime.
///
/// The build setting alone is not enough. `http://localhost:8077` is correct in the
/// simulator, which shares the Mac's network stack, and meaningless on a physical phone
/// where `localhost` is the phone itself. Rebuilding with a different base URL every time
/// you switch between the two is friction that shows up as "it just says no backend".
///
/// So: an override stored on the device wins, falling back to whatever the build was
/// configured with. Nothing here is a secret — the API key still lives in the Keychain.
/// Deliberately not `Sendable`: it holds a `UserDefaults`, and it is only ever read on the
/// main actor at launch or from the settings screen. The `APIConfiguration` it produces is
/// what crosses actor boundaries.
public struct BackendSettings {
    public static let overrideKey = "BackendBaseURLOverride"

    private let defaults: UserDefaults
    private let bundledValue: String?

    public init(defaults: UserDefaults = .standard, bundledValue: String?) {
        self.defaults = defaults
        self.bundledValue = bundledValue
    }

    /// The URL to use, or nil when nothing is configured — which is a supported state, not
    /// an error. See ADR-019a.
    public var baseURL: URL? {
        Self.parse(overrideValue) ?? Self.parse(bundledValue)
    }

    /// The user-supplied override, if any.
    public var overrideValue: String? {
        defaults.string(forKey: Self.overrideKey)
    }

    /// What the app was built with, shown so the user can see what they are overriding.
    public var bundled: String? { Self.normalized(bundledValue) }

    public var isUsingOverride: Bool { Self.parse(overrideValue) != nil }

    /// Stores an override. Passing nil or blank restores the built-in value.
    public func setOverride(_ raw: String?) {
        guard let value = Self.normalized(raw) else {
            defaults.removeObject(forKey: Self.overrideKey)
            return
        }
        defaults.set(value, forKey: Self.overrideKey)
    }

    /// Validates without storing, so the UI can refuse nonsense before a restart.
    public static func isValid(_ raw: String) -> Bool { parse(raw) != nil }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func parse(_ raw: String?) -> URL? {
        guard let value = normalized(raw),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
