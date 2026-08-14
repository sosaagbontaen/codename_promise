# Flows

Every diagram here is a durability argument. The question each one answers is: *if the
process dies at the worst possible moment, what did the user lose?* The answer must always
be "nothing they said or wrote."

---

## The workflow, and why it isn't a pipeline

```mermaid
flowchart LR
    create["Create draft<br/><i>id · createdAt · entryDate</i>"]
    capture["Capture<br/><i>content.rawText</i>"]
    media["Attach media<br/><i>media[]</i>"]
    format["Format with AI<br/><i>content.formattedText</i>"]
    review["Review"]
    sync["Sync<br/><i>syncStates[]</i>"]

    create --> capture
    capture --> media
    capture --> format
    media --> format
    format --> review
    review --> sync
    review -->|"edit again"| capture
    sync -->|"edit after syncing"| capture
    capture -.->|"sync is optional, and may never happen"| sync

    style create fill:#2E7D32,color:#fff,stroke:#1B5E20
    style capture fill:#1565C0,color:#fff,stroke:#0D47A1
    style media fill:#E65100,color:#fff,stroke:#BF360C
    style format fill:#6A1B9A,color:#fff,stroke:#4A148C
    style review fill:#37474F,color:#fff,stroke:#263238
    style sync fill:#C62828,color:#fff,stroke:#8E0000
```

Formatting can precede media, can run repeatedly, and sync can happen at any point or
never. A draft that is never synced is a complete, valid, finished entry.

---

## Dictation — the path the project exists for

The original workflow lost dictation when something interrupted it. Audio is written to disk
and committed *before* any network call, so transcription may fail forever without costing
the user their words.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant UI as Capture view
    participant Store as DraftStore<br/>(@MainActor)
    participant Files as MediaFileStore
    participant STT as TranscriptionService

    User->>UI: speaks
    UI->>Files: write(chunk, .atomic)
    Files-->>UI: relativePath
    UI->>Store: attachAudioCapture(...)
    Store->>Store: insert + flush()
    Note over Store: Words are now safe.<br/>Everything after this is convenience.

    UI->>STT: transcribe(audioURL, captureId)

    alt transcription succeeds
        STT-->>UI: text
        UI->>Store: mergeTranscript(text, from: capture)
        Store->>Store: appendRawText + mergedIntoDraftAt<br/>in one commit
        Note over Store: Only now is the audio releasable.
    else offline, 500, or timeout
        STT-->>UI: error
        UI->>Store: markTranscriptionFailed
        Note over UI: Audio is on disk.<br/>Returns via pendingTranscriptions().
    else process is killed mid-flight
        Note over Store: Nothing is written.<br/>Launch reconciliation re-queues it as .pending.
    end
```

Long dictations record in chunks (`AudioCapture.chunkIndex`) so a failure costs one chunk
rather than the whole session, and chunks append in order.

---

## Durability boundaries

```mermaid
flowchart TB
    keystroke["User types a character"] --> buffer["@State buffer in the view"]
    buffer -->|"~300ms debounce"| model["draft.updateRawText()"]
    buffer -->|"scenePhase → .inactive / .background"| model
    model --> save["context.save()"]
    save --> disk[("SwiftData store")]

    subgraph why["Why not autosave alone"]
        note["Autosave fires at opportune moments,<br/>chiefly around scene-phase changes.<br/>An 8-minute foreground dictation<br/>never reaches one — a jetsam takes<br/>everything since the last save.<br/>ADR-001"]
    end

    style note fill:#4E342E,color:#fff,stroke:#3E2723
    style disk fill:#1565C0,color:#fff,stroke:#0D47A1
    style save fill:#2E7D32,color:#fff,stroke:#1B5E20
```

The debounce keeps rapid typing from thrashing the store; the scene-phase flush closes the
window the debounce opens. Every mutating method on `DraftStore` commits before returning.

---

## Sync — resumable and idempotent

```mermaid
sequenceDiagram
    autonumber
    participant Store as DraftStore
    participant State as SyncState
    participant API as NotionAPI

    Store->>State: beginAttempt(contentHash)
    Note over State: Same content → reuse attemptId & phase.<br/>Changed content → fresh key, phases reset.

    opt phase < pageEnsured
        Store->>API: ensurePage(entryDate, key: attemptId:page)
        API-->>Store: pageId
        Store->>State: externalId = pageId; advance(.pageEnsured)
    end

    opt phase < filesUploaded
        loop each media item without a recorded fileId
            Store->>API: uploadFile(key: attemptId:file:<mediaId>)
            API-->>Store: fileId
            Store->>State: recordUploadedFile(mediaId, fileId)
        end
        Store->>State: advance(.filesUploaded)
    end

    opt phase < contentInserted
        Store->>API: insertContent(formattedText, previouslyInsertedBlockIds,<br/>key: attemptId:content)
        Note over API: Replays on a repeated key<br/>rather than inserting twice. ADR-003
        API-->>Store: blockIds
        Store->>State: insertedBlockIds = blockIds; advance(.contentInserted)
    end

    opt phase < propertiesUpdated
        Store->>API: updateProperties(title, entryDate)
        Store->>State: markSynced(externalId, contentHash)
    end

    Note over State: markSynced does NOT bump draft.updatedAt.<br/>Otherwise the draft re-dirties itself forever. ADR-016
```

Each step is skipped when `phase` already covers it, so a retry resumes. Each mutating call
carries a key derived from `attemptId`, so a step whose response was lost replays instead of
writing twice.

Implemented in [`SyncCoordinator`](../../Core/Sources/CodenamePromiseCore/Coordination/SyncCoordinator.swift).
Two behaviours worth knowing that the diagram doesn't show:

- **Media is best-effort.** A photo that fails to upload is marked and skipped; the entry syncs
  regardless. See ADR-015a.
- **The payload is snapshotted before the first `await`.** If the user keeps typing mid-sync,
  the attempt still sends the content its idempotency key was minted for, and the result is
  reported as `syncedButSupersededByEdits` so the draft correctly shows as dirty again.

---

## Sync state machine

```mermaid
stateDiagram-v2
    [*] --> pending

    pending --> syncing : beginAttempt()
    syncing --> synced : all phases complete
    syncing --> failed : any step errors
    failed --> syncing : retry — resumes at recorded phase
    synced --> pending : contentHash ≠ syncedContentHash

    syncing --> failed : launch reconciliation<br/>(startedAt older than timeout)

    note right of syncing
        A lease, not a flag.
        Without startedAt, a process
        death strands the draft here
        forever — and ".syncing"
        means "do not retry".
        ADR-004
    end note

    note right of synced
        Dirtiness is a content hash
        comparison, never a timestamp
        comparison. ADR-016
    end note
```

---

## Launch reconciliation

Runs once at startup, before any UI reads state.

```mermaid
flowchart TB
    launch["App launch"] --> reconcile["DraftStore.reconcileAbandonedOperations()"]

    reconcile --> s1{"SyncState .syncing<br/>older than timeout?"}
    s1 -->|yes| s2["→ .failed, keep phase + externalId<br/>so the retry resumes"]

    reconcile --> u1{"MediaItem .uploading<br/>older than timeout?"}
    u1 -->|yes| u2["→ .failed, keep attemptCount<br/>so backoff can work"]

    reconcile --> t1{"AudioCapture .transcribing<br/>older than timeout?"}
    t1 -->|yes| t2["→ .pending<br/>(work not yet done, not a failure —<br/>the audio is still on disk)"]

    s2 --> flush["flush()"]
    u2 --> flush
    t2 --> flush
    flush --> ui["UI reads a consistent, retryable world"]

    style s2 fill:#C62828,color:#fff,stroke:#8E0000
    style u2 fill:#E65100,color:#fff,stroke:#BF360C
    style t2 fill:#2E7D32,color:#fff,stroke:#1B5E20
```

An interrupted transcription returns as `.pending` rather than `.failed` — presenting
undone work as a failure would be a lie, and the audio never left the disk.

---

## Media lifecycle

```mermaid
stateDiagram-v2
    direction LR

    state "Compression" as C {
        [*] --> pending
        pending --> compressing
        compressing --> compressed
        compressing --> failed
        pending --> skipped : small enough / already efficient
    }

    state "Upload" as U {
        [*] --> uploadPending
        uploadPending --> uploading : markUploading (sets lease)
        uploading --> uploaded
        uploading --> uploadFailed
        uploadFailed --> uploading : retry
        uploading --> uploadFailed : launch reconciliation
    }

    C --> U : bytes ready (compressed if we made one)
```

Compression and upload are tracked separately because a single combined status could not
distinguish "needs compressing" from "needs uploading" (ADR-013). Compression is planned to
run **on device** — uploading an 800MB original in order to get 80MB back is the wrong shape
for the bandwidth-constrained case that motivated it (ADR-015).

---

## Offline behaviour

Capture and editing never touch the network. Everything that does degrades visibly.

| Capability | Offline | User sees |
|---|---|---|
| Create / type / edit / attach media | Works | Nothing unusual |
| Dictation recording | Works | Nothing unusual |
| Dictation transcription | Queued | "Recorded — will transcribe when online", audio safe |
| AI formatting | Queued | "Will format when online", raw text untouched |
| Sync | Queued | Destination badge shows pending, entry unaffected |

The point is not that everything works offline — it can't. The point is that nothing is ever
*lost* offline, and the user can always tell the difference (ADR-019a).
