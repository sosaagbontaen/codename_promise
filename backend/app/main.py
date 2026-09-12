"""FastAPI application.

Endpoint contracts are consumed by ``Core/Sources/CodenamePromiseCore/Networking``. Every
mutating route runs through :mod:`app.idempotency`, because the client treats a lost response
as retryable and will replay it.

Providers are chosen from configuration at startup: real ones when credentials are present,
deterministic stubs otherwise. That is not a testing convenience so much as the reason the
client can be built and demoed with no accounts at all.
"""

from __future__ import annotations

from typing import Any, Optional

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile, status

from .config import Settings
from .connections import ConnectionStore
from .idempotency import IdempotencyStore
from .oauth import NotionOAuth
from .organiser import ORGANISER_VERSION, organise
from .providers.groq import (
    DEFAULT_FORMATTING_MODEL,
    DEFAULT_TRANSCRIPTION_MODEL,
    GroqError,
    GroqFormatter,
    GroqOrganiser,
    GroqRateLimited,
    GroqTranscriber,
    list_models,
)
from .providers.notion_api import (
    NotionError,
    NotionGatewayHTTP,
    NotionUploadTooLarge,
    NotionUploadUnsupported,
)
from .routes_notion_auth import build_router
from .schemas import (
    EmptyResponse,
    EnsurePageRequest,
    EnsurePageResponse,
    FormatRequest,
    FormatResponse,
    OrganiseRequest,
    OrganiseResponse,
    OrganisedSection,
    InsertContentRequest,
    InsertContentResponse,
    TranscriptionResponse,
    UpdatePropertiesRequest,
    UploadFileResponse,
    VocabularyTerm,
)
from .services import (
    EchoTranscriber,
    InMemoryNotion,
    ParagraphOrganiser,
    PassthroughFormatter,
    insert_entry,
)
from .vocabulary import VocabularyStore
from .wordguard import FormattingAlteredWordsError


def create_app(
    settings: Optional[Settings] = None,
    transcriber: Any = None,
    formatter: Any = None,
    organiser: Any = None,
    notion: Any = None,
    connections: Optional[ConnectionStore] = None,
    vocabulary: Optional[VocabularyStore] = None,
    #: Injectable so the health check is testable without reaching Groq.
    model_lister: Any = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    model_lister = model_lister or list_models
    connections = connections if connections is not None else ConnectionStore()
    vocabulary = vocabulary if vocabulary is not None else VocabularyStore()

    # Explicit overrides win (tests); otherwise credentials decide.
    if transcriber is None:
        transcriber = (
            GroqTranscriber(
                api_key=settings.groq_api_key,
                model=settings.transcription_model,
                base_url=settings.groq_base_url,
            )
            if settings.has_groq
            else EchoTranscriber()
        )
    if formatter is None:
        formatter = (
            GroqFormatter(
                api_key=settings.groq_api_key,
                model=settings.formatting_model,
                base_url=settings.groq_base_url,
                enforce_wording=settings.enforce_wording,
            )
            if settings.has_groq
            else PassthroughFormatter()
        )

    if organiser is None:
        organiser = (
            GroqOrganiser(
                api_key=settings.groq_api_key,
                model=settings.formatting_model,
                base_url=settings.groq_base_url,
            )
            if settings.has_groq
            else ParagraphOrganiser()
        )

    fallback_notion = notion or InMemoryNotion()
    idempotency = IdempotencyStore()
    oauth = NotionOAuth(
        client_id=settings.notion_client_id,
        client_secret=settings.notion_client_secret,
        redirect_uri=settings.notion_redirect_uri,
    )

    def resolve_notion() -> Any:
        """The real gateway once a database is chosen, the in-memory one before that.

        Resolved per request rather than at startup because the connection can be created or
        changed while the server is running — connecting Notion should not require a restart.
        """
        if notion is not None:
            return notion
        connection = connections.get()
        if connection and connection.is_ready:
            return NotionGatewayHTTP(
                access_token=connection.access_token,
                database_id=connection.database_id,
                title_property=connection.title_property,
                date_property=connection.date_property,
                max_upload_bytes=int(settings.notion_max_upload_mb * 1024 * 1024),
            )
        return fallback_notion

    app = FastAPI(title="Codename Promise", version="0.1.0")
    app.state.settings = settings
    app.state.idempotency = idempotency
    app.state.connections = connections
    app.state.vocabulary = vocabulary
    app.state.notion = fallback_notion

    def require_auth(authorization: Optional[str] = Header(default=None)) -> None:
        """Bearer-token check.

        When no key is configured the API is open — appropriate for local development and
        explicitly *not* for anything reachable. The key is a shared secret shipped in a
        client binary, so it is extractable by design; it limits casual abuse, not a
        determined attacker. Rate limiting belongs in front of this. See ADR-022.
        """
        if not settings.requires_auth:
            return
        if authorization != f"Bearer {settings.api_key}":
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid or missing API key.",
            )

    app.include_router(
        build_router(oauth=oauth, store=connections, app_return_url=settings.app_return_url)
    )

    # --- Vocabulary ---------------------------------------------------------------

    @app.get("/vocabulary")
    async def list_vocabulary() -> dict:
        return {"terms": vocabulary.all()}

    @app.post("/vocabulary")
    async def add_vocabulary(request: VocabularyTerm) -> dict:
        return {"terms": vocabulary.add(request.term)}

    @app.delete("/vocabulary/{term}")
    async def remove_vocabulary(term: str) -> dict:
        return {"terms": vocabulary.remove(term)}

    @app.get("/")
    async def root() -> dict:
        """Something to see when you open the address in a browser.

        Without this, opening the server in Safari answers `{"detail":"Not Found"}`, which is
        FastAPI correctly saying there is no route here and reads exactly like a broken
        deployment. The address bar is the first thing anybody tries when wondering whether
        their server is up, so it should answer that question.

        Deliberately says nothing about configuration. `/health` is the endpoint for that and
        it is unauthenticated, but there is no reason for a passer-by to get a summary of
        what this server is wired to.
        """
        return {"service": "dumpnotes", "status": "ok", "health": "/health"}

    @app.get("/auth/check")
    async def auth_check(_: None = Depends(require_auth)) -> dict:
        """Is this key accepted? Nothing else.

        Exists because every other authenticated endpoint does real work — transcribes
        audio, calls a model, writes to Notion — so a client had no way to find out whether
        its key was right short of trying to use it and watching a recording fail. In the
        app that read as "it is broken" with no way to tell a wrong address from a wrong key.

        Cheap on purpose: no providers, no state, no side effects. When no key is configured
        this returns ok to anybody, which is the truth — there is nothing to be wrong about.
        """
        return {"ok": True}

    @app.get("/health")
    async def health(verify: bool = False) -> dict:
        """What this server is wired to, and optionally whether that still exists.

        `verify=true` asks the provider which models the account can actually call and
        compares them against the ones configured here. It is opt-in because it costs a
        network round trip, and it exists because the alternative already happened:
        `llama-3.3-70b-versatile` was retired by Groq, every formatting request began
        returning 404, and nothing anywhere said so until somebody tried to format an entry.
        A deploy check that calls this with `verify=true` would have caught it the same day.
        """
        connection = connections.get()
        body = {
            "status": "ok",
            "auth_required": settings.requires_auth,
            "formatter_version": settings.formatter_version,
            # So it is obvious at a glance whether you're talking to real providers or stubs.
            "transcription": "groq" if settings.has_groq else "stub",
            "formatting": "groq" if settings.has_groq else "stub",
            "notion": "connected" if (connection and connection.is_ready) else "stub",
            "notion_oauth_configured": oauth.is_configured,
            # Always visible, no network needed: you can see what is configured without
            # having to read the source to find out.
            # From settings, not from the provider constants. Reporting the constant while
            # the app calls something else is how a tripwire ends up pointing at the wrong
            # wire, which is exactly what happened here: the constant was fixed, config still
            # named the retired model, and /health would have said "available" either way.
            "models": {
                "transcription": settings.transcription_model,
                "formatting": settings.formatting_model,
            },
        }

        if verify:
            if not settings.has_groq:
                body["models_verified"] = "skipped: no provider configured"
                return body
            try:
                available = await model_lister(settings.groq_api_key)
            except GroqError as exc:
                body["status"] = "degraded"
                body["models_verified"] = f"could not check: {exc}"
                return body
            checked = {
                name: ("available" if model in available else "MISSING")
                for name, model in body["models"].items()
            }
            body["models_verified"] = checked
            if any(v == "MISSING" for v in checked.values()):
                body["status"] = "degraded"
        return body

    # --- Transcription ------------------------------------------------------------

    @app.post("/stt", response_model=TranscriptionResponse)
    async def stt(
        audio: UploadFile = File(...),
        idempotency_key: Optional[str] = Header(default=None, alias="Idempotency-Key"),
        _: None = Depends(require_auth),
    ) -> TranscriptionResponse:
        data = await audio.read()
        if not data:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="The audio file was empty."
            )

        async def run() -> TranscriptionResponse:
            try:
                text = await transcriber.transcribe(data, audio.filename or "audio.m4a")
            except GroqError as exc:
                # 502: transient by the client's classification, so the recording stays
                # queued and is retried. The audio is safe on the device regardless.
                raise HTTPException(status_code=502, detail=str(exc))
            return TranscriptionResponse(text=text)

        return await idempotency.run(idempotency_key, {"bytes": len(data)}, run)

    # --- Formatting ---------------------------------------------------------------

    @app.post("/organise", response_model=OrganiseResponse)
    async def organise_entry(
        request: OrganiseRequest,
        idempotency_key: Optional[str] = Header(default=None, alias="Idempotency-Key"),
        _: None = Depends(require_auth),
    ) -> OrganiseResponse:
        """A rambling transcript in, a journal entry out, with its sources attached.

        Distinct from `/format`, which is a copy-editor bound by `wordguard` to preserve every
        word. This one is allowed to drop filler and move a thought from minute eight next to
        one from minute one, because that is the product. What it is not allowed to do is lose
        anything quietly, which `dropguard` enforces: every line is accounted for, and what
        was discarded is checked to be filler in fact rather than filler by assertion.

        `sources` on each section is the trust mechanism, not a debugging aid. It is what lets
        the app show a line of the finished entry beside the words it came from.
        """
        async def run() -> OrganiseResponse:
            try:
                result = await organise(request.transcript, organiser, organiser)
            except GroqRateLimited as exc:
                # 429 rather than 502: the client already knows to back off and retry a 429,
                # and telling it the server failed would be both wrong and counterproductive.
                headers = {"Retry-After": exc.retry_after} if exc.retry_after else None
                raise HTTPException(status_code=429, detail=str(exc), headers=headers)
            except GroqError as exc:
                raise HTTPException(status_code=502, detail=str(exc))

            return OrganiseResponse(
                sections=[
                    OrganisedSection(
                        heading=s["heading"], body=s["body"], sources=s["sources"]
                    )
                    for s in result.sections
                ],
                sentences=result.sentences,
                dropped=result.dropped,
                organiser_version=result.version,
                repaired=len(result.repaired.wrongly_dropped) + len(result.repaired.unaccounted),
            )

        # The payload is part of the key's identity: the same key with a different
        # transcript is a different operation, not a replay.
        return await idempotency.run(idempotency_key, request.model_dump(), run)

    @app.post("/format", response_model=FormatResponse)
    async def format_entry(
        request: FormatRequest,
        idempotency_key: Optional[str] = Header(default=None, alias="Idempotency-Key"),
        _: None = Depends(require_auth),
    ) -> FormatResponse:
        async def run() -> FormatResponse:
            protected = vocabulary.all()
            try:
                formatted = await formatter.format(request.raw_text, protected)
            except FormattingAlteredWordsError as exc:
                # 422 so the client treats it as permanent and does not retry a model that
                # will paraphrase again. Better no formatting than altered words.
                raise HTTPException(status_code=422, detail=str(exc))
            except GroqError as exc:
                raise HTTPException(status_code=502, detail=str(exc))

            # Report what was corrected. This is how the user finds out that their friend's
            # name got "fixed", which is the only realistic way they'd know to protect it.
            analysis = getattr(formatter, "last_analysis", None)
            corrections = [
                {"original": original, "replacement": replacement}
                for original, replacement in (analysis.corrections if analysis else [])
            ]
            return FormatResponse(
                formatted_text=formatted,
                formatter_version=settings.formatter_version,
                corrections=corrections,
            )

        return await idempotency.run(idempotency_key, request.model_dump(), run)

    # --- Notion -------------------------------------------------------------------

    @app.post("/notion/ensure-page", response_model=EnsurePageResponse)
    async def ensure_page(
        request: EnsurePageRequest,
        idempotency_key: Optional[str] = Header(default=None, alias="Idempotency-Key"),
        _: None = Depends(require_auth),
    ) -> EnsurePageResponse:
        gateway = resolve_notion()

        async def run() -> EnsurePageResponse:
            try:
                page_id = await gateway.ensure_page(
                    request.entry_date, request.title, request.existing_page_id
                )
            except NotionError as exc:
                raise HTTPException(status_code=502, detail=str(exc))
            return EnsurePageResponse(page_id=page_id)

        return await idempotency.run(idempotency_key, request.model_dump(), run)

    @app.post("/notion/upload-file", response_model=UploadFileResponse)
    async def upload_file(
        file: UploadFile = File(...),
        media_id: str = Form(...),
        idempotency_key: Optional[str] = Header(default=None, alias="Idempotency-Key"),
        _: None = Depends(require_auth),
    ) -> UploadFileResponse:
        data = await file.read()
        gateway = resolve_notion()

        async def run() -> UploadFileResponse:
            try:
                file_id = await gateway.upload_file(data, file.filename or "upload", media_id)
            except (NotionUploadUnsupported, NotionUploadTooLarge) as exc:
                # 422, not 5xx: retrying will not help. The client marks this one item failed
                # and syncs the entry anyway (ADR-015a).
                raise HTTPException(status_code=422, detail=str(exc))
            except NotionError as exc:
                raise HTTPException(status_code=502, detail=str(exc))
            return UploadFileResponse(file_id=file_id)

        return await idempotency.run(
            idempotency_key, {"media_id": media_id, "size": len(data)}, run
        )

    @app.post("/notion/insert-content", response_model=InsertContentResponse)
    async def insert_content(
        request: InsertContentRequest,
        idempotency_key: Optional[str] = Header(default=None, alias="Idempotency-Key"),
        _: None = Depends(require_auth),
    ) -> InsertContentResponse:
        gateway = resolve_notion()

        # The endpoint the whole idempotency design exists for. Replaying this without a key
        # would put the user's entry in Notion twice.
        async def run() -> InsertContentResponse:
            try:
                block_ids = await insert_entry(
                    gateway,
                    request.page_id,
                    request.formatted_text,
                    request.files,
                    request.replace_block_ids,
                )
            except NotionError as exc:
                raise HTTPException(status_code=502, detail=str(exc))
            return InsertContentResponse(block_ids=block_ids)

        return await idempotency.run(idempotency_key, request.model_dump(), run)

    @app.post("/notion/update-props", response_model=EmptyResponse)
    async def update_props(
        request: UpdatePropertiesRequest,
        idempotency_key: Optional[str] = Header(default=None, alias="Idempotency-Key"),
        _: None = Depends(require_auth),
    ) -> EmptyResponse:
        gateway = resolve_notion()

        async def run() -> EmptyResponse:
            try:
                await gateway.update_properties(
                    request.page_id, request.title, request.entry_date
                )
            except NotionError as exc:
                raise HTTPException(status_code=502, detail=str(exc))
            return EmptyResponse()

        return await idempotency.run(idempotency_key, request.model_dump(), run)

    return app


app = create_app()
