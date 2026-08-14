"""Storage for a user's Notion connection.

What this holds is a live credential to someone's Notion workspace, so a few things are
deliberate:

* The token lives **server-side only**. It is never returned to the client — the app asks
  "am I connected?" and gets a boolean plus a workspace name, never the token itself. That
  keeps it out of the device, out of backups, and out of anything the client logs.
* The file is written with ``0600`` permissions and is gitignored.
* Single-user, file-backed, no encryption at rest. That is honest for one person running this
  on their own machine and **not** sufficient for multiple users — see the note in
  ``backend/README.md``. Multi-user needs per-user rows and an encrypted column.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, Optional


@dataclass
class NotionConnection:
    access_token: str
    workspace_id: str
    workspace_name: Optional[str] = None
    bot_id: Optional[str] = None
    #: Chosen by the user after authorising, from the databases they granted access to.
    database_id: Optional[str] = None
    database_title: Optional[str] = None
    #: Property names discovered from the chosen database's schema. Every workspace names
    #: these differently, so they are resolved once rather than assumed.
    title_property: Optional[str] = None
    date_property: Optional[str] = None

    @property
    def destination_fingerprint(self) -> Optional[str]:
        """Identifies *which* Notion this is.

        Page IDs, file IDs and block IDs are only meaningful against the destination that
        issued them. When a client is pointed at a different workspace or database — or, in
        development, switched from the in-memory stub to real Notion — the IDs it has cached
        are not merely stale, they are nonsense. Comparing this lets the client notice and
        start clean instead of sending fabricated references.
        """
        if not (self.workspace_id and self.database_id):
            return None
        digest = hashlib.sha256(f"{self.workspace_id}:{self.database_id}".encode()).hexdigest()
        return digest[:16]

    @property
    def is_ready(self) -> bool:
        """Connected *and* pointed at a database. Authorising alone is not enough."""
        return bool(self.access_token and self.database_id)

    def public_summary(self) -> Dict[str, object]:
        """What the client is allowed to know. Deliberately excludes the token."""
        return {
            "connected": True,
            "workspace_name": self.workspace_name,
            "database_id": self.database_id,
            "database_title": self.database_title,
            "ready": self.is_ready,
            "destination_fingerprint": self.destination_fingerprint,
        }


class ConnectionStore:
    """Persists the connection to a JSON file."""

    def __init__(self, path: Optional[Path] = None) -> None:
        self._path = Path(path) if path else Path(os.environ.get("CP_STATE_DIR", ".state")) / "notion.json"
        self._cached: Optional[NotionConnection] = None
        self._loaded = False

    def get(self) -> Optional[NotionConnection]:
        if not self._loaded:
            self._cached = self._read()
            self._loaded = True
        return self._cached

    def save(self, connection: NotionConnection) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(asdict(connection), indent=2)
        # Write then chmod, so the token is never briefly world-readable.
        self._path.write_text(payload)
        os.chmod(self._path, 0o600)
        self._cached = connection
        self._loaded = True

    def clear(self) -> None:
        if self._path.exists():
            self._path.unlink()
        self._cached = None
        self._loaded = True

    def _read(self) -> Optional[NotionConnection]:
        if not self._path.exists():
            return None
        try:
            data = json.loads(self._path.read_text())
            return NotionConnection(**data)
        except (json.JSONDecodeError, TypeError):
            # A corrupt connection file means "reconnect", never a crash on startup.
            return None


class InMemoryConnectionStore(ConnectionStore):
    """Test double that touches no filesystem."""

    def __init__(self, connection: Optional[NotionConnection] = None) -> None:
        self._cached = connection
        self._loaded = True

    def save(self, connection: NotionConnection) -> None:
        self._cached = connection

    def clear(self) -> None:
        self._cached = None
