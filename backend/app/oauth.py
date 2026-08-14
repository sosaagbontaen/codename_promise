"""Notion OAuth.

The flow, and why it is shaped this way:

1. The app opens ``/notion/oauth/start`` in a web session.
2. That redirects to Notion, where the user signs in **to Notion, not to us**, and picks
   which pages or databases to share. Notion's own screen is the permission UI — there is no
   place where this app asks for a Notion password, and no key for the user to copy.
3. Notion redirects back to ``/notion/oauth/callback`` with a short-lived code.
4. The backend exchanges that code for an access token using the client secret, stores the
   token **server-side**, and bounces the user back to the app via a custom scheme.
5. The app calls ``/notion/databases`` to show a picker, then ``/notion/database`` to choose.

The token never touches the device. The app's view of all this is a boolean and a workspace
name — see :meth:`NotionConnection.public_summary`.

``state`` is generated per attempt and verified on return, so a callback the app did not
initiate is rejected.
"""

from __future__ import annotations

import base64
import secrets
import time
from typing import Dict, Optional

import httpx

from .connections import NotionConnection

NOTION_AUTHORIZE_URL = "https://api.notion.com/v1/oauth/authorize"
NOTION_TOKEN_URL = "https://api.notion.com/v1/oauth/token"

#: Long enough for a real sign-in including 2FA, short enough that a leaked state is useless.
STATE_TTL_SECONDS = 15 * 60


class OAuthNotConfigured(Exception):
    """Raised when the Notion integration credentials are absent."""


class OAuthStateError(Exception):
    """Raised when a callback's state is unknown or expired."""


class StateStore:
    """One-shot, expiring CSRF states."""

    def __init__(self, ttl_seconds: float = STATE_TTL_SECONDS) -> None:
        self._states: Dict[str, float] = {}
        self._ttl = ttl_seconds

    def issue(self) -> str:
        self._evict()
        state = secrets.token_urlsafe(32)
        self._states[state] = time.monotonic()
        return state

    def consume(self, state: Optional[str]) -> None:
        """Verify and burn a state. Raises if it is unknown or expired."""
        self._evict()
        if not state or state not in self._states:
            raise OAuthStateError("This sign-in link is no longer valid. Please try again.")
        # One-shot: a replayed callback must not authorise a second time.
        del self._states[state]

    def _evict(self) -> None:
        cutoff = time.monotonic() - self._ttl
        for state in [s for s, issued in self._states.items() if issued < cutoff]:
            del self._states[state]

    def __len__(self) -> int:
        return len(self._states)


class NotionOAuth:
    def __init__(
        self,
        client_id: Optional[str],
        client_secret: Optional[str],
        redirect_uri: Optional[str],
        authorize_url: str = NOTION_AUTHORIZE_URL,
        token_url: str = NOTION_TOKEN_URL,
    ) -> None:
        self._client_id = client_id
        self._client_secret = client_secret
        self._redirect_uri = redirect_uri
        self._authorize_url = authorize_url
        self._token_url = token_url
        self.states = StateStore()

    @property
    def is_configured(self) -> bool:
        return bool(self._client_id and self._client_secret and self._redirect_uri)

    def _require_configured(self) -> None:
        if not self.is_configured:
            raise OAuthNotConfigured(
                "Notion isn't set up on this server. Set NOTION_CLIENT_ID, "
                "NOTION_CLIENT_SECRET and NOTION_REDIRECT_URI."
            )

    def authorization_url(self) -> str:
        """The URL to open. Includes a fresh single-use state."""
        self._require_configured()
        state = self.states.issue()
        from urllib.parse import urlencode

        query = urlencode(
            {
                "client_id": self._client_id,
                "response_type": "code",
                "owner": "user",
                "redirect_uri": self._redirect_uri,
                "state": state,
            }
        )
        return f"{self._authorize_url}?{query}"

    async def exchange(self, code: str, state: Optional[str]) -> NotionConnection:
        """Trade the callback code for an access token."""
        self._require_configured()
        self.states.consume(state)

        basic = base64.b64encode(
            f"{self._client_id}:{self._client_secret}".encode("utf-8")
        ).decode("ascii")

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    self._token_url,
                    headers={
                        "Authorization": f"Basic {basic}",
                        "Content-Type": "application/json",
                    },
                    json={
                        "grant_type": "authorization_code",
                        "code": code,
                        "redirect_uri": self._redirect_uri,
                    },
                )
        except httpx.HTTPError as exc:
            raise OAuthStateError(f"Could not reach Notion: {exc}") from exc

        if response.status_code >= 400:
            # Deliberately does not echo Notion's body — it can contain the code.
            raise OAuthStateError(f"Notion rejected the sign-in ({response.status_code}).")

        payload = response.json()
        return NotionConnection(
            access_token=payload["access_token"],
            workspace_id=payload.get("workspace_id", ""),
            workspace_name=payload.get("workspace_name"),
            bot_id=payload.get("bot_id"),
        )
