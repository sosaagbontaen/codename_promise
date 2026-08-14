"""Settings, read from the environment.

Every secret here comes from the environment and nothing is defaulted to a real value. With
none of it set the service runs on deterministic stubs, which is what lets the iOS client be
developed without credentials.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional


def _env(name: str) -> Optional[str]:
    """Environment value, treating blank as absent.

    Sourcing a `.env` exports empty variables rather than leaving them unset, so
    `CP_API_KEY=` arrives as `""`. Anything checking `is not None` then sees a configured
    value — which turned auth on with an empty expected token and locked the client out
    while `/health` cheerfully reported `auth_required: true`. Normalise once, here.
    """
    value = os.environ.get(name)
    if value is None:
        return None
    value = value.strip()
    return value or None


def _flag(name: str) -> bool:
    return (os.environ.get(name) or "").lower() in {"1", "true", "yes"}


@dataclass(frozen=True)
class Settings:
    api_key: Optional[str] = None

    # Groq Cloud. OpenAI-compatible, so switching providers is a base-URL change.
    groq_api_key: Optional[str] = None
    groq_base_url: str = "https://api.groq.com/openai/v1"
    transcription_model: str = "whisper-large-v3-turbo"
    formatting_model: str = "llama-3.3-70b-versatile"

    # Notion OAuth — from a public integration in Notion's developer settings.
    notion_client_id: Optional[str] = None
    notion_client_secret: Optional[str] = None
    notion_redirect_uri: Optional[str] = None
    #: Where to bounce the user after a successful sign-in, so the app can come forward.
    app_return_url: str = "codenamepromise://notion-connected"

    formatter_version: str = "wwwt-2026-08"
    #: Notion caps file size by workspace plan — 5MB on free. Raise it for a paid workspace.
    notion_max_upload_mb: float = 5.0
    #: Off by default. The user's journal is the most sensitive text they own, so retaining
    #: prompts or audio has to be an explicit opt-in. See ADR-022.
    retain_payloads: bool = False
    #: Enforce that formatting only restructures. Escape hatch for debugging a model, never
    #: for shipping. See app/wordguard.py.
    enforce_wording: bool = True

    @staticmethod
    def from_env() -> "Settings":
        return Settings(
            api_key=_env("CP_API_KEY"),
            groq_api_key=_env("GROQ_API_KEY"),
            groq_base_url=_env("GROQ_BASE_URL") or "https://api.groq.com/openai/v1",
            transcription_model=_env("CP_TRANSCRIPTION_MODEL") or "whisper-large-v3-turbo",
            formatting_model=_env("CP_FORMATTING_MODEL") or "llama-3.3-70b-versatile",
            notion_client_id=_env("NOTION_CLIENT_ID"),
            notion_client_secret=_env("NOTION_CLIENT_SECRET"),
            notion_redirect_uri=_env("NOTION_REDIRECT_URI"),
            app_return_url=_env("CP_APP_RETURN_URL") or "codenamepromise://notion-connected",
            formatter_version=_env("CP_FORMATTER_VERSION") or "wwwt-2026-08",
            notion_max_upload_mb=float(_env("CP_NOTION_MAX_UPLOAD_MB") or 5.0),
            retain_payloads=_flag("CP_RETAIN_PAYLOADS"),
            enforce_wording=not _flag("CP_DISABLE_WORDING_GUARD"),
        )

    @property
    def requires_auth(self) -> bool:
        return self.api_key is not None

    @property
    def has_groq(self) -> bool:
        return bool(self.groq_api_key)
