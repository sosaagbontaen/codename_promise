import Foundation
import SwiftData

/// The v1 schema, named on day one.
///
/// This exists before there is anything to migrate *because* it cannot be created
/// retroactively: without a named baseline you cannot later express a migration from the
/// schema you already shipped, leaving a hand-rolled fixup or a wiped store as the only
/// options — in an app holding six years of journal entries. See ADR-008a.
///
/// House rules for evolving this:
///  1. New schema version → new `VersionedSchema` type, never edit a shipped one.
///  2. Every new attribute gets a default so the migration stays lightweight.
///  3. Add a stage to `CodenamePromiseMigrationPlan` even when it is `.lightweight`.
///  4. A version owns *frozen copies* of the models, never the live classes. Only the
///     newest version may point at the types the app actually uses.
///
/// Its models are frozen in `SchemaV1Models.swift`, and rule 4 is written there in blood.
public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [SchemaV1.EntryDraft.self, SchemaV1.MediaItem.self,
         SchemaV1.AudioCapture.self, SchemaV1.SyncState.self]
    }
}

/// Adds attributes that accumulated after v1 shipped:
/// `SyncState.destinationFingerprint`, `SyncState.appendsToExistingPage`,
/// `SyncState.externalTitle` and `AudioCapture.nextTranscriptionAttemptAt`.
///
/// Every one has a default, which is what makes the migration lightweight. What was missing
/// was the *version bump*: attributes were added to the models while `SchemaV1` still claimed
/// to describe them, so a store written by the old build no longer matched the schema the new
/// build declared, and SwiftData refused to open it — "Couldn't open your journal".
///
/// That is rule 1 in the list above, broken three times by the person who wrote it. The rule
/// isn't bureaucracy: the version number is the only signal SwiftData gets that a migration is
/// expected rather than a mismatch.
///
/// Its models are now frozen in `SchemaV2Models.swift`, because v3 exists. It used to point
/// at the live types, which is the privilege of being newest and only that.
public enum SchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [SchemaV2.EntryDraft.self, SchemaV2.MediaItem.self,
         SchemaV2.AudioCapture.self, SchemaV2.SyncState.self]
    }
}

/// Adds the organised entry: `EntryDraft.organisedJSON` and `EntryDraft.organiserVersion`.
///
/// Both are plain scalars with defaults, which is what keeps this lightweight. They are
/// deliberately **not** inside `EntryContent`, even though that is where `formattedText`
/// lives and where they would read most naturally. `EntryContent` is a `Codable` composite
/// and SwiftData flattens it into one column per property, so adding a non-optional field
/// there fails the migration outright with *"missing attribute values on mandatory
/// destination attribute"* and the store will not open. That is ADR-008a, and it is the bug
/// that produced "Couldn't open your journal" on a phone holding real entries.
///
/// This one points at the live model types, which is the privilege of being newest. The
/// Its models are frozen in `SchemaV3Models.swift`, because v4 exists.
public enum SchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [SchemaV3.EntryDraft.self, SchemaV3.MediaItem.self,
         SchemaV3.AudioCapture.self, SchemaV3.SyncState.self]
    }
}

/// Adds per-stage block tracking: `SyncState.photoBlockIds` and `SyncState.videoBlockIds`.
///
/// The words are now written to a destination before the media, in three calls rather than
/// one, and the server deletes exactly the block ids it is handed. One shared list would mean
/// a resumed sync either replaced blocks a different stage owns — the entry losing its
/// words — or re-appended the ones it had already written, giving the page a second copy of
/// every photo.
///
/// Both are arrays with an empty default, which is what keeps this lightweight. They live on
/// `SyncState`, which is a `@Model`, not inside a `Codable` composite: that distinction is
/// ADR-008a and the reason this migration opens the store instead of failing on a mandatory
/// attribute.
///
/// Its models are the live types, which is the privilege of being newest.
public enum SchemaV4: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [EntryDraft.self, MediaItem.self, AudioCapture.self, SyncState.self]
    }
}

public enum CodenamePromiseMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self]
    }

    public static var stages: [MigrationStage] {
        // Lightweight: every added attribute carries a default, so SwiftData can infer the
        // mapping. Declared explicitly anyway, per rule 3 — an inferred migration that
        // silently stops being inferrable is a bad thing to discover in the field.
        [
            .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
            .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
            .lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self),
        ]
    }
}

public enum CodenamePromiseSchema {
    /// Always build containers from this, never from an ad-hoc `Schema([...])` — an
    /// unversioned container is how you end up unable to migrate.
    public static var current: Schema { Schema(versionedSchema: SchemaV4.self) }
}
