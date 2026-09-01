"""Word preservation, OAuth, and database selection."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.connections import InMemoryConnectionStore, NotionConnection
from app.main import create_app
from app.oauth import NotionOAuth, OAuthStateError, StateStore
from app.providers.notion_api import classify_blocks
from app.services import InMemoryNotion
from app.wordguard import (
    FormattingAlteredWordsError,
    dropped_words,
    introduced_words,
    verify_preserves_wording,
)

RAW = "Ran five miles this morning. Fixed the sync bug. Felt good about both."


# --- The guard on "AI assists, never authors" ---------------------------------------------

class TestWordGuard:
    def test_pure_restructuring_passes(self):
        formatted = "- Ran five miles this morning.\n- Fixed the sync bug.\n- Felt good about both."
        verify_preserves_wording(RAW, formatted)

    def test_reordering_passes(self):
        formatted = "- Fixed the sync bug.\n- Ran five miles this morning.\n- Felt good about both."
        verify_preserves_wording(RAW, formatted)

    def test_nesting_and_repetition_pass(self):
        """Repeating a word the author used is regrouping, not authoring."""
        formatted = "- Ran five miles this morning.\n  - Felt good\n- Fixed the sync bug."
        # "about both" is dropped here, which the guard catches — so assert on the direction
        # we mean rather than the whole check.
        assert introduced_words(RAW, formatted) == set()

    def test_paraphrasing_is_caught(self):
        formatted = "- Went for a jog\n- Resolved a defect"
        with pytest.raises(FormattingAlteredWordsError) as caught:
            verify_preserves_wording(RAW, formatted)
        assert "jog" in caught.value.invented

    def test_a_helpful_heading_is_still_authoring(self):
        """The most likely real failure: a model adding a friendly title."""
        formatted = "# Highlights\n- Ran five miles this morning.\n- Fixed the sync bug.\n- Felt good about both."
        with pytest.raises(FormattingAlteredWordsError):
            verify_preserves_wording(RAW, formatted)

    def test_summarising_is_caught(self):
        formatted = "- Ran five miles this morning."
        with pytest.raises(FormattingAlteredWordsError) as caught:
            verify_preserves_wording(RAW, formatted)
        assert "bug" in caught.value.lost

    def test_markdown_markers_are_not_words(self):
        assert introduced_words("hello world", "- hello\n- world") == set()
        assert introduced_words("hello world", "> hello **world**") == set()

    def test_list_numbering_is_allowed(self):
        assert introduced_words("alpha beta", "1. alpha\n2. beta") == set()

    def test_case_and_punctuation_changes_are_tolerated(self):
        """Splitting a sentence changes punctuation; that is structure, not wording."""
        assert introduced_words("one thing. two things", "- One thing\n- Two things") == set()

    def test_dropped_words_reports_the_difference(self):
        assert dropped_words("alpha beta gamma", "alpha gamma") == {"beta"}


class TestFormattingEndpointGuard:
    def _client(self, formatter):
        return TestClient(create_app(settings=Settings(formatter_version="test-1"), formatter=formatter))

    def test_altered_wording_is_rejected_as_permanent(self):
        """422 so the client stops rather than retrying a model that will paraphrase again."""

        class Paraphraser:
            async def format(self, raw_text: str, protected=()) -> str:
                from app.wordguard import verify_preserves_wording

                out = "- Went jogging"
                verify_preserves_wording(raw_text, out)
                return out

        response = self._client(Paraphraser()).post(
            "/format", json={"raw_text": RAW, "draft_id": "d1"}
        )
        assert response.status_code == 422
        assert "wording" in response.json()["detail"].lower()

    def test_faithful_formatting_is_accepted(self):
        class Faithful:
            async def format(self, raw_text: str, protected=()) -> str:
                return "\n".join(f"- {s.strip()}" for s in raw_text.split(". ") if s.strip())

        response = self._client(Faithful()).post(
            "/format", json={"raw_text": RAW, "draft_id": "d1"}
        )
        assert response.status_code == 200


# --- OAuth ---------------------------------------------------------------------------------

class TestOAuthState:
    def test_state_is_single_use(self):
        states = StateStore()
        state = states.issue()
        states.consume(state)
        with pytest.raises(OAuthStateError):
            states.consume(state)

    def test_unknown_state_is_rejected(self):
        with pytest.raises(OAuthStateError):
            StateStore().consume("not-a-real-state")

    def test_missing_state_is_rejected(self):
        with pytest.raises(OAuthStateError):
            StateStore().consume(None)

    def test_expired_state_is_rejected(self):
        states = StateStore(ttl_seconds=-1)
        state = states.issue()
        with pytest.raises(OAuthStateError):
            states.consume(state)

    def test_authorization_url_carries_the_expected_parameters(self):
        oauth = NotionOAuth("client-1", "secret-1", "http://localhost:8000/cb")
        url = oauth.authorization_url()
        assert url.startswith("https://api.notion.com/v1/oauth/authorize?")
        for fragment in ["client_id=client-1", "response_type=code", "owner=user", "state="]:
            assert fragment in url

    def test_unconfigured_oauth_reports_itself(self):
        assert NotionOAuth(None, None, None).is_configured is False


class TestConnectionEndpoints:
    def _client(self, connection=None, **settings_kwargs):
        settings = Settings(
            notion_client_id="cid",
            notion_client_secret="secret",
            notion_redirect_uri="http://localhost:8000/notion/oauth/callback",
            **settings_kwargs,
        )
        store = InMemoryConnectionStore(connection)
        app = create_app(settings=settings, connections=store)
        return TestClient(app, follow_redirects=False), store

    def test_status_is_disconnected_before_sign_in(self):
        client, _ = self._client()
        body = client.get("/notion/connection").json()
        assert body["connected"] is False
        assert body["configurable"] is True

    def test_sign_in_redirects_to_notion(self):
        client, _ = self._client()
        response = client.get("/notion/oauth/start")
        assert response.status_code == 307
        assert response.headers["location"].startswith("https://api.notion.com/v1/oauth/authorize")

    def test_sign_in_is_unavailable_without_integration_credentials(self):
        app = create_app(settings=Settings(), connections=InMemoryConnectionStore())
        response = TestClient(app, follow_redirects=False).get("/notion/oauth/start")
        assert response.status_code == 503

    def test_a_declined_sign_in_is_not_an_error(self):
        client, store = self._client()
        response = client.get("/notion/oauth/callback", params={"error": "access_denied"})
        assert response.status_code == 200
        assert store.get() is None

    def test_a_callback_with_an_unknown_state_is_refused(self):
        client, _ = self._client()
        response = client.get("/notion/oauth/callback", params={"code": "abc", "state": "forged"})
        assert response.status_code == 400

    def test_the_token_is_never_returned_to_the_client(self):
        connection = NotionConnection(
            access_token="secret-token-do-not-leak",
            workspace_id="ws",
            workspace_name="My Workspace",
            database_id="db-1",
        )
        client, _ = self._client(connection)
        body = client.get("/notion/connection").text
        assert "secret-token-do-not-leak" not in body
        assert "My Workspace" in body

    def test_status_distinguishes_connected_from_ready(self):
        """Authorised but no database chosen yet is a real, distinct state."""
        client, _ = self._client(NotionConnection(access_token="t", workspace_id="ws"))
        body = client.get("/notion/connection").json()
        assert body["connected"] is True
        assert body["ready"] is False

    def test_listing_databases_requires_a_connection(self):
        client, _ = self._client()
        assert client.get("/notion/databases").status_code == 409

    def test_disconnecting_forgets_the_token(self):
        client, store = self._client(NotionConnection(access_token="t", workspace_id="ws"))
        assert client.delete("/notion/connection").status_code == 200
        assert store.get() is None


class TestDatabaseSelection:
    def _app(self, resolved, connection=None):
        from app import routes_notion_auth

        class FakeGateway:
            def __init__(self, **kwargs):
                pass

            async def resolve_properties(self):
                return resolved

        async def fake_lister(token, base_url=None):
            return [{"id": "db-1", "title": "Journal"}, {"id": "db-2", "title": "Scratch"}]

        settings = Settings(
            notion_client_id="cid",
            notion_client_secret="s",
            notion_redirect_uri="http://localhost/cb",
        )
        store = InMemoryConnectionStore(
            connection or NotionConnection(access_token="t", workspace_id="ws")
        )
        app = create_app(settings=settings, connections=store)
        # Replace the router with one wired to fakes.
        app.router.routes = [r for r in app.router.routes if not getattr(r, "path", "").startswith("/notion/")]
        app.include_router(
            routes_notion_auth.build_router(
                oauth=NotionOAuth("cid", "s", "http://localhost/cb"),
                store=store,
                app_return_url="app://done",
                database_lister=fake_lister,
                gateway_factory=FakeGateway,
            )
        )
        return TestClient(app), store

    def test_choosing_a_database_records_its_resolved_columns(self):
        client, store = self._app({"title_property": "Name", "date_property": "When"})
        response = client.post("/notion/database", json={"database_id": "db-1"})

        assert response.status_code == 200
        assert response.json()["ready"] is True
        connection = store.get()
        assert connection.database_id == "db-1"
        assert connection.database_title == "Journal"
        assert connection.title_property == "Name"
        assert connection.date_property == "When"

    def test_a_database_without_a_date_column_is_refused_at_pick_time(self):
        """Fail where the user is looking at a picker, not mid-sync."""
        client, store = self._app({"title_property": "Name", "date_property": None})
        response = client.post("/notion/database", json={"database_id": "db-1"})

        assert response.status_code == 422
        assert "date" in response.json()["detail"].lower()
        assert store.get().database_id is None, "a refused choice must not be persisted"


class TestProviderSelection:
    def test_health_reports_stubs_when_nothing_is_configured(self):
        client = TestClient(create_app(settings=Settings(), connections=InMemoryConnectionStore()))
        body = client.get("/health").json()
        assert body["transcription"] == "stub"
        assert body["notion"] == "stub"
        assert body["notion_oauth_configured"] is False

    def test_health_reports_groq_when_a_key_is_present(self):
        client = TestClient(
            create_app(
                settings=Settings(groq_api_key="test-key-not-real"),
                connections=InMemoryConnectionStore(),
            )
        )
        body = client.get("/health").json()
        assert body["transcription"] == "groq"
        assert body["formatting"] == "groq"


class TestEnvironmentNormalisation:
    """Sourcing a .env exports blanks rather than leaving variables unset.

    `CP_API_KEY=` used to arrive as `""`, which `is not None` treats as configured — auth
    switched on with an empty expected token, and the app was locked out of a server whose
    /health said everything was fine.
    """

    def test_a_blank_api_key_does_not_enable_auth(self, monkeypatch):
        monkeypatch.setenv("CP_API_KEY", "")
        assert Settings.from_env().requires_auth is False

    def test_a_whitespace_api_key_does_not_enable_auth(self, monkeypatch):
        monkeypatch.setenv("CP_API_KEY", "   ")
        assert Settings.from_env().requires_auth is False

    def test_a_real_api_key_does_enable_auth(self, monkeypatch):
        monkeypatch.setenv("CP_API_KEY", "an-actual-key")
        assert Settings.from_env().requires_auth is True

    def test_a_blank_groq_key_leaves_the_stubs_in_place(self, monkeypatch):
        monkeypatch.setenv("GROQ_API_KEY", "")
        assert Settings.from_env().has_groq is False

    def test_blank_notion_credentials_are_not_configured(self, monkeypatch):
        for name in ("NOTION_CLIENT_ID", "NOTION_CLIENT_SECRET", "NOTION_REDIRECT_URI"):
            monkeypatch.setenv(name, "")
        settings = Settings.from_env()
        assert NotionOAuth(
            settings.notion_client_id,
            settings.notion_client_secret,
            settings.notion_redirect_uri,
        ).is_configured is False

    def test_a_blank_model_override_falls_back_to_the_default(self, monkeypatch):
        monkeypatch.setenv("CP_FORMATTING_MODEL", "")
        assert Settings.from_env().formatting_model == "llama-3.3-70b-versatile"

    def test_values_are_trimmed(self, monkeypatch):
        monkeypatch.setenv("CP_API_KEY", "  padded-key  ")
        assert Settings.from_env().api_key == "padded-key"


class TestFormatterRetry:
    """The corrective retry.

    Models intermittently drop short standalone lines — a bare "Howdy" gets judged as noise
    — even at temperature 0. Naming the exact missing words back to the model recovers it;
    re-rolling the identical request mostly does not.
    """

    def _formatter(self, outputs):
        from app.providers.groq import GroqFormatter

        class Scripted(GroqFormatter):
            def __init__(self):
                super().__init__(api_key="not-a-real-key")
                self.calls = []

            async def complete(self, messages):
                self.calls.append(messages)
                return outputs[len(self.calls) - 1]

        return Scripted()

    RAW = "Howdy\n- went to the airport\n- bought eggs"

    def test_a_faithful_first_attempt_is_not_retried(self):
        import asyncio

        formatter = self._formatter(["- Howdy\n- went to the airport\n- bought eggs"])
        result = asyncio.run(formatter.format(self.RAW))
        assert len(formatter.calls) == 1
        assert "Howdy" in result

    def test_a_dropped_word_triggers_one_corrective_retry(self):
        import asyncio

        formatter = self._formatter([
            "- went to the airport\n- bought eggs",                    # drops "Howdy"
            "- Howdy\n- went to the airport\n- bought eggs",           # corrected
        ])
        result = asyncio.run(formatter.format(self.RAW))

        assert len(formatter.calls) == 2
        assert "Howdy" in result
        # The retry must name the actual missing word, not just say "try again".
        correction = formatter.calls[1][-1]["content"]
        assert "howdy" in correction.lower()

    def test_a_second_failure_is_not_retried_again(self):
        import asyncio

        from app.wordguard import FormattingAlteredWordsError

        formatter = self._formatter([
            "- went to the airport\n- bought eggs",
            "- went to the airport\n- bought eggs",
        ])
        with pytest.raises(FormattingAlteredWordsError):
            asyncio.run(formatter.format(self.RAW))
        assert len(formatter.calls) == 2, "one retry, not an unbounded loop"

    def test_added_words_are_named_in_the_correction(self):
        import asyncio

        formatter = self._formatter([
            "# Summary\n- Howdy\n- went to the airport\n- bought eggs",
            "- Howdy\n- went to the airport\n- bought eggs",
        ])
        asyncio.run(formatter.format(self.RAW))
        correction = formatter.calls[1][-1]["content"]
        assert "summary" in correction.lower()

    def test_the_guard_can_be_disabled_for_debugging(self):
        import asyncio

        from app.providers.groq import GroqFormatter

        class Scripted(GroqFormatter):
            def __init__(self):
                super().__init__(api_key="not-a-real-key", enforce_wording=False)

            async def complete(self, messages):
                return "- totally different words"

        assert asyncio.run(Scripted().format(self.RAW)) == "- totally different words"


class TestTypoCorrection:
    """Corrections are allowed; rewrites are not.

    The line between them is string similarity: a word you can still recognise is a fix, a
    different word is the model editorialising.
    """

    def test_a_doubled_letter_typo_is_corrected(self):
        from app.wordguard import analyse

        result = analyse("how softwaaarre engineers work", "- how software engineers work")
        assert result.is_acceptable
        assert ("softwaaarre", "software") in result.corrections

    def test_a_stray_keystroke_is_corrected(self):
        from app.wordguard import analyse

        result = analyse("the engqchineers are cooked", "- the engineers are cooked")
        assert result.is_acceptable

    def test_run_together_words_may_be_separated(self):
        from app.wordguard import analyse

        result = analyse(
            "Sinceqwhendideggsbecomesoexpensive?",
            "- Since when did eggs become so expensive?",
        )
        assert result.is_acceptable, f"invented={result.invented} lost={result.lost}"

    def test_a_synonym_is_still_a_rewrite(self):
        from app.wordguard import analyse

        result = analyse("ran five miles", "- jogged five miles")
        assert not result.is_acceptable
        assert "jogged" in result.invented

    def test_dropping_a_line_is_still_summarising(self):
        from app.wordguard import analyse

        result = analyse("Howdy\nbought eggs", "- bought eggs")
        assert not result.is_acceptable
        assert "howdy" in result.lost


class TestProtectedVocabulary:
    """Names and slang look exactly like typos. The user gets to say otherwise."""

    def test_a_protected_name_may_not_be_corrected(self):
        from app.wordguard import analyse

        # Without protection this passes as a typo fix — "Amaka" -> "Amaya" is a close match.
        assert analyse("saw Amaka today", "- saw Amaya today").is_acceptable

        result = analyse("saw Amaka today", "- saw Amaya today", protected=["Amaka"])
        assert not result.is_acceptable
        assert "amaka" in result.violated_protected

    def test_a_protected_term_used_correctly_passes(self):
        from app.wordguard import analyse

        result = analyse("wagwan blud", "- wagwan blud", protected=["wagwan"])
        assert result.is_acceptable

    def test_protected_terms_may_be_multi_word(self):
        from app.wordguard import analyse

        result = analyse(
            "went to Osa Board today", "- went to Osa Bored today", protected=["Osa Board"]
        )
        assert not result.is_acceptable
        assert "board" in result.violated_protected

    def test_the_error_names_the_protected_word(self):
        from app.wordguard import FormattingAlteredWordsError, verify_preserves_wording

        with pytest.raises(FormattingAlteredWordsError) as caught:
            verify_preserves_wording("saw Amaka", "- saw Amaya", protected=["Amaka"])
        assert "marked as correct" in str(caught.value)
        assert "amaka" in str(caught.value)


class TestVocabularyEndpoints:
    def _client(self):
        from app.connections import InMemoryConnectionStore
        from app.vocabulary import InMemoryVocabularyStore

        store = InMemoryVocabularyStore()
        app = create_app(
            settings=Settings(formatter_version="test-1"),
            connections=InMemoryConnectionStore(),
            vocabulary=store,
        )
        return TestClient(app), store

    def test_terms_start_empty(self):
        client, _ = self._client()
        assert client.get("/vocabulary").json()["terms"] == []

    def test_a_term_can_be_added_and_removed(self):
        client, _ = self._client()
        assert client.post("/vocabulary", json={"term": "wagwan"}).json()["terms"] == ["wagwan"]
        assert client.delete("/vocabulary/wagwan").json()["terms"] == []

    def test_adding_is_case_insensitively_deduped_but_keeps_your_capitalisation(self):
        client, _ = self._client()
        client.post("/vocabulary", json={"term": "Amaka"})
        terms = client.post("/vocabulary", json={"term": "amaka"}).json()["terms"]
        assert terms == ["Amaka"]

    def test_removal_is_case_insensitive(self):
        client, _ = self._client()
        client.post("/vocabulary", json={"term": "Amaka"})
        assert client.delete("/vocabulary/AMAKA").json()["terms"] == []

    def test_blank_terms_are_ignored(self):
        client, _ = self._client()
        assert client.post("/vocabulary", json={"term": "   "}).json()["terms"] == []

    def test_format_reports_the_corrections_it_made(self):
        """How the user discovers a word worth protecting."""
        from app.connections import InMemoryConnectionStore
        from app.vocabulary import InMemoryVocabularyStore
        from app.wordguard import verify_preserves_wording

        class Corrector:
            async def format(self, raw_text, protected=()):
                out = "- how software engineers work"
                self.last_analysis = verify_preserves_wording(raw_text, out, protected)
                return out

        app = create_app(
            settings=Settings(formatter_version="test-1"),
            formatter=Corrector(),
            connections=InMemoryConnectionStore(),
            vocabulary=InMemoryVocabularyStore(),
        )
        response = TestClient(app).post(
            "/format", json={"raw_text": "how softwaaarre engineers work", "draft_id": "d"}
        )
        corrections = response.json()["corrections"]
        assert {"original": "softwaaarre", "replacement": "software"} in corrections

    def test_protected_terms_reach_the_formatter(self):
        from app.connections import InMemoryConnectionStore
        from app.vocabulary import InMemoryVocabularyStore

        seen = {}

        class Spy:
            async def format(self, raw_text, protected=()):
                seen["protected"] = list(protected)
                return raw_text

        store = InMemoryVocabularyStore(["wagwan"])
        app = create_app(
            settings=Settings(formatter_version="t"),
            formatter=Spy(),
            connections=InMemoryConnectionStore(),
            vocabulary=store,
        )
        TestClient(app).post("/format", json={"raw_text": "wagwan", "draft_id": "d"})
        assert seen["protected"] == ["wagwan"]


class TestCorrectionToAWordAlreadyPresent:
    """The case that made the guard misdiagnose a typo fix as a deletion.

    If the author wrote both "software" and "softwaaarre", correcting the typo produces a
    word that was already in the text. A set difference sees only that "softwaaarre"
    vanished, calls it a deletion, and the retry then asks the model to restore a word it
    never removed.
    """

    RAW = "the future of software and how softwaaarre engineers work"

    def test_a_typo_fixed_to_an_existing_word_is_recognised(self):
        from app.wordguard import analyse

        result = analyse(self.RAW, "- the future of software and how software engineers work")
        assert result.is_acceptable, f"lost={result.lost} invented={result.invented}"
        assert ("softwaaarre", "software") in result.corrections

    def test_a_genuine_deletion_is_still_caught(self):
        from app.wordguard import analyse

        result = analyse("Howdy\nbought eggs and milk", "- bought eggs")
        assert not result.is_acceptable
        assert "milk" in result.lost

    def test_a_paraphrase_alongside_a_typo_fix_is_still_caught(self):
        """Both happened at once in practice: softwaaarre->software and cooked->affected."""
        from app.wordguard import analyse

        result = analyse(
            "how softwaaarre engineers might be cooked",
            "- how software engineers might be affected",
        )
        assert not result.is_acceptable
        assert "affected" in result.invented
        assert "cooked" in result.lost
        assert ("softwaaarre", "software") in result.corrections


class TestPageListing:
    """The picker behind "add to an existing entry"."""

    def _app(self, ready=True):
        from app import routes_notion_auth
        from app.connections import InMemoryConnectionStore, NotionConnection
        from app.vocabulary import InMemoryVocabularyStore

        async def fake_pages(token, database_id, limit=50, base_url=None):
            return [
                {"id": "p1", "title": "Tuesday", "entry_date": "2026-08-12",
                 "last_edited_time": "2026-08-12T10:00:00Z"},
                {"id": "p2", "title": "Wednesday", "entry_date": "2026-08-13",
                 "last_edited_time": "2026-08-13T10:00:00Z"},
            ]

        connection = NotionConnection(
            access_token="t", workspace_id="ws",
            database_id="db-1" if ready else None,
        )
        store = InMemoryConnectionStore(connection)
        app = create_app(
            settings=Settings(notion_client_id="c", notion_client_secret="s",
                              notion_redirect_uri="http://localhost/cb"),
            connections=store,
            vocabulary=InMemoryVocabularyStore(),
        )
        app.router.routes = [
            r for r in app.router.routes if not getattr(r, "path", "").startswith("/notion/")
        ]
        app.include_router(
            routes_notion_auth.build_router(
                oauth=NotionOAuth("c", "s", "http://localhost/cb"),
                store=store, app_return_url="app://done",
                page_lister=fake_pages,
            )
        )
        return TestClient(app)

    def test_pages_are_listed_for_the_picker(self):
        body = self._app().get("/notion/pages").json()
        assert [p["title"] for p in body["pages"]] == ["Tuesday", "Wednesday"]

    def test_listing_carries_the_date_so_entries_are_recognisable(self):
        body = self._app().get("/notion/pages").json()
        assert body["pages"][0]["entry_date"] == "2026-08-12"

    def test_listing_never_returns_page_content(self):
        """Appending must not need to read the page — that's what makes it lossless."""
        body = self._app().get("/notion/pages").json()
        for page in body["pages"]:
            assert set(page) == {"id", "title", "entry_date", "last_edited_time"}

    def test_listing_requires_a_chosen_database(self):
        assert self._app(ready=False).get("/notion/pages").status_code == 409


class TestLongEntryChunking:
    """Long reflections were the ones that failed.

    Asked to restructure two thousand words, the model drifts somewhere in the middle, the
    guard correctly rejects the whole response, and the user gets a 422 on exactly the entry
    they most wanted help with — then pastes it into ChatGPT instead.
    """

    def _formatter(self, outputs, threshold=1200):
        from app.providers.groq import GroqFormatter

        class Scripted(GroqFormatter):
            def __init__(self):
                super().__init__(api_key="not-a-real-key")
                self.CHUNK_THRESHOLD = threshold
                self.calls = []

            async def complete(self, messages):
                self.calls.append(messages[-1]["content"])
                return outputs[min(len(self.calls) - 1, len(outputs) - 1)]

        return Scripted()

    def test_a_short_entry_is_sent_in_one_piece(self):
        import asyncio

        formatter = self._formatter(["- short"])
        asyncio.run(formatter.format("short"))
        assert len(formatter.calls) == 1

    def test_a_long_entry_is_split_on_the_author_s_own_paragraph_breaks(self):
        from app.providers.groq import _split_for_formatting

        text = "\n\n".join(["para " + "word " * 60 for _ in range(5)])
        chunks = _split_for_formatting(text, 400)

        assert len(chunks) > 1
        # Nothing is invented or lost by splitting.
        assert "".join(chunks).split() == text.split()

    def test_splitting_never_cuts_a_paragraph_in_half(self):
        from app.providers.groq import _split_for_formatting

        text = "alpha\n\nbravo\n\ncharlie"
        for chunk in _split_for_formatting(text, 8):
            assert chunk.strip() in {"alpha", "bravo", "charlie"}

    def test_one_bad_chunk_keeps_its_own_words_instead_of_failing_the_entry(self):
        """Partial structure with the author's exact words beats a 422 on the whole thing."""
        import asyncio

        # First chunk formats fine; the second paraphrases on both attempts.
        formatter = self._formatter(
            ["- alpha", "- something else entirely", "- something else entirely"],
            threshold=10,
        )
        result = asyncio.run(formatter.format("alpha\n\nbravo"))

        assert "alpha" in result
        assert "bravo" in result, "the author's own words survive a chunk that couldn't format"
        assert formatter.chunks_left_unformatted == 1

    def test_a_single_unsplittable_block_still_goes_through(self):
        from app.providers.groq import _split_for_formatting

        text = "word" * 500  # no blank lines, no newlines
        assert _split_for_formatting(text, 100) == [text]


class TestEntryDays:
    """Answering "which days am I missing" needs the destination, not just the device.

    Someone arriving with years of journal in Notion has a history the app has never seen, so
    a local-only answer would tell them they skipped weeks they actually wrote.
    """

    def _app(self, days_by_page):
        from app import routes_notion_auth

        class FakeGateway:
            def __init__(self, *args, **kwargs):
                pass

        async def fake_day_lister(access_token, database_id, date_property, start, end):
            assert date_property == "When", "the configured date column must be used"
            return sorted({d for d in days_by_page if start <= d <= end})

        settings = Settings(
            notion_client_id="cid",
            notion_client_secret="s",
            notion_redirect_uri="http://localhost/cb",
        )
        store = InMemoryConnectionStore(
            NotionConnection(
                access_token="t",
                workspace_id="ws",
                database_id="db-1",
                title_property="Name",
                date_property="When",
            )
        )
        app = create_app(settings=settings, connections=store)
        app.router.routes = [
            r for r in app.router.routes if not getattr(r, "path", "").startswith("/notion/")
        ]
        app.include_router(
            routes_notion_auth.build_router(
                oauth=NotionOAuth("cid", "s", "http://localhost/cb"),
                store=store,
                app_return_url="app://done",
                gateway_factory=FakeGateway,
                day_lister=fake_day_lister,
            )
        )
        return TestClient(app)

    def test_returns_the_days_that_have_a_page(self):
        client = self._app(["2026-08-02", "2026-08-04", "2026-09-01"])

        response = client.get(
            "/notion/entry-days", params={"start": "2026-08-01", "end": "2026-08-31"}
        )

        assert response.status_code == 200
        assert response.json() == {"days": ["2026-08-02", "2026-08-04"]}

    def test_returns_dates_only_and_never_content(self):
        """Whether a day is written must not require reading what was written."""
        client = self._app(["2026-08-02"])

        body = client.get(
            "/notion/entry-days", params={"start": "2026-08-01", "end": "2026-08-31"}
        ).json()

        assert set(body) == {"days"}
        assert body["days"] == ["2026-08-02"]

    def test_asking_before_a_database_is_chosen_is_a_clear_409(self):
        settings = Settings(
            notion_client_id="cid",
            notion_client_secret="s",
            notion_redirect_uri="http://localhost/cb",
        )
        store = InMemoryConnectionStore(NotionConnection(access_token="t", workspace_id="ws"))
        app = create_app(settings=settings, connections=store)

        response = TestClient(app).get(
            "/notion/entry-days", params={"start": "2026-08-01", "end": "2026-08-31"}
        )

        assert response.status_code == 409


class TestBlockClassification:
    """The rule that decides whether a Notion page counts as written or illustrated.

    Directly against `classify_blocks`, because this is where the feature is either right or
    quietly useless — a rule that calls an abandoned page "finished" makes the whole worklist
    empty, and one that calls a finished page "empty" turns it into noise.
    """

    def test_a_page_with_a_paragraph_has_words(self):
        blocks = [{"type": "paragraph", "paragraph": {"rich_text": [{"plain_text": "Went to the sea."}]}}]
        assert classify_blocks(blocks) == {"has_words": True, "has_media": False}

    def test_a_page_with_an_image_has_media(self):
        assert classify_blocks([{"type": "image", "image": {}}]) == {
            "has_words": False, "has_media": True
        }

    def test_video_and_file_blocks_count_as_media(self):
        for kind in ("video", "file", "pdf", "audio", "embed"):
            assert classify_blocks([{"type": kind, kind: {}}])["has_media"], kind

    def test_headings_and_lists_count_as_words(self):
        for kind in ("heading_1", "bulleted_list_item", "numbered_list_item", "to_do", "quote"):
            blocks = [{"type": kind, kind: {"rich_text": [{"plain_text": "x"}]}}]
            assert classify_blocks(blocks)["has_words"], kind

    def test_an_empty_paragraph_is_not_words(self):
        """What Notion leaves behind when a line is deleted.

        Counting one would mark the abandoned pages as finished, which is exactly the set
        this feature exists to find.
        """
        assert classify_blocks([{"type": "paragraph", "paragraph": {"rich_text": []}}]) == {
            "has_words": False, "has_media": False
        }

    def test_whitespace_is_not_words(self):
        blocks = [{"type": "paragraph", "paragraph": {"rich_text": [{"plain_text": "   \n"}]}}]
        assert classify_blocks(blocks)["has_words"] is False

    def test_a_divider_is_neither(self):
        assert classify_blocks([{"type": "divider", "divider": {}}]) == {
            "has_words": False, "has_media": False
        }

    def test_the_verdict_carries_no_content(self):
        """Two booleans leave; the text does not."""
        blocks = [{"type": "paragraph", "paragraph": {"rich_text": [{"plain_text": "secret"}]}}]
        result = classify_blocks(blocks)
        assert set(result) == {"has_words", "has_media"}
        assert "secret" not in repr(result)


class TestEntryCoverage:
    """The endpoint behind "which entries did I start and never finish"."""

    def _app(self, entries):
        from app import routes_notion_auth

        class FakeGateway:
            def __init__(self, *args, **kwargs):
                pass

        async def fake_coverage(access_token, database_id, date_property, start, end):
            assert date_property == "When"
            return [e for e in entries if start <= e["date"] <= end]

        settings = Settings(
            notion_client_id="cid",
            notion_client_secret="s",
            notion_redirect_uri="http://localhost/cb",
        )
        store = InMemoryConnectionStore(
            NotionConnection(
                access_token="t",
                workspace_id="ws",
                database_id="db-1",
                title_property="Name",
                date_property="When",
            )
        )
        app = create_app(settings=settings, connections=store)
        app.router.routes = [
            r for r in app.router.routes if not getattr(r, "path", "").startswith("/notion/")
        ]
        app.include_router(
            routes_notion_auth.build_router(
                oauth=NotionOAuth("cid", "s", "http://localhost/cb"),
                store=store,
                app_return_url="app://done",
                gateway_factory=FakeGateway,
                coverage_lister=fake_coverage,
            )
        )
        return TestClient(app)

    def test_reports_entries_with_their_two_verdicts(self):
        client = self._app([
            {"page_id": "p1", "date": "2026-08-02", "title": "Beach",
             "has_words": False, "has_media": True},
            {"page_id": "p2", "date": "2026-09-20", "title": "Later",
             "has_words": True, "has_media": True},
        ])

        body = client.get(
            "/notion/entry-coverage", params={"start": "2026-08-01", "end": "2026-08-31"}
        ).json()

        assert body == {"entries": [
            {"page_id": "p1", "date": "2026-08-02", "title": "Beach",
             "has_words": False, "has_media": True}
        ]}

    def test_asking_before_a_database_is_chosen_is_a_clear_409(self):
        settings = Settings(
            notion_client_id="cid",
            notion_client_secret="s",
            notion_redirect_uri="http://localhost/cb",
        )
        store = InMemoryConnectionStore(NotionConnection(access_token="t", workspace_id="ws"))
        app = create_app(settings=settings, connections=store)

        response = TestClient(app).get(
            "/notion/entry-coverage", params={"start": "2026-08-01", "end": "2026-08-31"}
        )

        assert response.status_code == 409


class TestStubCoverage:
    """The deterministic gateway answers the same question the real one does."""

    @pytest.mark.anyio
    async def test_a_page_with_only_photos_is_reported_as_wordless(self):
        notion = InMemoryNotion()
        page_id = await notion.ensure_page("2026-08-14", "Beach", None)
        await notion.replace_children(page_id, [{"type": "image", "image": {}}], [])

        coverage = await notion.entry_coverage("2026-08-01", "2026-08-31")

        assert coverage == [{
            "page_id": page_id, "date": "2026-08-14", "title": "Beach",
            "has_words": False, "has_media": True,
        }]

    @pytest.mark.anyio
    async def test_a_page_outside_the_window_is_not_reported(self):
        notion = InMemoryNotion()
        await notion.ensure_page("2026-01-04", "Old", None)

        assert await notion.entry_coverage("2026-08-01", "2026-08-31") == []
