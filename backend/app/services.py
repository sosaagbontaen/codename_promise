"""Provider boundaries.

Every outbound integration sits behind a Protocol with a deterministic stub implementation.
That means the whole API surface — including the idempotency and chunking behaviour the iOS
client depends on — is testable, and runnable end to end, without credentials or network.

The real OpenAI/Notion implementations slot in behind the same Protocols. They are the parts
that need keys, and they are deliberately the *last* thing to be written, because everything
around them can be proven correct first.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Protocol, Sequence

from .blocks import batched, build_entry_blocks


class Transcriber(Protocol):
    async def transcribe(self, audio: bytes, filename: str) -> str: ...


class Formatter(Protocol):
    #: ``protected`` carries the user's vocabulary — words that look like typos but are not.
    async def format(self, raw_text: str, protected: Sequence[str] = ()) -> str: ...


class NotionGateway(Protocol):
    async def ensure_page(
        self, entry_date: str, title: Optional[str], existing_page_id: Optional[str]
    ) -> str: ...

    async def upload_file(self, data: bytes, filename: str, media_id: str) -> str: ...

    async def replace_children(
        self, page_id: str, blocks: List[Dict[str, Any]], replace_block_ids: List[str]
    ) -> List[str]: ...

    async def update_properties(
        self, page_id: str, title: Optional[str], entry_date: str
    ) -> None: ...

    async def list_pages(self, limit: int = 50) -> List[Dict[str, Any]]: ...

    #: Days that already have a page, so the client can say which are missing.
    async def entry_days(self, start: str, end: str) -> List[str]: ...


# --- Stubs -----------------------------------------------------------------------------

class EchoTranscriber:
    """Returns a deterministic placeholder. Never pretends to have heard anything."""

    async def transcribe(self, audio: bytes, filename: str) -> str:
        return f"[transcription unavailable — {len(audio)} bytes of audio received]"


class PassthroughFormatter:
    """Groups lines into bullets without touching a single word.

    This is not a stand-in for the model so much as a demonstration of the contract: the
    formatter may only regroup and restructure. If a real implementation ever changes
    wording, it has broken the product's central promise, not just a test.
    """

    async def format(self, raw_text: str, protected: Sequence[str] = ()) -> str:
        lines = [line.strip() for line in raw_text.splitlines() if line.strip()]
        out: List[str] = []
        for line in lines:
            if line.startswith(("#", "-", "*", ">")):
                out.append(line)
            else:
                # Sentence-per-bullet, with the sentence itself left exactly as written.
                sentences = [s.strip() for s in line.replace("! ", "!|").replace("? ", "?|").replace(". ", ".|").split("|") if s.strip()]
                out.extend(f"- {sentence}" for sentence in sentences)
        return "\n".join(out)


class InMemoryNotion:
    """A Notion stand-in that keeps pages in a dict.

    It models the one behaviour that matters for correctness: ``replace_children`` removes
    the blocks it is told to replace before appending. If the server ever appends without
    replacing, a page here ends up with the entry twice — the same corruption the client's
    idempotency work guards against, made visible in a test.
    """

    def __init__(self) -> None:
        self.pages: Dict[str, Dict[str, Any]] = {}
        self.files: Dict[str, bytes] = {}
        self.blocks: Dict[str, Dict[str, Any]] = {}
        self.append_calls = 0
        self._next_id = 0

    def _id(self, prefix: str) -> str:
        self._next_id += 1
        return f"{prefix}-{self._next_id}"

    async def ensure_page(
        self, entry_date: str, title: Optional[str], existing_page_id: Optional[str]
    ) -> str:
        if existing_page_id and existing_page_id in self.pages:
            return existing_page_id
        # One page per draft. Deliberately does NOT look for an existing page with the same
        # date — doing that merged separate entries and adopted pages the app never created.
        # See ADR-006 (revised).
        page_id = self._id("page")
        self.pages[page_id] = {"entry_date": entry_date, "title": title, "children": []}
        return page_id

    async def upload_file(self, data: bytes, filename: str, media_id: str) -> str:
        file_id = self._id("file")
        self.files[file_id] = data
        return file_id

    async def replace_children(
        self, page_id: str, blocks: List[Dict[str, Any]], replace_block_ids: List[str]
    ) -> List[str]:
        page = self.pages.setdefault(page_id, {"entry_date": None, "title": None, "children": []})

        for block_id in replace_block_ids:
            self.blocks.pop(block_id, None)
            if block_id in page["children"]:
                page["children"].remove(block_id)

        created: List[str] = []
        for batch in batched(blocks):
            self.append_calls += 1
            for block in batch:
                block_id = self._id("block")
                self.blocks[block_id] = block
                page["children"].append(block_id)
                created.append(block_id)
        return created

    async def update_properties(
        self, page_id: str, title: Optional[str], entry_date: str
    ) -> None:
        page = self.pages.setdefault(page_id, {"entry_date": None, "title": None, "children": []})
        page["title"] = title
        page["entry_date"] = entry_date

    async def list_pages(self, limit: int = 50) -> List[Dict[str, Any]]:
        return [
            {
                "id": page_id,
                "title": page.get("title") or "Untitled",
                "entry_date": page.get("entry_date"),
                "last_edited_time": None,
            }
            for page_id, page in list(self.pages.items())[:limit]
        ]

    async def entry_days(self, start: str, end: str) -> List[str]:
        return sorted({
            str(page["entry_date"])[:10]
            for page in self.pages.values()
            if page.get("entry_date") and start <= str(page["entry_date"])[:10] <= end
        })


async def insert_entry(
    notion: NotionGateway,
    page_id: str,
    formatted_text: str,
    attached_files: List[Dict[str, str]],
    replace_block_ids: List[str],
) -> List[str]:
    """Convert, chunk, and write one entry's content."""
    blocks = build_entry_blocks(formatted_text, attached_files)
    return await notion.replace_children(page_id, blocks, replace_block_ids)
