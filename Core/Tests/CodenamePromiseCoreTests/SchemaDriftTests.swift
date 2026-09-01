import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// The guard that was missing.
///
/// Attributes were added to the live models three times without bumping the schema version.
/// Every test stayed green, because every test built a fresh in-memory store from whatever
/// the models happened to say that day - and a store that agrees with itself always opens.
/// The failure only appeared on a device holding real entries: "Couldn't open your journal".
///
/// This is the tripwire. It records the shape the current schema version describes, and fails
/// the moment the live models drift from it. Adding a property is not the bug; adding one
/// *while the newest `VersionedSchema` still claims to describe the old shape* is.
///
/// **When this fails, it is telling you to bump the schema.** The fix is never to update the
/// expectation on its own:
///
/// 1. Freeze today's models into a `SchemaVNModels.swift` under the *current* version.
/// 2. Add `SchemaV(N+1)` pointing at the live types, and a migration stage.
/// 3. Then update the expectation below.
///
/// See ADR-008a, which contains the same instructions and was written by someone who then
/// broke them three times.
@Suite("Schema drift")
struct SchemaDriftTests {

    /// Attribute names per entity, as of SchemaV2.
    ///
    /// Order-independent: SwiftData does not promise property ordering, so comparing sets
    /// avoids a test that fails for a reason nobody cares about.
    static let expected: [String: Set<String>] = [
        "EntryDraft": [
            "id", "createdAt", "updatedAt", "entryDateKey", "content",
            "formattedTextEditedByUser", "media", "audioCaptures", "syncStates",
        ],
        "MediaItem": [
            "id", "createdAt", "relativePath", "originalSizeBytes",
            "compressedRelativePath", "compressedSizeBytes", "sortIndex", "kindRaw",
            "compressionLevelRaw", "compressionStatusRaw", "uploadStatusRaw",
            "uploadStartedAt", "uploadAttemptCount", "uploadError", "draft",
        ],
        "AudioCapture": [
            "id", "recordedAt", "relativePath", "durationSeconds", "sizeBytes",
            "chunkIndex", "transcriptionStatusRaw", "transcript", "transcriptionStartedAt",
            "transcriptionAttemptCount", "transcriptionError", "nextTranscriptionAttemptAt",
            "mergedIntoDraftAt", "draft",
        ],
        "SyncState": [
            "id", "targetRaw", "statusRaw", "phaseRaw", "externalId", "syncedContentHash",
            "attemptId", "attemptContentHash", "uploadedFileIds", "insertedBlockIds",
            "destinationFingerprint", "appendsToExistingPage", "externalTitle",
            "startedAt", "lastSyncedAt", "lastSyncError", "attemptCount", "draft",
        ],
    ]

    private func shape(of schema: Schema) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for entity in schema.entities {
            out[entity.name] = Set(entity.properties.map(\.name))
        }
        return out
    }

    @Test("the live models still match the shape SchemaV2 describes")
    func noUndeclaredDrift() {
        let actual = shape(of: CodenamePromiseSchema.current)

        for (entity, expectedProperties) in Self.expected {
            guard let actualProperties = actual[entity] else {
                Issue.record("\(entity) has vanished from the current schema")
                continue
            }
            let added = actualProperties.subtracting(expectedProperties)
            let removed = expectedProperties.subtracting(actualProperties)

            if !added.isEmpty {
                Issue.record("""
                    \(entity) gained \(added.sorted()) without a schema version bump.
                    Freeze the current models into SchemaV2Models.swift, add SchemaV3 \
                    pointing at the live types plus a migration stage, and only then update \
                    the expectation in this file. See ADR-008a.
                    """)
            }
            if !removed.isEmpty {
                Issue.record("""
                    \(entity) lost \(removed.sorted()). Removing an attribute is not a \
                    lightweight migration - existing stores still have that column.
                    """)
            }
        }

        #expect(Set(actual.keys) == Set(Self.expected.keys),
                "an entity was added or removed, which is always a schema change")
    }

    /// The other half of the same discipline: a version that describes nothing distinct is a
    /// rename, and Core Data rejects the plan outright with "Duplicate version checksums".
    @Test("no two schema versions describe the same models")
    func versionsStayDistinct() {
        var shapes: Set<String> = []
        var count = 0
        for version in CodenamePromiseMigrationPlan.schemas {
            count += 1
            var names: [String] = []
            for model in version.models { names.append(String(reflecting: model)) }
            shapes.insert(names.sorted().joined(separator: ","))
        }
        #expect(shapes.count == count,
                "two versions point at the same types - freeze the older one first")
    }
}
