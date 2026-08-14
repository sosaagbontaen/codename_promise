import Foundation

/// Where an entry ended up, as something the user can actually open.
///
/// Syncing is only satisfying if you can go and look at the result, and the destination's own
/// app is where you'd want to land — not a browser tab asking you to log in.
///
/// Two URLs, because they fail differently. The custom scheme opens the Notion app directly
/// and does nothing at all if it isn't installed. The web URL always works and, on a device
/// with the app, universal links usually hand off to it anyway. Try the first, fall back to
/// the second.
public enum DestinationLink {

    /// Notion page IDs come back as dashed UUIDs but appear in URLs without dashes.
    /// Normalising here rather than at each call site because getting it wrong produces a
    /// link that looks right and 404s.
    public static func notion(pageId: String) -> (app: URL?, web: URL)? {
        let compact = pageId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")

        // A Notion page id is a 32-character hex UUID. Anything else — an empty string, a
        // stub id from a development backend — must not produce a link that goes nowhere.
        guard compact.count == 32,
              compact.allSatisfy({ $0.isHexDigit }),
              let web = URL(string: "https://www.notion.so/\(compact)")
        else { return nil }

        return (app: URL(string: "notion://www.notion.so/\(compact)"), web: web)
    }

    /// The link for a synced entry, or nil when there's nothing to open yet.
    public static func url(for state: SyncState) -> (app: URL?, web: URL)? {
        guard let externalId = state.externalId, !externalId.isEmpty else { return nil }
        switch state.target {
        case .notion:
            return notion(pageId: externalId)
        case .evernote, .obsidian:
            // No link scheme worked out for these yet, and a wrong guess is worse than an
            // absent button.
            return nil
        }
    }
}
