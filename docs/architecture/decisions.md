# Decision register

Every ADR reference in the source code points here. Each entry records what was decided,
the failure it prevents, and where it lives.

These came out of a pre-implementation architecture review of the original spec, conducted
before any code was written. The review found 25 issues; three did not survive scrutiny and
are recorded below as **Rejected** with the reasoning, because a rejected decision is worth
as much as an accepted one when the question comes back.

**Status key** — `Accepted`: implemented. `Planned`: decided, not yet built.
`Deferred`: deliberately not now, additive later. `Rejected`: considered and declined.

---

## Accepted — durability and correctness

### ADR-001 · Saves are explicit, never left to autosave
**Status:** Accepted · [`DraftStore`](../../Core/Sources/CodenamePromiseCore/Persistence/DraftStore.swift)

SwiftData's autosave is not a per-mutation durability guarantee — it commits at opportune
moments, chiefly around scene-phase changes. During an eight-minute foreground dictation no
such moment arrives, so a jetsam takes everything since the last opportunistic save.

**Decided:** every mutating method on `DraftStore` calls `flush()` before returning; views
debounce keystrokes (~300ms) into the model and flush again on `scenePhase` change. Autosave
stays enabled as a backstop only.

### ADR-002 · Dictation audio is a durable, first-class artifact
**Status:** Accepted · [`AudioCapture`](../../Core/Sources/CodenamePromiseCore/Models/AudioCapture.swift)

The original spec's `/stt` took audio and returned a transcript, with the audio living only
in a buffer. Record ten minutes, lose the connection, lose the reflection — the exact bug
the project was founded to eliminate.

**Decided:** audio is written to the container and committed *before* transcription is
attempted, modelled as `AudioCapture` with its own lifecycle and lease. It is released only
once `mergedIntoDraftAt` is set, meaning the transcript is durably part of the draft.
Long dictations chunk via `chunkIndex` so a failure costs one chunk.

**Why not `MediaType.audio`:** photos are attached and kept forever; dictation audio is
scaffolding torn down once its words are safe. Different lifecycle, different model.

### ADR-003 · Every mutating destination call carries an idempotency key
**Status:** Accepted, both sides · [`SyncCoordinator`](../../Core/Sources/CodenamePromiseCore/Coordination/SyncCoordinator.swift) and [`backend/app/idempotency.py`](../../backend/app/idempotency.py) · [`SyncState`](../../Core/Sources/CodenamePromiseCore/Models/SyncState.swift), [`IdempotencyKey`](../../Core/Sources/CodenamePromiseCore/Services/ServiceContracts.swift)

`POST /notion/insert-content` is not idempotent. A successful insert whose `200` is lost,
followed by a retry, writes the entry into Notion twice and leaves the user hand-deleting
blocks.

**Decided:** `SyncState.attemptId` is generated once per logical attempt and reused across
retries of the same content; the backend caches results by key and replays instead of
re-writing. The key rotates when content changes, because that is genuinely a different
write.

### ADR-004 · In-flight states are leases, not flags
**Status:** Accepted · `DraftStore.reconcileAbandonedOperations()`

`.syncing` documented as "don't retry yet" plus a process death equals a permanently
unsyncable draft with no user-visible way out. Same for `.uploading` and `.transcribing`.

**Decided:** each carries a `startedAt`; launch reconciliation demotes anything older than
`staleOperationTimeout` (default 5 min). Sync and upload go to `.failed` keeping phase,
`externalId` and attempt count so the retry resumes. Transcription goes back to `.pending` —
the audio never left the disk, so calling it a failure would be a lie.

### ADR-005 · Multi-step sync records its progress
**Status:** Accepted · `SyncState.phase`, `uploadedFileIds`, `insertedBlockIds`, driven by [`SyncCoordinator`](../../Core/Sources/CodenamePromiseCore/Coordination/SyncCoordinator.swift)

One `status` field cannot represent "page created, files uploaded, content insert failed",
so a retry either restarts (duplicating) or gives up.

**Decided:** `SyncPhase` advances monotonically and is persisted with each successful step,
alongside the destination IDs already obtained. Retries skip covered steps.

**Correction found while building the coordinator.** `beginAttempt` originally cleared
`insertedBlockIds` and `uploadedFileIds` whenever content changed, on the reasoning that a new
attempt starts clean. That was a category error: those IDs describe what exists *in the
destination*, not what the attempt has done. Clearing them meant editing a synced entry and
re-syncing would append a second copy beside the first — the same duplication ADR-003 guards
against, reached by editing rather than retrying. Attempt state (`attemptId`, `phase`) rotates
on content change; destination state persists. Covered by
`editingRotatesTheAttempt`.

### ADR-006 · `entryDate` is domain data, distinct from `createdAt`
**Status:** Accepted · [`CalendarDay`](../../Core/Sources/CodenamePromiseCore/Domain/CalendarDay.swift)

A daily journal with only an instant misfiles the 00:30-about-yesterday case, breaks
grouping across timezones, and leaves the destination page's identity undefined.

**Decided:** `CalendarDay`, stored as `yyyy-MM-dd` so lexicographic order is chronological
order and range predicates work without date arithmetic. Defaulted from `createdAt` in the
user's timezone, always user-editable.

**Page identity — revised, and this correction matters.** The original rule was "one
destination page per `entryDate`", with `ensurePage` searching the database for a page
carrying that date and reusing it. That was wrong in two ways:

1. It merged separate entries written on the same day into one page. A person who journals
   twice in a day gets one page, silently.
2. Far worse, it adopted pages this app never created. A user with an existing hand-written
   entry for that date had it claimed and written into — the app overwriting the user's own
   journal, which is the precise failure the entire project exists to prevent. Observed in
   practice, not hypothetically.

**Now:** page identity is the **draft**. Each `EntryDraft` gets its own page and `entryDate`
is a property on it. `ensurePage` only ever reuses a page id the client previously recorded;
it never goes looking for a page to adopt.

Retries are covered by the recorded `externalId` (ADR-005) and the idempotency key (ADR-003).
The residual risk is a duplicate page when a response is lost *and* the idempotency cache has
been dropped. That trade is deliberate: a visible duplicate is vastly preferable to silently
overwriting something the user wrote. Covered by
`test_a_page_the_app_never_created_is_never_adopted`.

### ADR-007 · Media bytes are owned and referenced relatively
**Status:** Accepted · [`MediaFileStore`](../../Core/Sources/CodenamePromiseCore/Persistence/MediaFileStore.swift)

Two guaranteed data-loss paths: a stored `PhotosPicker` temp URL gets purged, and absolute
container paths dangle after restore-from-backup because the container UUID changes.

**Decided:** bytes are copied into the app container on attach, before the model row exists,
and referenced by a path relative to the media root. Ordering is bytes-first so the worst
case is an orphan file, never a row pointing at nothing.

### ADR-008a · The schema is versioned from v1
**Status:** Accepted · [`Schema.swift`](../../Core/Sources/CodenamePromiseCore/Persistence/Schema.swift)

Without a named baseline you cannot later express a migration from the schema you already
shipped — leaving a hand-rolled fixup or a wiped store, in an app holding years of entries.

**Decided:** `SchemaV1: VersionedSchema` plus a `SchemaMigrationPlan` exist before there is
anything to migrate. House rules: never edit a shipped `VersionedSchema`; every new
attribute gets a default; add a stage even when it is lightweight.

**Amended** after both halves of this were got wrong in one release, on a device holding real
entries:

1. Attributes were added to the models three times without a version bump. `SchemaV1` still
   claimed to describe them, so a store written by the older build no longer matched the
   schema the new build declared and SwiftData refused to open it — *"Couldn't open your
   journal"*.
2. The fix — adding `SchemaV2` — pointed it at the **same four model classes** as `SchemaV1`.
   Two versions describing an identical shape hash identically, and Core Data rejects the
   plan with `NSInvalidArgumentException: Duplicate version checksums detected`. That is an
   Objective-C exception thrown during store load, so the app does not show an error, it
   terminates. The store was still unopenable; the failure had only moved.

So a fourth rule, and it is the one that has teeth: **a `VersionedSchema` owns frozen copies
of its models, never the live classes.** Only the newest version may point at the types the
app uses. Adding a v3 means copying today's models into `SchemaV2Models.swift` *first*, then
changing them. Frozen copies live in `SchemaV1Models.swift`, nested inside the version's
namespace so the SwiftData entity names still match.

A version bump with no shape behind it is not a migration, it is a rename.

**Tested by** `MigrationTests`, which writes a store from `SchemaV1`'s own models and opens it
through the real `ModelContainerFactory` — see ADR-025.

### ADR-008b · No unique constraints; CloudKit stays possible
**Status:** Accepted

`@Attribute(.unique)` on a client-generated UUID buys nothing — the UUID is already
unique — while making the store CloudKit-incompatible and quietly foreclosing multi-device
sync.

**Decided:** no unique constraints, child relationships optional, every attribute defaulted.
Costs nothing today; keeps iCloud a configuration change rather than a migration.

### ADR-009a · All model mutation happens on the main actor
**Status:** Accepted · `DraftStore` is `@MainActor`

`@Model` types are not `Sendable` and `ModelContext` is not thread-safe. A service holding
an `EntryDraft`, awaiting the network, then mutating it on resume is a data race that
reproduces only on slow connections.

**Decided:** one `DraftStore` on the main actor owns all writes. Service boundaries take and
return `Sendable` DTOs, never models; callers re-fetch by `UUID`. Swift 6 language mode is
on, so the unsafe shape fails to compile rather than failing in the field. Journal-sized
data does not need a background context — `@ModelActor` is available if that changes.

### ADR-010 · `EntryContent` is a value, not an entity
**Status:** Accepted · [`EntryContent`](../../Core/Sources/CodenamePromiseCore/Domain/EntryContent.swift)

As a `@Model` it was an implicit to-one relationship with no delete rule, so deleting a
draft orphaned its content row forever.

**Decided:** a `Codable` struct stored as a single attribute. Matches how the domain docs
always described it, removes a table, and simplifies the save story. Trade-off accepted:
no `#Predicate` into its fields — full-text search will filter in memory, which is fine at
journal scale.

### ADR-011 · Explicit ordering for to-many relationships
**Status:** Accepted · `MediaItem.sortIndex`, `EntryDraft.orderedMedia`

SwiftData to-many relationships are set-backed; array order is incidental and can differ
between launches. Photo order in a journal entry is user-visible.

**Decided:** explicit `sortIndex`, explicit inverses on every relationship, and reads go
through `orderedMedia` / `orderedAudioCaptures`. Never trust the raw array's order.

### ADR-012 · Enums are persisted as raw strings
**Status:** Accepted · [`Enums.swift`](../../Core/Sources/CodenamePromiseCore/Domain/Enums.swift)

Enum-typed SwiftData properties have been unreliable inside `#Predicate`, and the retry
queues (`pendingTranscriptions`, reconciliation) are exactly those predicates.

**Decided:** `public private(set) var xRaw: String` storage with a bridged enum accessor —
publicly readable so predicates work, privately writable so the enum is the only way to
mutate. Accessors fall back to a safe default rather than trapping: an unknown value from a
future schema must never make an entry unreadable.

### ADR-013 · Compression and upload are tracked separately
**Status:** Accepted · `MediaItem.compressionStatus` + `uploadStatus`

The original lifecycle mapped "compressing", "compressed" and "uploading" all onto
`UPLOADING`, so no retry pass could tell what work remained.

**Decided:** two independent status fields, each with its own terminal states.

### ADR-015a · A failed media upload never fails the entry
**Status:** Accepted · `SyncCoordinator.uploadPendingMedia`

"Upload failures causing the entire entry to fail" is on the founding list of problems in the
README, so the sync path treats media as best-effort: a photo that won't upload is marked
failed and the walk continues, and the entry syncs with whatever media did make it. Losing a
photo is annoying; losing the reflection because of a photo is the bug the project exists to
fix. Covered by `mediaFailureDoesNotFailTheEntry`.

### ADR-016 · Sync dirtiness is a content hash, never a timestamp
**Status:** Accepted · `EntryContent.contentHash`, `SyncState.syncedContentHash`

Invariant 2 bumps `updatedAt` on every mutation. If dirtiness were
`updatedAt > lastSyncedAt`, a sync recording its own completion would immediately re-dirty
itself — an infinite re-sync which, combined with a non-idempotent insert, duplicates the
entry on every pass.

**Decided:** compare SHA-256 content hashes, stored per destination. Invariant 2 is formally
amended: sync bookkeeping is not a content mutation. Regression-tested in
`syncBookkeepingDoesNotLoop`.

### ADR-017 · Formatting output is versioned; block conversion is server-side
**Status:** Accepted (client contract) / Planned (backend conversion) · `EntryContent.formatterVersion`

**Decided:** `formatterVersion` records which prompt produced `formattedText`, so output
stays reproducible when the prompt changes. Markdown→Notion-block conversion lives on the
backend so the client never learns Notion's block schema, and so chunking for Notion's
limits (2000 chars per rich-text object, 100 children per request) lives in one place. A
long entry hitting those limits is a real failure mode for exactly the thoughtful entries
this app is for.

### ADR-018a · Deleting a record deletes its bytes
**Status:** Accepted · `DraftStore.delete`, `removeMedia`

`deleteRule: .cascade` removes rows, not files. A draft with four videos reclaimed nothing.

**Decided:** `DraftStore` collects owned relative paths before deleting and hands them to
`MediaFileStore.delete`.

### ADR-019a · Offline degradation is specified per capability
**Status:** Accepted · [flows.md](flows.md#offline-behaviour)

"Local-first" branding with two network-only features and no stated behaviour leaves the
user unable to tell whether their words are safe — the precise anxiety the product exists to
remove.

**Decided:** capture and editing never touch the network. Transcription, formatting and sync
queue with visible "will do this when online" state. Not everything works offline; nothing
is ever lost offline, and the user can always tell which.

### ADR-022 · API key in Keychain; no server-side retention
**Status:** Accepted (client) / Planned (backend policy)

A key committed to source is irreversible without a history rewrite, and the most sensitive
text the user owns would otherwise sit in server logs by default.

**Decided:** key in Keychain, never in source or `Info.plist`; `Secrets.xcconfig` is
gitignored. Backend disables prompt and audio retention. The Notion token lives server-side.
Rate limiting server-side, since a shipped key is extractable.

### ADR-025 · Adversarial tests come before features
**Status:** Accepted · [`DurabilityTests.swift`](../../Core/Tests/CodenamePromiseCoreTests/DurabilityTests.swift)

"Never lose work" is the thesis and the hardest claim to verify by hand.

**Decided:** the core ships as a package with an in-memory container and protocol-shaped
services so the failures can be simulated headlessly: process death mid-dictation, a moved
container standing in for restore-from-backup, a lost response after a successful insert,
interrupted uploads and transcriptions. If this suite is green the promise is real.

**Amended:** an in-memory container is always empty and always at the current schema — a
*fresh install*, the one state a real user is never in. Every launch after the first opens a
store some older build wrote. The suite was therefore structurally unable to fail on a broken
migration, and didn't: 140 tests were green while the build on the phone couldn't open the
journal at all.

`MigrationTests` closes that hole. It writes a store from `SchemaV1`'s frozen models and opens
it through the real `ModelContainerFactory` and migration plan, asserting the entries, their
attachments, un-merged audio and destination page IDs all come through — plus one test that
simply refuses to let two schema versions describe the same shape (ADR-008a rule 4).

**When you add a schema version, add its fixture case here.** A migration is untested until
something has actually been through it, and this is the only suite that can be.

---

## Planned — decided, not yet built

### ADR-015 · Compress media on device
**Status:** Planned (before media ships)

Server-side compression means uploading an 800MB original to get 80MB back — backwards for
the bandwidth-constrained case that motivated it, and it ships private journal media to a
server with no other reason to see it.

**Decided:** `ImageIO` for photos, `AVAssetExportSession` for video, on device. Keep
`/compress/*` as a fallback for formats iOS handles poorly.

---

## Deferred — additive later, nothing at risk now

| ADR | Decision | Why deferring is safe |
|---|---|---|
| **009b** | Background `URLSession` for large uploads | Only bites when video ships; foreground-only uploads are fine for photos. Note it conflicts with the blanket async/await plan, so revisit deliberately. |
| **013b** | Per-destination media upload state | Only meaningful with a second destination live. Additive optional fields. |
| **014** | Durable outbox / automatic background retry | Partially landed: `TranscriptionCoordinator` is a real queue with persisted backoff (`nextTranscriptionAttemptAt`) that drains on launch, on becoming active, and after a recording. What's still deferred is *background* execution — it only runs while the app is in the foreground. Sync remains user-initiated with a visible Retry, which loses nothing given ADR-004. |
| **018b** | Orphan-file reaper on a schedule | `reapOrphans` is implemented; wiring it to launch is a one-liner whenever it matters. Slow harm. |
| **019b** | On-device STT fallback (`SFSpeechRecognizer`) | ADR-002 already prevents the data loss. This is a convenience upgrade. |
| **021** | `.gitignore` | Done, but noting it was over-weighted in review: `DerivedData` lives outside the project directory by default, so there was no history-bloat time bomb. |
| **022b** | Biometric lock | Deferrable. The *storage encryption* choice is not, and is settled under ADR-022. |
| **024** | Archive / retention / pruning UI | Additive, no migration. One caveat: "multiple drafts per day" was *not* deferrable and is settled in ADR-006. `TranscriptionCoordinator.releaseTranscribedAudio(olderThan:)` exists but is **deliberately never called automatically** — deleting original recordings is irreversible, and a user unhappy with a transcript may want to hear the audio again. That belongs in settings as an explicit choice, not in a silent launch task. |

---

## Notes on evolving this

**Editing `SchemaV1` is still permitted** — nothing has shipped, so there is no installed base
to migrate. `nextTranscriptionAttemptAt` was added to `AudioCapture` this way. The rule in
ADR-008a bites the moment a build reaches a device with real entries in it; from then on, new
version, new stage, no exceptions.

---

## Rejected — considered and declined

### ADR-012-alt · Raw strings everywhere as a blanket rule
**Rejected.** The review over-weighted enum-predicate fragility as though it forced a
schema decision. It does not: fetching and filtering in Swift is free at journal scale and
needs no migration. Raw storage was adopted (ADR-012) because it is cheap and the queues are
real, not because there was no escape hatch.

### ADR-014-alt · Build the outbox up front
**Rejected for v1.** A persisted job queue with backoff was presented as a must-have because
"sync whenever" is a headline promise. But user-initiated sync plus lease recovery
(ADR-004) plus a visible Retry button loses nothing. The queue is a convenience feature and
its fields are additive.

### ADR-023 · A `SyncDestination` protocol before a second destination exists
**Rejected.** The review recommended abstracting destinations before writing the Notion
implementation. That is speculative indirection for a project with exactly one destination
and no second one planned — and an abstraction designed against one implementation is
usually the wrong one.

**Instead:** a concrete `NotionAPI` protocol (for testability, not portability), and a
naming discipline — destination-neutral plumbing keeps neutral names (`SyncState`,
`SyncPhase`, `DraftStore`), so extraction stays possible when a real second destination
arrives and its shape is known. The unused `SyncTarget` cases cost nothing and stay.
