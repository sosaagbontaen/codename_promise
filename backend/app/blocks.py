"""Markdown → Notion blocks, with chunking for Notion's limits.

This lives server-side so the iOS client never learns Notion's block schema, and so the
chunking rules live in exactly one place. See ADR-017.

Two hard limits from the Notion API, both of which a real WWWT entry will hit:

* **2000 characters** per rich-text object. A long reflective paragraph exceeds this easily.
* **100 children** per append request. A detailed day with many bullets exceeds this.

Neither limit produces a helpful error — you get a 400 — so a long entry would simply fail
to sync. For the thoughtful, longer entries this app exists to support, that failure mode is
exactly backwards.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Iterator, List, Optional, Tuple

RICH_TEXT_LIMIT = 2000
CHILDREN_PER_REQUEST = 100

_BULLET = re.compile(r"^\s*[-*+]\s+(.*)$")
_NUMBERED = re.compile(r"^\s*\d+[.)]\s+(.*)$")
_HEADING = re.compile(r"^(#{1,3})\s+(.*)$")
_QUOTE = re.compile(r"^\s*>\s?(.*)$")
_TODO = re.compile(r"^\s*[-*+]\s+\[([ xX])\]\s+(.*)$")


def split_rich_text(text: str, limit: int = RICH_TEXT_LIMIT) -> List[Dict[str, Any]]:
    """Split text into rich-text objects no longer than ``limit``.

    Splits on whitespace where possible so words aren't cut in half — the user's own words
    should survive transport looking like their words.
    """
    if not text:
        return []

    parts: List[str] = []
    remaining = text
    while len(remaining) > limit:
        window = remaining[:limit]
        cut = window.rfind(" ")
        # No breathing space in the window (a URL, say) — hard-cut rather than overflow.
        if cut <= limit // 2:
            cut = limit
        parts.append(remaining[:cut])
        remaining = remaining[cut:].lstrip()
    if remaining:
        parts.append(remaining)

    return [{"type": "text", "text": {"content": part}} for part in parts]


def _block(block_type: str, text: str, **extra: Any) -> Dict[str, Any]:
    payload: Dict[str, Any] = {"rich_text": split_rich_text(text)}
    payload.update(extra)
    return {"object": "block", "type": block_type, block_type: payload}


def _indent_width(raw_line: str) -> int:
    """Leading whitespace, with a tab counted as four spaces."""
    width = 0
    for char in raw_line:
        if char == " ":
            width += 1
        elif char == "\t":
            width += 4
        else:
            break
    return width


def _parse_line(line: str) -> Optional[Dict[str, Any]]:
    """One line of markdown-ish text as a Notion block, or None for a blank line."""
    if not line.strip():
        return None

    todo = _TODO.match(line)
    if todo:
        return _block("to_do", todo.group(2), checked=todo.group(1).lower() == "x")

    heading = _HEADING.match(line)
    if heading:
        return _block(f"heading_{len(heading.group(1))}", heading.group(2))

    bullet = _BULLET.match(line)
    if bullet:
        return _block("bulleted_list_item", bullet.group(1))

    numbered = _NUMBERED.match(line)
    if numbered:
        return _block("numbered_list_item", numbered.group(1))

    quote = _QUOTE.match(line)
    if quote:
        return _block("quote", quote.group(1))

    return _block("paragraph", line.strip())


#: Notion accepts nested children in a create request to a limited depth. Beyond this,
#: deeper items are attached to the deepest allowed parent rather than dropped.
MAX_NESTING_DEPTH = 2


def markdown_to_blocks(markdown: str) -> List[Dict[str, Any]]:
    """Convert the formatter's markdown-ish output into Notion blocks, preserving nesting.

    Indentation is structure, not decoration. The formatter is asked to nest supporting
    detail under the point it supports, and the app's editor is a plain text field — so an
    indented "  - " line is the only way a sub-point can exist. Treating every dash as a
    top-level bullet, which this did, threw that away: a carefully nested reflection arrived
    in Notion as one flat list, and the structure the user asked the AI for was silently lost
    at the last step.

    Deliberately conservative about everything else: it recognises the structures the
    formatting prompt actually produces and treats anything unrecognised as a paragraph,
    because an unfamiliar line rendered plainly is always readable.
    """
    blocks: List[Dict[str, Any]] = []
    # (indent width, block) for each open ancestor, outermost first.
    stack: List[Tuple[int, Dict[str, Any]]] = []

    in_code = False
    code_lines: List[str] = []
    code_language = "plain text"

    for raw_line in markdown.splitlines():
        line = raw_line.rstrip()

        if line.strip().startswith("```"):
            if in_code:
                blocks.append(_block("code", "\n".join(code_lines), language=code_language))
                code_lines, in_code = [], False
            else:
                in_code = True
                code_language = line.strip()[3:].strip() or "plain text"
            stack = []
            continue

        if in_code:
            code_lines.append(raw_line)
            continue

        block = _parse_line(line)
        if block is None:
            continue

        indent = _indent_width(raw_line)
        # Headings reset the outline: a sub-point can't belong to a bullet above a heading.
        if block["type"].startswith("heading_"):
            stack = []
            blocks.append(block)
            continue

        while stack and stack[-1][0] >= indent:
            stack.pop()

        if stack and len(stack) <= MAX_NESTING_DEPTH:
            parent = stack[-1][1]
            parent_body = parent[parent["type"]]
            parent_body.setdefault("children", []).append(block)
        else:
            blocks.append(block)

        stack.append((indent, block))

    if in_code and code_lines:
        blocks.append(_block("code", "\n".join(code_lines), language=code_language))

    return blocks


def batched(blocks: List[Dict[str, Any]], size: int = CHILDREN_PER_REQUEST) -> Iterator[List[Dict[str, Any]]]:
    """Yield block batches within Notion's per-request children limit."""
    for start in range(0, len(blocks), size):
        yield blocks[start : start + size]


#: Notion block type per media kind. A photo in a `file` block renders as a download link
#: rather than a picture, which is a worse journal.
_BLOCK_TYPE_FOR_KIND = {"photo": "image", "video": "video", "audio": "audio"}


def file_blocks(files: List[Dict[str, str]]) -> List[Dict[str, Any]]:
    """Blocks embedding already-uploaded files, appended after the entry's text.

    Each entry is ``{"id": file_upload_id, "kind": "photo" | "video"}``.
    """
    blocks: List[Dict[str, Any]] = []
    for item in files:
        block_type = _BLOCK_TYPE_FOR_KIND.get(item.get("kind", "photo"), "file")
        blocks.append(
            {
                "object": "block",
                "type": block_type,
                block_type: {"type": "file_upload", "file_upload": {"id": item["id"]}},
            }
        )
    return blocks


def build_entry_blocks(
    formatted_text: str,
    attached_files: Optional[List[Dict[str, str]]] = None,
) -> List[Dict[str, Any]]:
    """The full block list for one entry: its text, then its media."""
    return markdown_to_blocks(formatted_text) + file_blocks(attached_files or [])
