# Backend

Python/FastAPI service for [Codename Promise](../README.md). It exists to do three things the
phone shouldn't: transcribe audio, run the formatting prompt, and talk to Notion.

It is a **destination, never the datastore**. The client persists locally before calling any
of this, so every endpoint here can fail without costing the user a word.

## Running

```bash
cd backend && .venv/bin/python -m uvicorn app.main:app --reload --port 8000
```

```bash
cd backend && .venv/bin/python -m pytest -q
```

Point the iOS app at it by setting the `BACKEND_BASE_URL` build setting to
`http://localhost:8000` (see the root [CLAUDE.md](../CLAUDE.md)).

## Configuration

All optional. With none of it set the service runs fully on deterministic stubs, which is what
lets the iOS client be developed without any accounts. `GET /health` reports which providers
are live, so you can always tell what you're talking to.

Copy [`.env.example`](.env.example) to `.env` and fill it in. `.env` is gitignored.

| Variable | Effect |
|---|---|
| `CP_API_KEY` | Requires `Authorization: Bearer <key>`. **Unset means the API is open.** |
| `GROQ_API_KEY` | Enables real transcription and formatting |
| `NOTION_CLIENT_ID` / `_SECRET` / `_REDIRECT_URI` | Enables Notion sign-in |
| `CP_TRANSCRIPTION_MODEL` | Default `whisper-large-v3-turbo` |
| `CP_FORMATTING_MODEL` | Default `llama-3.3-70b-versatile` |
| `CP_FORMATTER_VERSION` | Reported back so output stays reproducible (ADR-017) |
| `CP_RETAIN_PAYLOADS` | Off by default; journal text is not retained (ADR-022) |
| `CP_DISABLE_WORDING_GUARD` | Debugging only — see below |

### Groq

Groq is OpenAI-compatible, so `GROQ_BASE_URL` is the only thing separating it from OpenAI or
anything else speaking the same protocol. Get a key at <https://console.groq.com/keys> and put
it in `.env` — it is read from the environment, never logged, and never returned in a response.

### Notion sign-in

Create a **public** integration at <https://www.notion.so/my-integrations>, set its redirect
URI to `http://localhost:8000/notion/oauth/callback`, and copy the client ID and secret into
`.env`. Then:

| Endpoint | Purpose |
|---|---|
| `GET /notion/oauth/start` | Redirects to Notion's own sign-in and page-picker |
| `GET /notion/oauth/callback` | Exchanges the code, stores the token, returns to the app |
| `GET /notion/connection` | Status: connected? ready? which database? **never the token** |
| `GET /notion/databases` | The databases the user shared, for the in-app picker |
| `POST /notion/database` | Choose one; resolves its title and date columns |
| `DELETE /notion/connection` | Forget the token. Local entries are untouched. |

The user signs in **to Notion**, not to this app, and Notion's own screen is where they choose
what to share. There is no password field here and no key for them to copy. The access token
is stored server-side and never sent to the device.

Database property names are discovered from the schema rather than assumed — every workspace
names its columns differently. A database with no date column is rejected at pick time, where
the user can choose another, rather than failing mid-sync.

### The wording guard

[`app/wordguard.py`](app/wordguard.py) verifies that formatted output only *restructures* the
user's text. A chat model told to reorganise prose will sometimes paraphrase while believing
it is helping; the prompt is a request, and this is the enforcement.

Output that introduces words the author never wrote — or drops words they did — is rejected
with a 422, and the client leaves the entry unformatted. Better no formatting than altered
words. `CP_DISABLE_WORDING_GUARD=1` exists for debugging a model's behaviour and should never
be set in anything a person actually journals into.

## The two things that actually matter here

**Idempotency** ([`app/idempotency.py`](app/idempotency.py)). Every mutating call accepts an
`Idempotency-Key` and replays the stored result rather than executing again. Without it, a
successful `insert-content` whose response was lost becomes a second copy of the user's entry
in Notion. See ADR-003.

Key reuse with a *different* body is rejected with a 422 rather than silently replayed — that
combination means the client's attempt bookkeeping is broken, and hiding it would be worse
than failing.

**Chunking** ([`app/blocks.py`](app/blocks.py)). Notion allows 2000 characters per rich-text
object and 100 children per request. A long reflective entry exceeds both, and the API's
response is an unhelpful 400. Conversion and chunking live here so the client never learns
Notion's block schema. See ADR-017.

## Known limitations

- **The idempotency store is in-memory.** A restart forgets every key, so a retry spanning a
  deploy can double-write. Swap it for Redis or Postgres before running more than one worker
  process — `IdempotencyStore` is a narrow interface precisely so that swap touches no
  handlers.
- **The Groq and Notion providers are written but unexercised.** No request has been made
  against either real service from here, so their happy paths are unverified — the tests cover
  the logic around them (idempotency, chunking, the wording guard, OAuth state), not the
  providers' wire behaviour. Stubs remain the default when credentials are absent.
- **Media upload to Notion is not implemented.** `NotionGatewayHTTP.upload_file` raises, and
  the client treats that as a per-item failure rather than an entry failure (ADR-015a), so
  text still syncs and photos are marked failed.
- **The connection file is unencrypted.** `.state/notion.json` holds a live Notion token at
  `0600`. Fine for one person on their own machine; multi-user needs per-user rows and an
  encrypted column.
- `PassthroughFormatter` regroups lines without changing a single word. That is not a
  placeholder behaviour to be relaxed later: a formatter that alters wording has broken the
  product's central promise. See ADR-017 and the tenet in the root README.
