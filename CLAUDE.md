# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Core logic — fast, headless, no simulator needed. Run this constantly:

```bash
cd Core && swift test
```

A single suite or test by name:

```bash
cd Core && swift test --filter "Sync idempotency"
```

The iOS app:

```bash
xcodebuild -scheme CodenamePromise -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The app target uses an Xcode 16+ **file-system synchronized group**, so files added under
`CodenamePromise/` are picked up automatically — there is no per-file bookkeeping in
`project.pbxproj`. Adding a source file needs no project edit.

`Core` is wired in as a local Swift package dependency, so app builds compile it from source.

Swift 6 language mode is on. Concurrency errors are load-bearing here, not noise — see the
main-actor rule below before working around one.

## What this project is

A local-first iOS journaling app ("Draft Manager") built around one aggregate root:
`EntryDraft`. Every feature exists only to create, enrich, format, persist, or synchronize
one. The product thesis is **never lose work**, and most of the non-obvious code exists to
make that literally true rather than aspirational.

Design tenets, in priority order when they conflict:

1. **Never lose what the user said or wrote.** Beats correctness elsewhere, beats convenience,
   beats performance.
2. **Local-first** — every action commits to the local store immediately. The backend is
   never consulted to decide whether a local write may proceed.
3. **AI assists, never authors** — formatting groups and structures `rawText` into
   `formattedText`. It must never change wording or tone. There is deliberately no code path
   from formatting to `rawText`; do not add one.
4. **Sync is optional** — an entry that is never synced is complete and valid.

## Architecture

```
Core/Sources/CodenamePromiseCore/
  Domain/       CalendarDay, EntryContent (value type), enums
  Models/       EntryDraft (aggregate root), MediaItem, AudioCapture, SyncState — @Model
  Persistence/  Schema (versioned), DraftStore (@MainActor), MediaFileStore
  Services/     DTO-shaped protocol definitions
  Networking/   APIClient, HTTP implementations of those protocols, reachability
  Coordination/ TranscriptionCoordinator (retry queue), FormattingCoordinator,
                SyncCoordinator (resumable, idempotent push)
  Security/     APIKeyStore (Keychain)

CodenamePromise/
  App/          @main, AppServices (container + launch reconciliation), scene-phase flush
  Views/Capture/  CaptureController (the debounce), CaptureView, AudioRecorder
  Views/Draft/    DraftListView grouped by entryDate
  Views/Settings/ NotionSettingsView (connect + database picker), WebAuthenticator
```

The three coordinators share one shape: snapshot `Sendable` values on the main actor, await the
service, re-fetch by `UUID`, and discard the result if the content moved on while it ran.

`CaptureController` is where the save discipline lives in the UI: `TextEditor` binds to a
buffer, changes commit on a ~300ms debounce, and anything that could end the session
(`onDisappear`, scene-phase change, starting a recording) commits immediately instead of
waiting. Do not bind an editor straight to `draft.content.rawText`.

`EntryDraft` owns `EntryContent` inline (a `Codable` value, not an entity) plus cascading
relationships to `MediaItem`, `AudioCapture`, and `SyncState` — one `SyncState` per
destination.

Full reference: [docs/architecture/domain-model.md](docs/architecture/domain-model.md),
[flows.md](docs/architecture/flows.md), and
[decisions.md](docs/architecture/decisions.md). **Source comments cite `ADR-NNN` throughout;
those numbers resolve in decisions.md.** Read the relevant ADR before changing anything it
covers — several fields look redundant and are not.

## Rules that are easy to break by accident

**Saves are explicit.** SwiftData autosave is *not* a per-mutation durability guarantee — it
commits at opportune moments, mainly around scene-phase changes, which never arrive during a
long foreground dictation. Every mutating method on `DraftStore` calls `flush()` before
returning. Keep it that way. (ADR-001)

**All model mutation happens on the main actor.** `@Model` types aren't `Sendable` and
`ModelContext` isn't thread-safe. Service boundaries take and return `Sendable` DTOs and
never a model; callers re-fetch by `UUID`. If the compiler complains that a model can't cross
an actor boundary, the design is wrong, not the compiler. (ADR-009a)

**Never bump `updatedAt` for sync bookkeeping.** Dirtiness is a content-hash comparison, not
a timestamp comparison. Bumping `updatedAt` in `markSynced` re-dirties the draft immediately
and loops forever. There's a regression test named `syncBookkeepingDoesNotLoop`. (ADR-016)

**Never store an absolute path in a model.** Media and audio are copied into the app
container by `MediaFileStore` and referenced relatively, because container UUIDs change on
restore-from-backup. Adopt bytes *before* creating the row. (ADR-007)

**Deleting a record doesn't delete its bytes.** Cascade rules clear rows only. Collect
`ownedRelativePaths` and hand them to `MediaFileStore.delete`. (ADR-018a)

**Dictation audio is durable before transcription is attempted**, and released only once
`mergedIntoDraftAt` is set. This is the founding bug of the project; do not make
transcription a precondition for anything. (ADR-002)

**Enums persist as raw strings** with bridged accessors, so `#Predicate` works. Add new enums
the same way, and keep the safe-default fallback — an unknown value must never make an entry
unreadable. (ADR-012)

**Read through `orderedMedia` / `orderedAudioCaptures`.** SwiftData to-many relationships are
set-backed; raw array order is incidental. (ADR-011)

**Every mutating destination call carries an idempotency key** derived from
`SyncState.attemptId`, which is stable across retries of the same content. A retry after a
lost response must replay, not re-write. (ADR-003)

**Schema changes:** never edit a shipped `VersionedSchema`. Add a new one, give every new
attribute a default, and add a migration stage even if lightweight. No unique constraints —
they'd foreclose CloudKit for no benefit. (ADR-008a, ADR-008b)

## Networking

`APIClient` maps every failure onto `APIError`, whose `isRetryable` is what stops the queue
hammering a request that can never succeed — 4xx is permanent, 5xx/429/408/offline is not.
Mutating calls take an `IdempotencyKey`. Failure messages are user-facing and none of them may
ever imply work was lost, because it never is; there's a test asserting that.

An **absent `BackendBaseURL` is a supported state**, not an error — the app then behaves exactly
as it does offline. To point at a backend, set the `BACKEND_BASE_URL` build setting; it is
substituted into `Config/Info.plist`, which is the target's `INFOPLIST_FILE`.

Do **not** try to shortcut that with `INFOPLIST_KEY_BackendBaseURL`. That mechanism only handles
Apple's known key names and silently discards custom ones — the build succeeds, the key is
absent, and the app can never reach its backend. `GENERATE_INFOPLIST_FILE` stays `YES`, so
Apple's generated keys still merge on top of `Config/Info.plist`.

The API key comes from the Keychain via `APIKeyStore` and must never be added to source or
`Info.plist`.

`TranscriptionCoordinator.drain()` is the queue: it leases an item (committing the lease first
so a crash is recoverable), calls the service, and merges on success. It runs on launch, on
becoming active, and after a recording. It stops early on `.offline` / `.notConfigured` /
`.unauthorized` rather than marking every queued item failed in turn.

## Testing

`Core/Tests` has two suites: invariant tests, and adversarial durability tests that simulate
process death mid-dictation, a relocated container (restore-from-backup), interrupted syncs,
uploads, and transcriptions. These are the proof of the product's central claim — when adding
a feature that touches persistence or sync, add the failure-mode test, not just the happy path.

Note when writing tests: each `DraftStore` owns its own `ModelContext`, so an object fetched
from one store does not observe another store's writes. Re-fetch through the store under test.

## Backend

Python/FastAPI, in [backend/](backend/) — this is a monorepo, so the wire contract lives in one
place and versions together.

```bash
cd backend && .venv/bin/python -m pytest -q
```

```bash
cd backend && .venv/bin/python -m uvicorn app.main:app --reload --port 8000
```

It runs fully on deterministic stubs with no credentials (`EchoTranscriber`,
`PassthroughFormatter`, `InMemoryNotion` behind Protocols in `app/services.py`), which is what
makes the client developable without keys. `GET /health` reports which providers are live.

Real providers activate from configuration: **Groq** (`GROQ_API_KEY`) for transcription and
formatting — it is OpenAI-compatible, so the base URL is the only thing tying it to Groq — and
**Notion via OAuth** once a user signs in and picks a database.

`app/wordguard.py` is the enforcement of "AI assists, never authors": formatted output that
introduces or drops words is rejected with a 422 rather than applied. The prompt in
`app/providers/groq.py` asks for that behaviour; the guard is what guarantees it. Do not
weaken it to make a model pass.

The connect flow: `ConnectionCoordinator` (in Core, so the state machine is testable without
a browser) produces the URL; `WebAuthenticator` opens it in an `ASWebAuthenticationSession`.
Cancelling is not an error, and the outcome is always confirmed by re-reading server state
rather than by trusting what the browser handed back.

Notion tokens live **server-side only** (`app/connections.py`, `.state/notion.json`, `0600`)
and are never returned to the device — the app sees a boolean, a workspace name, and the
chosen database.

**The idempotency store is in-memory**, so it forgets keys on restart and must be swapped for
Redis/Postgres before running more than one worker. Endpoints are also listed in
[codename-promise-ios-spec.md](codename-promise-ios-spec.md). Two contracts matter from the
client side: mutating calls accept an `Idempotency-Key` and replay on repeat, and
markdown→Notion-block conversion plus chunking for Notion's limits (2000 chars per rich-text
object, 100 children per request) happens server-side.
