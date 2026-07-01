# Codename Promise

> Capture first. Organize later. Sync whenever.

A local-first journaling application that acts as a **Draft Manager** for daily reflections.

Unlike traditional journaling apps, this project is not centered around Notion, AI, or even the editor itself.

It is centered around a single domain object:

> `EntryDraft`

Every feature either creates, enriches, formats, persists, or synchronizes an `EntryDraft`.

The result is a journaling workflow that is resilient to crashes, interruptions, offline usage, failed uploads, and incomplete work.

## Why this exists

I've journaled daily for over six years using a system called **WWWT (What Went Well Today).**

As my reflections became longer and more thoughtful, my existing workflow began to fail.

Problems included:

- Lost dictation after interruptions
- Lost work after refreshing the app
- Anxiety caused by unreliable capture
- AI rewriting my personality instead of organizing it
- Manual creation of Notion pages
- Notion media size limits
- Upload failures causing the entire entry to fail

The goal of this project is simple:

> Never lose work.
>
> Never force synchronization.
>
> Never let infrastructure get in the way of reflection.

## Design principles

### Local first

Every user action immediately updates a local `EntryDraft`.

Nothing exists only in memory.

SQLite is the source of truth while editing.

### Draft first

The `EntryDraft` is the heart of the application.

Everything else exists to manipulate or synchronize it.

There are no independent pieces of state scattered throughout the application.

### AI assists, never authors

GPT is responsible for:

- Grouping related ideas
- Creating intuitive bullet hierarchies
- Improving readability

GPT is **not** responsible for:

- Changing wording
- Changing tone
- Summarizing
- Rewriting personality

The user's voice always wins.

### Reliable by default

Every mutation to an `EntryDraft` is persisted immediately.

Failures never destroy work.

Synchronization can always happen later.

### Synchronization is optional

Notion is treated as a destination.

Not the primary datastore.

The `EntryDraft` exists independently of Notion.

## Technology stack

| Area | Technology |
|------|------------|
| Mobile | React Native, Expo |
| Local storage | SQLite |
| Backend | Python, FastAPI |
| AI | OpenAI Whisper, GPT |
| Media | Pillow, FFmpeg |
| Integrations | Notion API |

## Core workflow

1. Create draft
2. Capture thoughts
   - Typing
   - Dictation
   - Photos
   - Videos
3. Edit raw input
4. Format with AI
5. Review
6. Push to Notion

## Core domain

The entire application revolves around a single domain object:

> `EntryDraft`

Every feature either creates, enriches, formats, persists, or synchronizes an `EntryDraft`.

The editor, AI formatting, media management, local persistence, and synchronization all exist to support its lifecycle.

For more details, see:

- `docs/EntryDraft.md`