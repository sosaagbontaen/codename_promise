import CryptoKit
import Foundation

/// The text of an entry at its various stages of enrichment.
///
/// This is a `Codable` value type stored as a single attribute on `EntryDraft`, not a
/// separate `@Model`. The original spec made it an entity, which gave it an implicit
/// to-one relationship with no delete rule — so deleting a draft left its content row
/// orphaned and unreachable forever. Modelling it as a value also matches how the domain
/// docs always described it. See ADR-010.
public struct EntryContent: Codable, Hashable, Sendable {
    /// User-provided heading. The AI never invents one.
    public var title: String?

    /// The user's own words, typed or dictated. Only the user edits this — formatting
    /// reads it and never writes it. This field is the thing the whole app exists to
    /// protect (invariant 3).
    public var rawText: String

    /// AI-structured version of `rawText`. Regenerable, discardable, never authoritative.
    public var formattedText: String?

    /// Which formatting prompt produced `formattedText`, so output stays reproducible
    /// when the prompt changes. See ADR-017.
    public var formatterVersion: String?

    public init(
        title: String? = nil,
        rawText: String = "",
        formattedText: String? = nil,
        formatterVersion: String? = nil
    ) {
        self.title = title
        self.rawText = rawText
        self.formattedText = formattedText
        self.formatterVersion = formatterVersion
    }

    /// Decoding that tolerates content written before a field existed.
    ///
    /// Synthesised `Codable` requires every key, default value or not — so adding a property
    /// to this struct would make every previously stored entry fail to decode. `EntryContent`
    /// is persisted as a single attribute on `EntryDraft`, so that is not a cosmetic failure:
    /// it is the user's words becoming unreadable.
    ///
    /// Any field added here must be read with `decodeIfPresent` and a default, for the same
    /// reason new SwiftData attributes must carry defaults (ADR-008a).
    ///
    /// That is necessary and **not sufficient**. SwiftData flattens this struct into one
    /// column per property, so adding a field here is a schema change, and Core Data
    /// validates the new column long before any of this code runs: a non-optional addition
    /// fails the migration outright with *"missing attribute values on mandatory destination
    /// attribute"*, and the store won't open at all. A property that needs a non-nil default
    /// belongs on `EntryDraft` as a `@Model` attribute, where a default actually reaches the
    /// entity description. See ADR-008a.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        formattedText = try container.decodeIfPresent(String.self, forKey: .formattedText)
        formatterVersion = try container.decodeIfPresent(String.self, forKey: .formatterVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case title, rawText, formattedText, formatterVersion
    }

    public var isEmpty: Bool {
        rawText.isEmpty && (formattedText?.isEmpty ?? true)
    }

    /// Stable fingerprint of everything a destination would receive.
    ///
    /// Sync dirtiness is decided by comparing this against the hash recorded at the last
    /// successful sync — *not* by comparing `updatedAt` to `lastSyncedAt`. Timestamps
    /// can't work here: invariant 2 bumps `updatedAt` on every mutation, so a sync that
    /// recorded its own completion would immediately mark itself dirty again and loop
    /// forever. See ADR-016.
    public var contentHash: String {
        var hasher = SHA256()
        for field in [title, rawText, formattedText] {
            // Length-prefixed so ("ab", nil) and ("a", "b") can never collide.
            let bytes = Data((field ?? "").utf8)
            hasher.update(data: withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { Data($0) })
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
