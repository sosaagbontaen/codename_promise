"""The backend's half of the contract.

The iOS suite proves the client resumes rather than restarts. These prove the server replays
rather than re-writes. Neither is sufficient alone: the duplication bug this whole design
guards against lives in the seam between them.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.blocks import (
    CHILDREN_PER_REQUEST,
    RICH_TEXT_LIMIT,
    batched,
    markdown_to_blocks,
    split_rich_text,
)
from app.config import Settings
from app.connections import InMemoryConnectionStore
from app.main import create_app
from app.services import InMemoryNotion


def make_client(api_key=None):
    notion = InMemoryNotion()
    settings = Settings(api_key=api_key, formatter_version="test-1")
    # An in-memory connection store keeps the suite off the filesystem and off the real
    # Notion gateway, so these tests exercise contracts rather than credentials.
    app = create_app(
        settings=settings, notion=notion, connections=InMemoryConnectionStore()
    )
    return TestClient(app), notion


def entry_body(**overrides):
    body = {
        "page_id": "page-1",
        "formatted_text": "- Ran five miles\n- Fixed the sync bug",
        "attached_file_ids": [],
        "replace_block_ids": [],
    }
    body.update(overrides)
    return body


# --- Idempotency -----------------------------------------------------------------------

class TestIdempotency:
    def test_repeated_key_replays_instead_of_reinserting(self):
        """The headline guarantee. A lost response must not duplicate the entry."""
        client, notion = make_client()
        headers = {"Idempotency-Key": "attempt-1:insert-content"}

        first = client.post("/notion/insert-content", json=entry_body(), headers=headers)
        second = client.post("/notion/insert-content", json=entry_body(), headers=headers)

        assert first.status_code == 200
        assert second.status_code == 200
        assert first.json() == second.json(), "a replay must return the original result"
        assert len(notion.pages["page-1"]["children"]) == 2, "the entry appears once, not twice"

    def test_a_different_key_is_a_different_write(self):
        client, notion = make_client()
        client.post("/notion/insert-content", json=entry_body(),
                    headers={"Idempotency-Key": "attempt-1:insert-content"})
        client.post("/notion/insert-content", json=entry_body(),
                    headers={"Idempotency-Key": "attempt-2:insert-content"})
        assert len(notion.pages["page-1"]["children"]) == 4

    def test_reusing_a_key_with_a_different_body_is_refused(self):
        """A client bug. Silently replaying the first result would hide it."""
        client, _ = make_client()
        headers = {"Idempotency-Key": "attempt-1:insert-content"}

        client.post("/notion/insert-content", json=entry_body(), headers=headers)
        clash = client.post(
            "/notion/insert-content",
            json=entry_body(formatted_text="- Something else entirely"),
            headers=headers,
        )
        assert clash.status_code == 422

    def test_without_a_key_every_call_executes(self):
        client, notion = make_client()
        client.post("/notion/insert-content", json=entry_body())
        client.post("/notion/insert-content", json=entry_body())
        assert len(notion.pages["page-1"]["children"]) == 4

    def test_format_replays(self):
        client, _ = make_client()
        headers = {"Idempotency-Key": "hash-abc:format"}
        body = {"raw_text": "One thing. Another thing.", "draft_id": "d1"}
        first = client.post("/format", json=body, headers=headers)
        second = client.post("/format", json=body, headers=headers)
        assert first.json() == second.json()


# --- Resumption ------------------------------------------------------------------------

class TestResumption:
    def test_replacing_blocks_does_not_leave_the_entry_twice(self):
        """The edit-then-resync path that the client's block IDs exist to support."""
        client, notion = make_client()

        first = client.post("/notion/insert-content", json=entry_body(),
                            headers={"Idempotency-Key": "attempt-1:insert-content"})
        original_ids = first.json()["block_ids"]

        second = client.post(
            "/notion/insert-content",
            json=entry_body(
                formatted_text="- Ran five miles\n- Fixed the sync bug\n- And wrote it up",
                replace_block_ids=original_ids,
            ),
            headers={"Idempotency-Key": "attempt-2:insert-content"},
        )

        assert second.status_code == 200
        assert len(notion.pages["page-1"]["children"]) == 3, "replaced, not appended"
        for old_id in original_ids:
            assert old_id not in notion.blocks

    def test_two_entries_on_one_day_get_separate_pages(self):
        """Page identity is the draft, not the date.

        The original rule reused any page carrying the same date, which merged separate
        entries and — worse — adopted pages the app had never created, including ones the
        user wrote by hand. See ADR-006 (revised).
        """
        client, _ = make_client()
        body = {"entry_date": "2026-08-13", "title": "Morning", "existing_page_id": None}

        first = client.post("/notion/ensure-page", json=body,
                            headers={"Idempotency-Key": "draft-a:ensure-page"})
        second = client.post("/notion/ensure-page", json={**body, "title": "Evening"},
                             headers={"Idempotency-Key": "draft-b:ensure-page"})

        assert first.json()["page_id"] != second.json()["page_id"]

    def test_a_retry_reuses_the_page_it_already_made(self):
        """The idempotency key, not the date, is what stops a retry duplicating."""
        client, _ = make_client()
        body = {"entry_date": "2026-08-13", "title": "Morning", "existing_page_id": None}
        headers = {"Idempotency-Key": "draft-a:ensure-page"}

        first = client.post("/notion/ensure-page", json=body, headers=headers)
        second = client.post("/notion/ensure-page", json=body, headers=headers)
        assert first.json()["page_id"] == second.json()["page_id"]

    def test_a_recorded_page_is_reused_across_attempts(self):
        """And the client's stored page id covers retries beyond the idempotency cache."""
        client, _ = make_client()
        created = client.post(
            "/notion/ensure-page",
            json={"entry_date": "2026-08-13", "title": "Morning", "existing_page_id": None},
            headers={"Idempotency-Key": "attempt-1:ensure-page"},
        ).json()["page_id"]

        again = client.post(
            "/notion/ensure-page",
            json={"entry_date": "2026-08-13", "title": "Morning", "existing_page_id": created},
            headers={"Idempotency-Key": "attempt-2:ensure-page"},
        ).json()["page_id"]

        assert again == created

    def test_a_page_the_app_never_created_is_never_adopted(self):
        """The regression that overwrote a hand-written journal entry."""
        client, notion = make_client()
        # A page that exists in the destination but was not created by this app.
        notion.pages["someone-elses-page"] = {
            "entry_date": "2026-08-13", "title": "My own notes", "children": ["theirs"],
        }

        created = client.post(
            "/notion/ensure-page",
            json={"entry_date": "2026-08-13", "title": None, "existing_page_id": None},
            headers={"Idempotency-Key": "x:ensure-page"},
        ).json()["page_id"]

        assert created != "someone-elses-page"
        assert notion.pages["someone-elses-page"]["children"] == ["theirs"], "untouched"

    def test_entry_date_must_be_a_calendar_day(self):
        client, _ = make_client()
        bad = client.post("/notion/ensure-page",
                          json={"entry_date": "2026-08-13T00:30:00Z", "title": None,
                                "existing_page_id": None})
        assert bad.status_code == 422


# --- Notion's limits -------------------------------------------------------------------

class TestChunking:
    def test_long_paragraphs_are_split_under_the_rich_text_limit(self):
        text = "word " * 900  # ~4500 chars
        parts = split_rich_text(text)
        assert len(parts) > 1
        assert all(len(p["text"]["content"]) <= RICH_TEXT_LIMIT for p in parts)

    def test_splitting_does_not_cut_words_in_half(self):
        text = "alpha bravo charlie " * 200
        rejoined = " ".join(p["text"]["content"].strip() for p in split_rich_text(text))
        assert "alph a" not in rejoined
        assert rejoined.split() == text.split()

    def test_a_hard_run_with_no_spaces_still_splits(self):
        parts = split_rich_text("x" * 5000)
        assert all(len(p["text"]["content"]) <= RICH_TEXT_LIMIT for p in parts)
        assert "".join(p["text"]["content"] for p in parts) == "x" * 5000

    def test_many_blocks_are_batched_within_the_children_limit(self):
        blocks = markdown_to_blocks("\n".join(f"- item {i}" for i in range(250)))
        assert len(blocks) == 250
        batches = list(batched(blocks))
        assert len(batches) == 3
        assert all(len(b) <= CHILDREN_PER_REQUEST for b in batches)

    def test_a_long_entry_syncs_in_multiple_append_calls(self):
        client, notion = make_client()
        long_entry = "\n".join(f"- thing number {i}" for i in range(250))
        response = client.post("/notion/insert-content",
                               json=entry_body(formatted_text=long_entry))
        assert response.status_code == 200
        assert len(response.json()["block_ids"]) == 250
        assert notion.append_calls == 3


# --- Markdown ---------------------------------------------------------------------------

class TestMarkdown:
    @pytest.mark.parametrize(
        "line,expected",
        [
            ("# Heading", "heading_1"),
            ("## Sub", "heading_2"),
            ("### Deeper", "heading_3"),
            ("- bullet", "bulleted_list_item"),
            ("* star bullet", "bulleted_list_item"),
            ("1. numbered", "numbered_list_item"),
            ("> quoted", "quote"),
            ("just a sentence", "paragraph"),
            ("- [ ] unchecked", "to_do"),
            ("- [x] checked", "to_do"),
        ],
    )
    def test_recognised_structures(self, line, expected):
        blocks = markdown_to_blocks(line)
        assert blocks[0]["type"] == expected

    def test_checkbox_state_is_carried(self):
        assert markdown_to_blocks("- [x] done")[0]["to_do"]["checked"] is True
        assert markdown_to_blocks("- [ ] todo")[0]["to_do"]["checked"] is False

    def test_code_fences_survive_intact(self):
        blocks = markdown_to_blocks("```swift\nlet x = 1\nlet y = 2\n```")
        assert blocks[0]["type"] == "code"
        assert blocks[0]["code"]["language"] == "swift"
        assert blocks[0]["code"]["rich_text"][0]["text"]["content"] == "let x = 1\nlet y = 2"

    def test_an_unterminated_fence_still_yields_its_content(self):
        """Dropping text because the model forgot a closing fence would be losing work."""
        blocks = markdown_to_blocks("```\nunclosed content")
        assert blocks[0]["type"] == "code"
        assert "unclosed content" in blocks[0]["code"]["rich_text"][0]["text"]["content"]

    def test_blank_lines_do_not_become_empty_blocks(self):
        assert len(markdown_to_blocks("one\n\n\ntwo")) == 2

    def test_empty_input_is_no_blocks(self):
        assert markdown_to_blocks("") == []


# --- Formatting contract ------------------------------------------------------------------

class TestFormatterContract:
    def test_the_formatter_does_not_change_the_words(self):
        """AI assists, never authors. The reference implementation must model that."""
        client, _ = make_client()
        raw = "Ran five miles. Fixed the sync bug. Felt good about both."
        response = client.post("/format", json={"raw_text": raw, "draft_id": "d1"})
        formatted = response.json()["formatted_text"]

        for sentence in ["Ran five miles.", "Fixed the sync bug.", "Felt good about both."]:
            assert sentence in formatted

    def test_the_response_reports_which_prompt_produced_it(self):
        client, _ = make_client()
        response = client.post("/format", json={"raw_text": "x", "draft_id": "d1"})
        assert response.json()["formatter_version"] == "test-1"


# --- Auth ----------------------------------------------------------------------------------

class TestAuth:
    def test_requests_without_the_key_are_rejected_when_one_is_configured(self):
        client, _ = make_client(api_key="secret")
        assert client.post("/format", json={"raw_text": "x", "draft_id": "d"}).status_code == 401

    def test_the_right_key_is_accepted(self):
        client, _ = make_client(api_key="secret")
        response = client.post(
            "/format",
            json={"raw_text": "x", "draft_id": "d"},
            headers={"Authorization": "Bearer secret"},
        )
        assert response.status_code == 200

    def test_health_reports_whether_auth_is_on(self):
        client, _ = make_client(api_key="secret")
        assert client.get("/health").json()["auth_required"] is True


# --- Input handling --------------------------------------------------------------------------

class TestUploads:
    def test_empty_audio_is_rejected_rather_than_transcribed(self):
        client, _ = make_client()
        response = client.post("/stt", files={"audio": ("empty.m4a", b"", "audio/m4a")})
        assert response.status_code == 400

    def test_transcription_replays_on_the_same_key(self):
        client, _ = make_client()
        headers = {"Idempotency-Key": "capture-1:stt"}
        files = {"audio": ("a.m4a", b"\x00\x01\x02\x03", "audio/m4a")}
        first = client.post("/stt", files=files, headers=headers)
        second = client.post("/stt", files={"audio": ("a.m4a", b"\x00\x01\x02\x03", "audio/m4a")},
                             headers=headers)
        assert first.status_code == 200
        assert first.json() == second.json()

    def test_file_upload_returns_an_id(self):
        client, _ = make_client()
        response = client.post(
            "/notion/upload-file",
            files={"file": ("photo.jpg", b"\xff\xd8\xff", "image/jpeg")},
            data={"media_id": "11111111-1111-1111-1111-111111111111"},
        )
        assert response.status_code == 200
        assert response.json()["file_id"].startswith("file-")


class TestMediaBlocks:
    """Uploaded files become the right kind of block.

    A photo in a generic `file` block renders as a download link rather than a picture, so
    the media kind has to travel with the upload id.
    """

    def test_a_photo_becomes_an_image_block(self):
        from app.blocks import file_blocks

        block = file_blocks([{"id": "f1", "kind": "photo"}])[0]
        assert block["type"] == "image"
        assert block["image"] == {"type": "file_upload", "file_upload": {"id": "f1"}}

    def test_a_video_becomes_a_video_block(self):
        from app.blocks import file_blocks

        block = file_blocks([{"id": "f2", "kind": "video"}])[0]
        assert block["type"] == "video"
        assert block["video"]["file_upload"]["id"] == "f2"

    def test_an_unknown_kind_falls_back_to_a_file_block(self):
        from app.blocks import file_blocks

        assert file_blocks([{"id": "f3", "kind": "spreadsheet"}])[0]["type"] == "file"

    def test_media_blocks_follow_the_entry_text(self):
        from app.blocks import build_entry_blocks

        blocks = build_entry_blocks("- one\n- two", [{"id": "f1", "kind": "photo"}])
        assert [b["type"] for b in blocks] == ["bulleted_list_item", "bulleted_list_item", "image"]

    def test_insert_content_accepts_files_with_kinds(self):
        client, notion = make_client()
        response = client.post("/notion/insert-content", json={
            "page_id": "page-1",
            "formatted_text": "- a day",
            "attached_files": [{"id": "f1", "kind": "video"}],
            "replace_block_ids": [],
        })
        assert response.status_code == 200
        types = [notion.blocks[b]["type"] for b in response.json()["block_ids"]]
        assert "video" in types

    def test_bare_ids_still_work_and_are_treated_as_photos(self):
        """Kept so an older client build doesn't break mid-upgrade."""
        client, notion = make_client()
        response = client.post("/notion/insert-content", json={
            "page_id": "page-1",
            "formatted_text": "- a day",
            "attached_file_ids": ["f9"],
            "replace_block_ids": [],
        })
        assert response.status_code == 200
        types = [notion.blocks[b]["type"] for b in response.json()["block_ids"]]
        assert "image" in types


class TestUploadLimits:
    """Notion caps file size by workspace plan — 5 MiB on free, verified live:
    "File size of 5.5 MiB exceeds the limit of 5 MiB."

    The guard originally used 20MB, which is Notion's *multi-part protocol* threshold and a
    completely different number. So 5–20MB files skipped the check, reached Notion, and came
    back as a generic 400 the client treats as retryable — retrying a file that can never fit.
    """

    def _upload(self, size_mb, limit_mb=5.0, name="clip.mp4"):
        import asyncio

        from app.providers.notion_api import NotionGatewayHTTP

        gateway = NotionGatewayHTTP(
            access_token="t", database_id="db",
            max_upload_bytes=int(limit_mb * 1024 * 1024),
        )
        data = b"x" * int(size_mb * 1024 * 1024)
        return asyncio.run(gateway.upload_file(data, name, "m1"))

    def test_a_file_just_over_the_plan_limit_is_refused(self):
        from app.providers.notion_api import NotionUploadTooLarge

        with pytest.raises(NotionUploadTooLarge) as caught:
            self._upload(5.5)
        assert "5.5MB" in str(caught.value)
        assert "5MB limit" in str(caught.value)

    def test_the_gap_between_the_plan_limit_and_multipart_is_covered(self):
        """The band that used to slip through and fail opaquely at Notion."""
        from app.providers.notion_api import NotionUploadTooLarge

        with pytest.raises(NotionUploadTooLarge):
            self._upload(12)

    def test_the_message_says_the_entry_still_synced(self):
        from app.providers.notion_api import NotionUploadTooLarge

        with pytest.raises(NotionUploadTooLarge) as caught:
            self._upload(9)
        assert "text synced" in str(caught.value)

    def test_a_paid_workspace_can_raise_the_limit(self):
        """Refused for the right reason — it gets past the size guard and tries the network."""
        from app.providers.notion_api import NotionError

        with pytest.raises(NotionError) as caught:
            self._upload(9, limit_mb=50)
        assert "too large" not in str(caught.value).lower()

    def test_an_oversized_upload_is_permanent_not_retryable(self):
        """422, so the client stops. A 5xx would have it retry a file that can never fit."""
        from app.connections import InMemoryConnectionStore
        from app.providers.notion_api import NotionUploadTooLarge
        from app.vocabulary import InMemoryVocabularyStore

        class Refusing:
            async def upload_file(self, data, filename, media_id):
                raise NotionUploadTooLarge("too big")

            async def ensure_page(self, *a, **k): return "p1"
            async def replace_children(self, *a, **k): return []
            async def update_properties(self, *a, **k): return None

        app = create_app(
            settings=Settings(), notion=Refusing(),
            connections=InMemoryConnectionStore(), vocabulary=InMemoryVocabularyStore(),
        )
        response = TestClient(app).post(
            "/notion/upload-file",
            files={"file": ("big.mp4", b"xx", "video/mp4")},
            data={"media_id": "m1"},
        )
        assert response.status_code == 422


class TestNesting:
    """Indentation is structure, not decoration.

    The formatter is asked to nest supporting detail under the point it supports, and the
    app's editor is a plain text field — so an indented "  - " line is the only way a
    sub-point can exist. Flattening every dash to a top-level bullet discarded exactly the
    structure the user asked the AI to produce.
    """

    def test_an_indented_bullet_becomes_a_child(self):
        from app.blocks import markdown_to_blocks

        blocks = markdown_to_blocks("- parent\n  - child")
        assert len(blocks) == 1
        children = blocks[0]["bulleted_list_item"]["children"]
        assert len(children) == 1
        assert children[0]["bulleted_list_item"]["rich_text"][0]["text"]["content"] == "child"

    def test_siblings_stay_siblings(self):
        from app.blocks import markdown_to_blocks

        blocks = markdown_to_blocks("- one\n- two\n- three")
        assert len(blocks) == 3
        assert all("children" not in b["bulleted_list_item"] for b in blocks)

    def test_two_levels_of_nesting(self):
        from app.blocks import markdown_to_blocks

        blocks = markdown_to_blocks("- a\n  - b\n    - c")
        b = blocks[0]["bulleted_list_item"]["children"][0]
        c = b["bulleted_list_item"]["children"][0]
        assert c["bulleted_list_item"]["rich_text"][0]["text"]["content"] == "c"

    def test_dedenting_returns_to_the_outer_level(self):
        from app.blocks import markdown_to_blocks

        blocks = markdown_to_blocks("- a\n  - a1\n- b")
        assert len(blocks) == 2
        assert len(blocks[0]["bulleted_list_item"]["children"]) == 1
        assert "children" not in blocks[1]["bulleted_list_item"]

    def test_tabs_indent_like_spaces(self):
        from app.blocks import markdown_to_blocks

        blocks = markdown_to_blocks("- parent\n\t- child")
        assert len(blocks) == 1
        assert "children" in blocks[0]["bulleted_list_item"]

    def test_a_heading_resets_the_outline(self):
        """A sub-point can't belong to a bullet from before a heading."""
        from app.blocks import markdown_to_blocks

        blocks = markdown_to_blocks("- a\n# Heading\n  - b")
        assert [b["type"] for b in blocks] == ["bulleted_list_item", "heading_1",
                                               "bulleted_list_item"]

    def test_nothing_is_lost_when_nesting_goes_too_deep(self):
        from app.blocks import markdown_to_blocks

        def count(blocks):
            total = 0
            for block in blocks:
                total += 1
                total += count(block[block["type"]].get("children", []))
            return total

        assert count(markdown_to_blocks("- a\n  - b\n    - c\n      - d\n        - e")) == 5

    def test_a_flat_entry_is_unchanged(self):
        from app.blocks import markdown_to_blocks

        blocks = markdown_to_blocks("- one\n- two")
        assert len(blocks) == 2
