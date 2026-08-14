"""Notion connection endpoints: sign in, pick a database, check status, disconnect.

Everything the *app* can see about the connection is deliberately narrow — a boolean, a
workspace name, and the chosen database. The access token stays here.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

from .connections import ConnectionStore
from .oauth import NotionOAuth, OAuthNotConfigured, OAuthStateError
from .providers.notion_api import NotionError, NotionGatewayHTTP, list_databases, list_pages


class SelectDatabaseRequest(BaseModel):
    database_id: str


def build_router(
    oauth: NotionOAuth,
    store: ConnectionStore,
    app_return_url: str,
    database_lister=list_databases,
    gateway_factory=NotionGatewayHTTP,
    page_lister=list_pages,
) -> APIRouter:
    router = APIRouter(prefix="/notion", tags=["notion-auth"])

    @router.get("/connection")
    async def connection_status() -> Dict[str, Any]:
        """What the app polls. Never includes the token."""
        connection = store.get()
        if connection is None:
            return {"connected": False, "ready": False, "configurable": oauth.is_configured}
        summary = connection.public_summary()
        summary["configurable"] = oauth.is_configured
        return summary

    @router.get("/oauth/start")
    async def oauth_start() -> RedirectResponse:
        try:
            return RedirectResponse(oauth.authorization_url(), status_code=307)
        except OAuthNotConfigured as exc:
            raise HTTPException(status_code=503, detail=str(exc))

    @router.get("/oauth/callback")
    async def oauth_callback(
        code: Optional[str] = None,
        state: Optional[str] = None,
        error: Optional[str] = None,
    ):
        # The user declined on Notion's screen. Not an error condition for us.
        if error:
            return HTMLResponse(_closing_page("Sign-in cancelled.", ""), status_code=200)
        if not code:
            raise HTTPException(status_code=400, detail="Notion did not return a code.")

        try:
            connection = await oauth.exchange(code, state)
        except OAuthNotConfigured as exc:
            raise HTTPException(status_code=503, detail=str(exc))
        except OAuthStateError as exc:
            raise HTTPException(status_code=400, detail=str(exc))

        # Preserve an already-chosen database across re-authorisation, so reconnecting
        # doesn't silently orphan every previously synced entry.
        existing = store.get()
        if existing and existing.database_id:
            connection.database_id = existing.database_id
            connection.database_title = existing.database_title
            connection.title_property = existing.title_property
            connection.date_property = existing.date_property

        store.save(connection)
        return HTMLResponse(
            _closing_page(
                f"Connected to {connection.workspace_name or 'Notion'}.",
                app_return_url,
            )
        )

    @router.get("/databases")
    async def databases() -> Dict[str, List[Dict[str, str]]]:
        """The databases the user shared during authorisation — the picker's contents."""
        connection = store.get()
        if connection is None:
            raise HTTPException(status_code=409, detail="Notion isn't connected yet.")
        try:
            return {"databases": await database_lister(connection.access_token)}
        except NotionError as exc:
            raise HTTPException(status_code=502, detail=str(exc))

    @router.get("/pages")
    async def pages() -> Dict[str, List[Dict[str, Any]]]:
        """Existing entries, for the "add to an existing entry" picker.

        Returns only what identifies a page — never its content. Appending doesn't need to
        read the page, which is what keeps it from flattening blocks the app can't model.
        """
        connection = store.get()
        if connection is None or not connection.is_ready:
            raise HTTPException(status_code=409, detail="Pick a Notion database first.")
        try:
            return {"pages": await page_lister(connection.access_token, connection.database_id)}
        except NotionError as exc:
            raise HTTPException(status_code=502, detail=str(exc))

    @router.post("/database")
    async def select_database(request: SelectDatabaseRequest) -> Dict[str, Any]:
        connection = store.get()
        if connection is None:
            raise HTTPException(status_code=409, detail="Notion isn't connected yet.")

        # Resolve the title and date columns now rather than at sync time, so a database
        # missing a date property fails here — where the user is looking at a picker and can
        # choose a different one — instead of mid-sync.
        gateway = gateway_factory(
            access_token=connection.access_token, database_id=request.database_id
        )
        try:
            resolved = await gateway.resolve_properties()
        except NotionError as exc:
            raise HTTPException(status_code=502, detail=str(exc))

        if not resolved.get("date_property"):
            raise HTTPException(
                status_code=422,
                detail=(
                    "That database has no date column. Entries are filed by the day they're "
                    "about, so a date property is required. Pick another database or add one."
                ),
            )

        title = None
        try:
            for candidate in await database_lister(connection.access_token):
                if candidate["id"] == request.database_id:
                    title = candidate["title"]
                    break
        except NotionError:
            pass

        connection.database_id = request.database_id
        connection.database_title = title
        connection.title_property = resolved.get("title_property")
        connection.date_property = resolved.get("date_property")
        store.save(connection)
        return connection.public_summary()

    @router.delete("/connection")
    async def disconnect() -> Dict[str, bool]:
        """Forgets the token. Local entries are untouched — sync is optional (tenet 4)."""
        store.clear()
        return {"connected": False, "ready": False}

    return router


def _closing_page(message: str, return_url: str) -> str:
    """Minimal page shown in the auth session before it hands back to the app."""
    redirect = (
        f'<meta http-equiv="refresh" content="0;url={return_url}">' if return_url else ""
    )
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Codename Promise</title>{redirect}
<style>
  body {{ font: 16px -apple-system, system-ui, sans-serif; margin: 0;
         display: grid; place-items: center; height: 100vh; color: #111; background: #fff; }}
  @media (prefers-color-scheme: dark) {{ body {{ background: #111; color: #eee; }} }}
  p {{ opacity: .7 }}
</style></head>
<body><div><h2>{message}</h2><p>You can close this window.</p></div></body></html>"""
