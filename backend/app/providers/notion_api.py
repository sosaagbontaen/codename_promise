"""Real Notion gateway, driven by an OAuth access token.

Page identity is the **draft**, not the day (ADR-006, revised). Each `EntryDraft` gets its own
page; `entry_date` is a property on it.

The earlier design searched the database for any page carrying the same date and reused it.
That was wrong in two ways. It merged separate entries written on one day, and — much worse —
it adopted pages this app never created, including ones the user had written by hand, then
wrote into them. An integration must not claim ownership of a page just because a property
matched.

Retries are handled instead by the client's stored `existing_page_id` and by the idempotency
key. The residual risk is a duplicate page if a response is lost *and* the idempotency cache
has been dropped — and a visible duplicate is enormously preferable to silently overwriting
something the user wrote.

Property names are discovered from the database schema rather than assumed. Every workspace
names its columns differently, and guessing "Name"/"Date" would work for exactly the person
who happened to use the defaults.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import httpx

from ..blocks import batched

NOTION_BASE_URL = "https://api.notion.com/v1"

#: Pinned deliberately. Notion's API is versioned by date and older versions keep working;
#: an unpinned client breaks silently when they ship a new default.
NOTION_VERSION = "2022-06-28"

#: File uploads and `file_upload` block attachments require a newer version than the rest of
#: this client uses. Bumping globally is not safe: 2025-09-03 reworked databases around data
#: sources, which would change how pages are created and queried. So the version is per-call —
#: uploads and block appends use this, everything else stays on the pinned version.
NOTION_FILE_VERSION = "2026-03-11"

#: Notion's single-part *protocol* threshold. Above this the API wants a multi-part upload,
#: which is a different flow and isn't implemented.
SINGLE_PART_LIMIT_BYTES = 20 * 1024 * 1024

#: The limit that actually bites: Notion caps individual file size by workspace plan, and on
#: the free plan that is 5 MiB — verified against a live workspace, which answers
#: "File size of 5.5 MiB exceeds the limit of 5 MiB."
#:
#: This was originally checked only against the 20MB threshold above, so anything between
#: 5 and 20MB skipped the guard, reached Notion, and came back as a generic 400 that the
#: client classified as retryable — a file that can never fit, retried forever.
#: `CP_NOTION_MAX_UPLOAD_MB` raises it for paid workspaces.
DEFAULT_MAX_UPLOAD_BYTES = 5 * 1024 * 1024


class NotionError(Exception):
    pass


class NotionUploadTooLarge(NotionError):
    """The file needs Notion's multi-part flow, which isn't implemented."""


class NotionUploadUnsupported(NotionError):
    """Raised when media upload is attempted but not available.

    This is a *deliberate* limitation rather than an oversight. Direct file upload through
    the Notion API is not implemented here, and the sync path already treats media as
    best-effort (ADR-015a) — so the entry's words still reach Notion and the photo is marked
    failed rather than taking the entry down with it.
    """


class NotionGatewayHTTP:
    def __init__(
        self,
        access_token: str,
        database_id: str,
        title_property: Optional[str] = None,
        date_property: Optional[str] = None,
        base_url: str = NOTION_BASE_URL,
        timeout: float = 30.0,
        max_upload_bytes: int = DEFAULT_MAX_UPLOAD_BYTES,
    ) -> None:
        self._max_upload_bytes = max_upload_bytes
        self._token = access_token
        self._database_id = database_id
        self._title_property = title_property
        self._date_property = date_property
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout

    @property
    def _headers(self) -> Dict[str, str]:
        return {
            "Authorization": f"Bearer {self._token}",
            "Notion-Version": NOTION_VERSION,
            "Content-Type": "application/json",
        }

    def _file_headers(self, json_content: bool = True) -> Dict[str, str]:
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Notion-Version": NOTION_FILE_VERSION,
        }
        if json_content:
            headers["Content-Type"] = "application/json"
        return headers

    async def _request(self, method: str, path: str, **kwargs: Any) -> Dict[str, Any]:
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.request(
                    method, f"{self._base_url}{path}", headers=self._headers, **kwargs
                )
        except httpx.HTTPError as exc:
            raise NotionError(f"Could not reach Notion: {exc}") from exc

        if response.status_code >= 400:
            detail = ""
            try:
                detail = response.json().get("message", "")
            except Exception:
                pass
            raise NotionError(f"Notion returned {response.status_code}. {detail}".strip())

        if not response.content:
            return {}
        return response.json()

    # --- Schema discovery -------------------------------------------------------------

    async def resolve_properties(self) -> Dict[str, Optional[str]]:
        """Find the title and date columns of the chosen database."""
        schema = await self._request("GET", f"/databases/{self._database_id}")
        properties: Dict[str, Any] = schema.get("properties", {})

        title = next((name for name, prop in properties.items() if prop.get("type") == "title"), None)
        date = next((name for name, prop in properties.items() if prop.get("type") == "date"), None)

        self._title_property = self._title_property or title
        self._date_property = self._date_property or date
        return {"title_property": self._title_property, "date_property": self._date_property}

    # --- NotionGateway --------------------------------------------------------------

    async def ensure_page(
        self, entry_date: str, title: Optional[str], existing_page_id: Optional[str]
    ) -> str:
        """Return this draft's page, creating one the first time.

        Only ever reuses a page this client previously created and recorded. It never goes
        looking for a page to adopt — see the module docstring for what that cost.
        """
        if existing_page_id:
            # Confirm the recorded page still exists; one deleted in Notion should produce a
            # fresh page rather than a confusing 404 partway through a sync.
            try:
                page = await self._request("GET", f"/pages/{existing_page_id}")
                if not page.get("archived", False):
                    return existing_page_id
            except NotionError:
                pass

        if not self._title_property or not self._date_property:
            await self.resolve_properties()

        return await self._create_page(entry_date, title)

    async def _create_page(self, entry_date: str, title: Optional[str]) -> str:
        properties: Dict[str, Any] = {}
        if self._title_property:
            properties[self._title_property] = {
                "title": [{"text": {"content": title or entry_date}}]
            }
        if self._date_property:
            properties[self._date_property] = {"date": {"start": entry_date}}

        page = await self._request(
            "POST",
            "/pages",
            json={"parent": {"database_id": self._database_id}, "properties": properties},
        )
        return page["id"]

    async def upload_file(self, data: bytes, filename: str, media_id: str) -> str:
        """Uploads bytes to Notion and returns a `file_upload` id to attach.

        Three steps, per Notion's contract: create the upload object, send the bytes, then
        reference the id from a block. The id is durable and reusable — "upload once, attach
        many times" — which is why the client records it and never re-uploads on a retry.
        """
        size_mb = len(data) / (1024 * 1024)
        limit_mb = self._max_upload_bytes / (1024 * 1024)

        # Checked here rather than left to Notion so the failure is permanent and legible.
        # Notion's own answer is a generic 400, which the client would treat as retryable.
        if len(data) > self._max_upload_bytes:
            raise NotionUploadTooLarge(
                f"{filename} is {size_mb:.1f}MB — over Notion's {limit_mb:.0f}MB limit for "
                "this workspace. The entry's text synced without it."
            )
        if len(data) > SINGLE_PART_LIMIT_BYTES:
            raise NotionUploadTooLarge(
                f"{filename} is {size_mb:.0f}MB, which needs a multi-part upload that isn't "
                "implemented yet. The entry's text synced without it."
            )

        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                created = await client.post(
                    f"{self._base_url}/file_uploads",
                    headers=self._file_headers(),
                    json={"filename": filename, "content_type": _mime_type(filename)},
                )
                if created.status_code >= 400:
                    raise NotionError(
                        f"Notion refused the upload ({created.status_code}). "
                        + str(created.json().get("message", ""))
                    )
                upload = created.json()
                upload_id = upload["id"]

                sent = await client.post(
                    f"{self._base_url}/file_uploads/{upload_id}/send",
                    headers=self._file_headers(json_content=False),
                    files={"file": (filename, data, _mime_type(filename))},
                )
                if sent.status_code >= 400:
                    message = str(sent.json().get("message", ""))
                    # Belt and braces: a workspace on a different plan may have a different
                    # cap than we assume. Size rejections are permanent whatever the number.
                    if "exceeds the limit" in message or "size" in message.lower():
                        raise NotionUploadTooLarge(
                            f"{filename} ({size_mb:.1f}MB) is too large for this Notion "
                            f"workspace. {message} The entry's text synced without it."
                        )
                    raise NotionError(
                        f"Notion rejected the file contents ({sent.status_code}). {message}"
                    )
        except httpx.HTTPError as exc:
            raise NotionError(f"Could not reach Notion: {exc}") from exc

        return upload_id

    async def replace_children(
        self, page_id: str, blocks: List[Dict[str, Any]], replace_block_ids: List[str]
    ) -> List[str]:
        # Delete first, then append. The other order would briefly show the entry twice on
        # the page, and a failure between the two would leave it that way permanently.
        for block_id in replace_block_ids:
            try:
                await self._request("DELETE", f"/blocks/{block_id}")
            except NotionError:
                # Already gone — someone deleted it in Notion. Not a failure.
                pass

        created: List[str] = []
        for batch in batched(blocks):
            # Block append uses the newer version because `file_upload` attachments require
            # it. Appending plain text blocks is unchanged across both.
            try:
                async with httpx.AsyncClient(timeout=self._timeout) as client:
                    response = await client.patch(
                        f"{self._base_url}/blocks/{page_id}/children",
                        headers=self._file_headers(),
                        json={"children": batch},
                    )
            except httpx.HTTPError as exc:
                raise NotionError(f"Could not reach Notion: {exc}") from exc
            if response.status_code >= 400:
                detail = ""
                try:
                    detail = response.json().get("message", "")
                except Exception:
                    pass
                raise NotionError(f"Notion returned {response.status_code}. {detail}".strip())
            created.extend(block["id"] for block in response.json().get("results", []))
        return created

    async def update_properties(
        self, page_id: str, title: Optional[str], entry_date: str
    ) -> None:
        if not self._title_property or not self._date_property:
            await self.resolve_properties()

        properties: Dict[str, Any] = {}
        if self._title_property and title:
            properties[self._title_property] = {"title": [{"text": {"content": title}}]}
        if self._date_property:
            properties[self._date_property] = {"date": {"start": entry_date}}

        if properties:
            await self._request("PATCH", f"/pages/{page_id}", json={"properties": properties})


def _mime_type(filename: str) -> str:
    return {
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
        "heic": "image/heic", "gif": "image/gif", "webp": "image/webp",
        "mov": "video/quicktime", "mp4": "video/mp4", "m4v": "video/x-m4v",
        "m4a": "audio/m4a", "pdf": "application/pdf",
    }.get(filename.rsplit(".", 1)[-1].lower(), "application/octet-stream")


async def list_pages(
    access_token: str,
    database_id: str,
    limit: int = 50,
    base_url: str = NOTION_BASE_URL,
) -> List[Dict[str, Any]]:
    """Recent pages in the chosen database, for the "add to an existing entry" picker.

    Read-only, and deliberately shallow: it returns what a person needs to recognise an
    entry — its title, its date, when it last changed — and never its content. Appending
    does not require reading the page, which is exactly why appending cannot flatten the
    toggles, callouts and embeds that a round-trip would.
    """
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
    }
    payload: Dict[str, Any] = {
        "sorts": [{"timestamp": "last_edited_time", "direction": "descending"}],
        "page_size": min(limit, 100),
    }

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{base_url}/databases/{database_id}/query", headers=headers, json=payload
            )
    except httpx.HTTPError as exc:
        raise NotionError(f"Could not reach Notion: {exc}") from exc

    if response.status_code >= 400:
        raise NotionError(f"Notion returned {response.status_code} listing pages.")

    pages: List[Dict[str, Any]] = []
    for item in response.json().get("results", []):
        properties = item.get("properties", {})
        title = ""
        entry_date = None
        for value in properties.values():
            if value.get("type") == "title" and not title:
                title = "".join(part.get("plain_text", "") for part in value.get("title", []))
            elif value.get("type") == "date" and entry_date is None:
                date_value = value.get("date") or {}
                entry_date = date_value.get("start")
        pages.append(
            {
                "id": item["id"],
                "title": title.strip() or "Untitled",
                "entry_date": entry_date,
                # Carried so a future edit feature can detect that a page changed underneath
                # it. Appending does not need it, but recording it costs nothing.
                "last_edited_time": item.get("last_edited_time"),
            }
        )
    return pages


async def list_databases(access_token: str, base_url: str = NOTION_BASE_URL) -> List[Dict[str, str]]:
    """Databases the user granted this integration access to, for the in-app picker.

    Notion's own authorisation screen is where the user chooses what to share, so this
    returns exactly that set — there is nothing to ask permission for a second time.
    """
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
    }
    payload = {"filter": {"value": "database", "property": "object"}, "page_size": 100}

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(f"{base_url}/search", headers=headers, json=payload)
    except httpx.HTTPError as exc:
        raise NotionError(f"Could not reach Notion: {exc}") from exc

    if response.status_code >= 400:
        raise NotionError(f"Notion returned {response.status_code} listing databases.")

    databases: List[Dict[str, str]] = []
    for item in response.json().get("results", []):
        title_parts = item.get("title", [])
        name = "".join(part.get("plain_text", "") for part in title_parts).strip()
        databases.append({"id": item["id"], "title": name or "Untitled database"})
    return databases
