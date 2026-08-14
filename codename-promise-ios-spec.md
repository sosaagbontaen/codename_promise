# Codename Promise — iOS Native Spec (v4)

> Capture first. Organize later. Sync whenever.

A local-first journaling app for iOS. Everything revolves around one object: `EntryDraft`.
Every feature creates, enriches, formats, persists, or syncs it.

**v4 supersedes v3.** v3 rewrote the original React Native/Expo spec as native SwiftUI. v4
is the result of a pre-implementation architecture review of v3, which found nine issues that
would have been baked into schema or external state — including two that would have
reproduced the exact bug the project was founded to eliminate.

**The model definitions that used to live in this file have been removed rather than
updated.** They no longer matched the implementation, and a spec containing plausible-looking
wrong code is worse than one containing none. The authoritative definitions are:

- Code: [`Core/Sources/CodenamePromiseCore`](Core/Sources/CodenamePromiseCore)
- Model reference and invariants: [docs/architecture/domain-model.md](docs/architecture/domain-model.md)
- Flows and state machines: [docs/architecture/flows.md](docs/architecture/flows.md)
- Every decision and its rationale: [docs/architecture/decisions.md](docs/architecture/decisions.md)

---

## Why this exists

Six+ years of daily journaling with **WWWT** (What Went Well Today). The old workflow kept
losing work:

- Lost dictation after interruptions
- Lost work on app refresh
- AI rewriting personality instead of organizing it
- Manual Notion page creation, media size limits, upload failures killing whole entries

Goal: never lose work, never force sync, never let infra block reflection.

---

## Design principles (unchanged)

- **Local-first** — every action updates local storage immediately; nothing lives only in memory
- **Draft-first** — `EntryDraft` is the single source of truth; no scattered state
- **AI assists, never authors** — AI groups, structures, and improves readability; it never
  changes wording, tone, or rewrites the user's voice
- **Reliable by default** — every mutation persists immediately; failures never destroy work
- **Sync is optional** — Notion (or others) is a destination, not the datastore

---

## Tech stack

| Area | v3 (spec'd) | v4 (current) |
|---|---|---|
| Mobile | Swift, SwiftUI (iOS 17+) | unchanged |
| Local storage | SwiftData | SwiftData, **versioned schema from v1** (ADR-008a) |
| State management | `@Observable` / SwiftUI state | unchanged |
| Concurrency | "URLSession + async/await" | **Swift 6 mode; all model writes on the main actor; DTO-only service boundaries** (ADR-009a) |
| Dictation (STT) | Whisper via backend | unchanged, but **audio is persisted before upload** (ADR-002) |
| LLM (formatting) | GPT via backend | unchanged, **output versioned** (ADR-017) |
| Backend | Python, FastAPI | unchanged, **plus idempotency keys** (ADR-003) |
| Media processing | Backend Pillow/ffmpeg | **on-device, backend as fallback** (ADR-015) |
| Media storage | absolute paths | **copied into container, relative paths** (ADR-007) |
| Notion integration | Notion API v1 | unchanged; **block conversion + chunking server-side** (ADR-017) |
| Auth | Simple API key | key in **Keychain**, no server-side retention (ADR-022) |

**Why SwiftData over GRDB/raw SQLite:** iOS 17+ is already the target for `@Observable`, and
SwiftData maps cleanly onto the aggregate/value-object shape. Note the correction from v3:
SwiftData's autosave is **not** a per-mutation durability guarantee, so the "persist on every
change for free" reasoning in v3 was wrong. Saves are explicit (ADR-001). If hand-tuned
queries or multi-process access are ever needed, GRDB remains the fallback.

---

## Core domain

`EntryDraft` is the aggregate root, never replaced, only enriched. It owns `EntryContent`
(a value), `MediaItem[]`, `AudioCapture[]`, and `SyncState[]` (one per destination).

See [domain-model.md](docs/architecture/domain-model.md) for the class diagram, the field-by-field
rationale, and the nine invariants.

Two structural changes from v3 worth calling out here:

1. **`EntryContent` is a value type**, not a `@Model`. As an entity it had an implicit to-one
   relationship with no delete rule, orphaning content rows on draft deletion (ADR-010).
2. **`AudioCapture` is new.** v3 had nowhere to put dictation audio, so a dropped connection
   or a process death lost the recording entirely. Audio is now durable before transcription
   is attempted (ADR-002).

And one addition that changes external state: **`entryDate`**, the calendar day an entry is
*about*, distinct from `createdAt`. It identifies the destination page. One page per
`entryDate` (ADR-006).

---

## Compression strategy

| Level | Use case | Reduction |
|---|---|---|
| none | Keep original | 0% |
| low | High quality needed | 20–40% |
| medium | Standard journaling | 50–70% |
| high | Bandwidth constrained | 80–90% |

**Runs on device** (ADR-015). v3 put this server-side, which meant uploading an 800MB
original to receive 80MB back — the opposite of what the bandwidth-constrained case needs,
and it shipped private journal media to a server with no other reason to see it. The
`/compress/*` endpoints remain as a fallback for formats iOS handles poorly.

---

## Core workflow

1. Create draft → `id`, `createdAt`, `entryDate`
2. Capture → `content.rawText` (type or dictate)
3. Attach media → `media[]`
4. Format with AI → `content.formattedText`
5. Review
6. Push to Notion → `syncStates`

Not strictly linear — format before attaching media, reformat repeatedly, add media after
formatting. Sync can happen anytime, or never.

---

## Backend endpoints

```
POST /stt                    # audio -> transcript (Whisper)
POST /format                 # rawText -> formattedText (GPT)
POST /compress/image         # fallback only; compression is on-device
POST /compress/video         # fallback only
POST /notion/ensure-page     # keyed on entryDate; returns pageId
POST /notion/upload-file     # returns fileId
POST /notion/insert-content  # markdown -> blocks, chunked server-side
POST /notion/update-props    # title, date
```

**Every mutating call carries an `Idempotency-Key` header.** The backend caches results by
key and replays rather than re-writing. Without this, a successful `insert-content` whose
response was lost would be retried and insert the entry into Notion twice (ADR-003).

`insert-content` also receives `previouslyInsertedBlockIds` so an interrupted attempt can be
replaced rather than appended to (ADR-005), and owns markdown→block conversion plus chunking
for Notion's limits — 2000 chars per rich-text object, 100 children per request (ADR-017).

Client calls are side effects on an already-persisted `EntryDraft`, never a precondition for
saving locally.

---

## Project structure

```
Core/                              Swift package — builds and tests headlessly
  Sources/CodenamePromiseCore/
    Domain/                        CalendarDay, EntryContent, enums
    Models/                        EntryDraft, MediaItem, AudioCapture, SyncState
    Persistence/                   Schema (versioned), DraftStore, MediaFileStore
    Services/                      DTO-shaped protocols: TranscriptionService,
                                   FormattingService, NotionAPI, NetworkReachability
  Tests/                           Invariant + adversarial durability suites

CodenamePromise/                   App target — capture is wired up
  App/                             @main, ModelContainer setup, launch reconciliation
  Views/Capture/                   CaptureController (debounced saves), CaptureView,
                                   AudioRecorder — typing, dictation, media
  Views/Draft/                     DraftListView grouped by entryDate
  Views/Sync/                      sync status, retry — not built yet
  Services/                        URLSession implementations — not built yet
```

The domain lives in a package so the durability guarantees are testable without a simulator.

---

## What changed vs. v3

Nine issues were classified as must-fix-before-implementation because they were baked into
schema, external identity, or a durability guarantee:

| # | Issue | Resolution |
|---|---|---|
| ADR-001 | Autosave treated as a durability guarantee | Explicit saves + scene-phase flush |
| ADR-002 | Dictation audio had no durable home | `AudioCapture`, persisted before upload |
| ADR-003 | `insert-content` not idempotent | Idempotency keys, stable across retries |
| ADR-004 | `.syncing` could strand a draft forever | Leases + launch reconciliation |
| ADR-006 | No calendar day, undefined page identity | `CalendarDay`, one page per `entryDate` |
| ADR-007 | Transient and absolute media paths | Copy into container, relative paths |
| ADR-008a | No schema versioning baseline | `SchemaV1` + migration plan |
| ADR-008b | `.unique` foreclosed CloudKit for nothing | Constraint removed |
| ADR-009a | No concurrency contract | Main-actor writes, DTO service boundaries |

Deferred, rejected, and planned decisions are recorded in
[decisions.md](docs/architecture/decisions.md) — including three review findings that did not
survive scrutiny.
