"""Idempotent request handling.

This is the single most load-bearing thing in the backend. The iOS client's entire sync
design assumes that repeating a mutating call with the same ``Idempotency-Key`` **replays**
the original result rather than performing the write again. Without that, a successful
``insert-content`` whose response was lost becomes a second copy of the user's journal entry
in Notion, and they discover it by hand weeks later.

See ADR-003 in ``docs/architecture/decisions.md``.

Three cases have to be distinguished, and conflating any two of them causes a bug:

============================  ==================================================
Case                          Response
============================  ==================================================
Key unseen                    Execute, store the result, return it
Key seen, completed           Return the stored result verbatim; do NOT execute
Key seen, still in flight     409 — a duplicate is racing; retry shortly
Key seen, different payload   422 — a client bug; refuse rather than guess
============================  ==================================================

That last case matters more than it looks. Reusing one key for two different payloads means
the client's attempt bookkeeping is broken; silently returning the first result would hide
the bug and silently executing the second would defeat the purpose.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import time
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, Optional

from fastapi import HTTPException, status


def fingerprint(payload: Any) -> str:
    """Stable hash of a request payload, used to detect key reuse across different bodies."""
    encoded = json.dumps(payload, sort_keys=True, default=str, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


@dataclass
class _Record:
    fingerprint: str
    created_at: float
    completed: bool = False
    response: Optional[Any] = None
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)  # created inside the loop


class IdempotencyStore:
    """In-memory idempotency cache.

    In-memory is deliberate for now and is a real limitation, not an oversight: restarting
    the process forgets every key, so a retry that spans a deploy can double-write. It is
    the correct starting point (no infrastructure, fully testable) and the interface is
    narrow enough to swap for Redis or Postgres without touching a single handler. That
    swap should happen before this runs anywhere with more than one worker process — see
    the note in ``backend/README.md``.
    """

    def __init__(self, ttl_seconds: float = 24 * 60 * 60) -> None:
        self._records: Dict[str, _Record] = {}
        self._ttl = ttl_seconds
        # Created lazily: on Python 3.9 `asyncio.Lock()` binds to the current event loop at
        # construction, and the app is built outside one. Constructing it here raised
        # "there is no current event loop" depending on what ran first.
        self._guard_lock: Optional[asyncio.Lock] = None

    @property
    def _guard(self) -> asyncio.Lock:
        if self._guard_lock is None:
            self._guard_lock = asyncio.Lock()
        return self._guard_lock

    async def run(
        self,
        key: Optional[str],
        payload: Any,
        operation: Callable[[], Awaitable[Any]],
    ) -> Any:
        """Execute ``operation`` at most once per key.

        A missing key means the caller opted out; the operation simply runs. That keeps
        non-mutating endpoints from needing ceremony, but every mutating client call is
        expected to supply one.
        """
        if key is None:
            return await operation()

        request_fingerprint = fingerprint(payload)

        async with self._guard:
            self._evict_expired()
            record = self._records.get(key)
            if record is None:
                record = _Record(fingerprint=request_fingerprint, created_at=time.monotonic())
                self._records[key] = record

        if record.fingerprint != request_fingerprint:
            raise HTTPException(
                status_code=422,  # Unprocessable Content
                detail=(
                    "This Idempotency-Key was already used for a different request body. "
                    "Keys must be unique per logical operation."
                ),
            )

        if record.completed:
            # The replay path. This is the whole point of the module.
            return record.response

        if record.lock.locked():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="A request with this Idempotency-Key is already in progress.",
            )

        async with record.lock:
            # Re-check: another coroutine may have completed it while we waited.
            if record.completed:
                return record.response

            result = await operation()
            record.response = result
            record.completed = True
            return result

    def _evict_expired(self) -> None:
        cutoff = time.monotonic() - self._ttl
        expired = [
            key
            for key, record in self._records.items()
            if record.created_at < cutoff and record.completed
        ]
        for key in expired:
            del self._records[key]

    # Test and diagnostic helpers.

    def __len__(self) -> int:
        return len(self._records)

    def clear(self) -> None:
        self._records.clear()
