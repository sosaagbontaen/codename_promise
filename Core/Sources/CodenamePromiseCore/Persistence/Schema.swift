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
/// This one points at the live model types, which is the privilege of being newest. The
/// moment a v3 exists, these get frozen into a `SchemaV2Models.swift` first — see rule 4.
public enum SchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [EntryDraft.self, MediaItem.self, AudioCapture.self, SyncState.self]
    }
}

public enum CodenamePromiseMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }

    public static var stages: [MigrationStage] {
        // Lightweight: every added attribute carries a default, so SwiftData can infer the
        // mapping. Declared explicitly anyway, per rule 3 — an inferred migration that
        // silently stops being inferrable is a bad thing to discover in the field.
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}

public enum CodenamePromiseSchema {
    /// Always build containers from this, never from an ad-hoc `Schema([...])` — an
    /// unversioned container is how you end up unable to migrate.
    public static var current: Schema { Schema(versionedSchema: SchemaV2.self) }
}
