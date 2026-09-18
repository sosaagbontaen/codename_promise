"""The organiser, and the guard that stops it summarising.

`wordguard` protects the copy-editor by asking whether every word is still the user's. An
organiser cannot pass that and must not be asked to. These tests pin the weaker promise it
makes instead: nothing vanishes, and what was discarded really was filler.
"""
import asyncio
from typing import Dict, List, Sequence

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.dropguard import audit, droppable, repair
from app.main import create_app
from app.organiser import organise, split_sentences


class TestDroppable:
    """What may be thrown away, decided by a rule rather than by a model."""

    def test_real_filler_is_droppable(self):
        for line in ["Um.", "Uh.", "Anyway.", "Where was I.", "Um, what else.", "Right.", "So."]:
            assert droppable(line), line

    def test_a_thought_is_never_filler(self):
        """The lines an organiser is most tempted to bin, and least allowed to.

        Every one of these was discarded as "filler" by a model that then passed the
        accounting check perfectly. They are the reflective lines, which are the reason
        somebody keeps a journal rather than a calendar.
        """
        for line in [
            "I always do that.",
            "I sit with something way too long before I ask anyone.",
            "That's probably the actual thing today.",
            "It's the same thing twice in one day.",
            "There's a pattern here isn't there.",
            "Things I've decided to deal with later and later has quietly become never.",
        ]:
            assert not droppable(line), line

    def test_length_alone_makes_a_line_content(self):
        """Even if every word is individually unremarkable."""
        assert not droppable("so and then it was just like that and then okay")

    def test_empty_is_droppable(self):
        assert droppable("")


class TestAudit:
    def test_a_clean_organisation_passes(self):
        sents = ["One thing happened.", "Um.", "Two things happened."]
        found = audit(sents, [{"sources": [1, 3]}], [2])
        assert found.is_clean

    def test_a_line_in_no_section_is_caught(self):
        sents = ["One.", "Two.", "Three."]
        assert audit(sents, [{"sources": [1]}], [2]).unaccounted == [3]

    def test_content_declared_as_filler_is_caught(self):
        """The failure that passed accounting: summarise, then call the rest filler."""
        sents = ["The deploy went out.", "I sit with things too long before asking."]
        assert audit(sents, [{"sources": [1]}], [2]).wrongly_dropped == [2]

    def test_a_line_claimed_twice_is_caught(self):
        sents = ["One.", "Two."]
        assert audit(sents, [{"sources": [1, 2]}, {"sources": [2]}], []).duplicated == [2]

    def test_an_invented_line_number_is_caught(self):
        assert audit(["One."], [{"sources": [1, 99]}], []).out_of_range == [99]


class TestRepair:
    def test_wrongly_dropped_content_goes_back(self):
        sents = ["The deploy went out.", "It went fine.", "I always do that."]
        sections = [{"sources": [1, 2]}]
        dropped = [3]
        repair(sents, sections, dropped)
        assert dropped == []
        assert 3 in sections[0]["sources"]

    def test_a_lost_line_joins_its_nearest_section(self):
        sents = ["One.", "Two.", "Three.", "Four."]
        sections = [{"sources": [1]}, {"sources": [4]}]
        repair(sents, sections, [])
        placed = {i for s in sections for i in s["sources"]}
        assert placed == {1, 2, 3, 4}

    def test_genuine_filler_stays_dropped(self):
        sents = ["The deploy went out.", "Um."]
        sections = [{"sources": [1]}]
        dropped = [2]
        repair(sents, sections, dropped)
        assert dropped == [2]


class TestSplitting:
    def test_fragments_survive_as_their_own_line(self):
        """They have to be nameable to be dropped."""
        assert split_sentences("I went out. Um. It was fine.") == [
            "I went out.", "Um.", "It was fine."
        ]

    def test_newlines_do_not_create_phantom_sentences(self):
        assert split_sentences("One thing.\n\nTwo things.") == ["One thing.", "Two things."]

    def test_an_empty_transcript_is_not_an_error(self):
        assert split_sentences("   \n  ") == []


class _Assigner:
    """A stand-in model whose behaviour each test chooses."""

    def __init__(self, threads: Dict[str, List[int]]):
        self.threads = threads

    async def assign(self, sentences: Sequence[str]) -> Dict[str, List[int]]:
        return self.threads

    async def write(self, thread: str, lines: Sequence[str]) -> Dict[str, str]:
        return {"heading": thread, "body": " ".join(lines)}


class TestOrganise:
    TEXT = "The deploy went out. Um. I called my mum. She sounded good. I always do that."

    def test_threads_become_sections_in_the_order_the_day_went(self):
        model = _Assigner({"family": [3, 4], "work": [1], "filler": [2]})
        result = asyncio.run(organise(self.TEXT, model, model))
        assert [s["heading"] for s in result.sections] == ["work", "family"]

    def test_a_section_is_written_only_from_its_own_lines(self):
        """Pass two never sees the rest, which is what makes fidelity structural."""
        model = _Assigner({"work": [1], "family": [3, 4], "filler": [2]})
        result = asyncio.run(organise(self.TEXT, model, model))
        work = next(s for s in result.sections if s["heading"] == "work")
        assert work["body"] == "The deploy went out."
        assert "mum" not in work["body"]

    def test_content_the_model_called_filler_is_put_back(self):
        model = _Assigner({"work": [1], "family": [3, 4], "filler": [2, 5]})
        result = asyncio.run(organise(self.TEXT, model, model))

        assert result.dropped == [2], "genuine filler still goes"
        assert result.repaired.wrongly_dropped == [5]
        placed = {i for s in result.sections for i in s["sources"]}
        assert 5 in placed, "the thought has to survive somewhere"

    def test_a_line_the_model_forgot_is_not_lost(self):
        model = _Assigner({"work": [1], "filler": [2]})
        result = asyncio.run(organise(self.TEXT, model, model))
        placed = {i for s in result.sections for i in s["sources"]} | set(result.dropped)
        assert placed == {1, 2, 3, 4, 5}

    def test_an_invented_line_number_cannot_break_the_entry(self):
        model = _Assigner({"work": [1, 900], "filler": [2]})
        result = asyncio.run(organise(self.TEXT, model, model))
        assert all(i <= 5 for s in result.sections for i in s["sources"])

    def test_an_empty_transcript_returns_nothing_rather_than_failing(self):
        model = _Assigner({})
        result = asyncio.run(organise("", model, model))
        assert result.sections == [] and result.sentences == []


class TestOrganiseEndpoint:
    def _client(self, organiser=None):
        return TestClient(create_app(settings=Settings(), organiser=organiser))

    def test_it_works_with_no_credentials_at_all(self):
        """Keyless development is a supported state, the same as it is for transcription."""
        r = self._client().post(
            "/organise",
            json={"draft_id": "d1", "transcript": "One thing happened. Um. Another thing."},
        )
        assert r.status_code == 200
        body = r.json()
        assert body["sections"] and body["organiser_version"]

    def test_the_server_returns_the_split_it_used(self):
        """So `sources` and the sentences they index cannot disagree.

        If the client re-split the transcript itself and split it differently, every source
        index would point at the wrong words, which is worse than having no citations.
        """
        text = "The deploy went out. Um. I called my mum."
        body = self._client().post(
            "/organise", json={"draft_id": "d1", "transcript": text}
        ).json()

        assert body["sentences"] == ["The deploy went out.", "Um.", "I called my mum."]
        for section in body["sections"]:
            for index in section["sources"]:
                assert 1 <= index <= len(body["sentences"])

    def test_every_line_is_accounted_for(self):
        text = "One thing. Um. Two things. Anyway. Three things."
        body = self._client().post(
            "/organise", json={"draft_id": "d1", "transcript": text}
        ).json()

        placed = {i for s in body["sections"] for i in s["sources"]} | set(body["dropped"])
        assert placed == set(range(1, len(body["sentences"]) + 1))

    def test_a_provider_failure_is_502_not_500(self):
        class Broken:
            async def assign(self, sentences):
                from app.providers.groq import GroqError
                raise GroqError("Could not reach Groq.")

            async def write(self, thread, lines):  # pragma: no cover
                return {}

        r = self._client(Broken()).post(
            "/organise", json={"draft_id": "d1", "transcript": "Something happened."}
        )
        assert r.status_code == 502

    def test_the_same_key_replays_rather_than_reorganising(self):
        client = self._client()
        payload = {"draft_id": "d1", "transcript": "One thing. Two things."}
        first = client.post("/organise", json=payload, headers={"Idempotency-Key": "k1"})
        second = client.post("/organise", json=payload, headers={"Idempotency-Key": "k1"})
        assert first.json() == second.json()

    def test_being_rate_limited_is_429_with_the_wait(self):
        """A user with a long recording meets this in normal use, not only under load.

        One eight-minute entry costs more than a minute of the free tier's token budget, so
        this has to read as "wait a moment" rather than "the server is broken".
        """
        class Limited:
            async def assign(self, sentences):
                from app.providers.groq import GroqRateLimited
                raise GroqRateLimited("Too many requests just now.", retry_after="30")

            async def write(self, thread, lines):  # pragma: no cover
                return {}

        r = self._client(Limited()).post(
            "/organise", json={"draft_id": "d1", "transcript": "Something happened."}
        )
        assert r.status_code == 429
        assert r.headers.get("Retry-After") == "30"


class TestLongTranscripts:
    """The ten-minute recording that could not be arranged.

    Every test here corresponds to something that actually happened against the real provider
    on a 129-line transcript, not to a hypothetical. Two distinct failures reached the user as
    "the server had a problem" and "server is busy": a completion budget that stopped being
    big enough somewhere around six minutes of talking, and a free-tier token-per-minute
    limit that one long entry exceeds on its own.
    """

    def _organiser(self, responses, **kwargs):
        """A GroqOrganiser whose HTTP calls return a scripted sequence."""
        import httpx
        from app.providers.groq import GroqOrganiser

        sent = []

        class Client:
            def __init__(self, *a, **kw):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *a):
                return False

            async def post(self, url, headers=None, json=None):
                sent.append(json)
                status, payload, hdrs = responses.pop(0)
                return httpx.Response(
                    status, json=payload, headers=hdrs or {},
                    request=httpx.Request("POST", url),
                )

        organiser = GroqOrganiser(api_key="k", **kwargs)
        return organiser, Client, sent

    @staticmethod
    def _ok(content):
        import json as _json
        return (200, {"choices": [{"message": {"content": _json.dumps(content)}}]}, None)

    def test_the_budget_grows_with_the_transcript(self):
        """It was a flat 6,000 for every length, which is where this bug lived."""
        from app.providers.groq import GroqOrganiser

        short = GroqOrganiser.assign_budget(10)
        long = GroqOrganiser.assign_budget(129)
        assert long > short
        # Comfortably past the old ceiling, which a seven-minute entry sat right on top of.
        assert long > 6_000
        # And bounded, so a transcript of any length still asks for something sane.
        assert GroqOrganiser.assign_budget(100_000) <= 32_000

    def test_a_long_transcript_still_gets_the_finer_grouping(self, monkeypatch):
        """Lowering the reasoning effort looked like a cheap fix and was a quality
        regression: on the same 129-line transcript `dropguard` had to rescue 23 lines the
        model called filler at "low", against 5 at "medium". The flat budget was the bug."""
        import asyncio
        import httpx

        organiser, Client, sent = self._organiser([self._ok({"threads": {"work": [1]}})])
        monkeypatch.setattr(httpx, "AsyncClient", Client)

        asyncio.run(organiser.assign([f"Line {i}." for i in range(200)]))
        assert sent[0]["reasoning_effort"] == "medium"
        assert sent[0]["max_completion_tokens"] > 6_000

    def test_being_rate_limited_waits_rather_than_failing(self, monkeypatch):
        """The free tier allows 8,000 tokens a minute and one seven-minute entry costs about
        7,200, so meeting the limit partway through is the normal path, not an edge case."""
        import asyncio
        import httpx

        organiser, Client, sent = self._organiser([
            (429, {"error": {"message": "slow down"}}, {"retry-after": "0.01"}),
            self._ok({"threads": {"work": [1, 2]}}),
        ])
        monkeypatch.setattr(httpx, "AsyncClient", Client)

        threads = asyncio.run(organiser.assign(["One thing.", "Two things."]))
        assert threads == {"work": [1, 2]}
        assert len(sent) == 2, "the call should have been retried, not abandoned"

    def test_a_rate_limit_that_outlasts_the_deadline_still_gives_up(self, monkeypatch):
        """Waiting is right; waiting forever is not. The request must not outlive the client
        holding it open."""
        import asyncio
        import httpx
        from app.providers.groq import GroqRateLimited

        from app.providers.groq import begin_organise

        organiser, Client, sent = self._organiser(
            [(429, {"error": {"message": "slow down"}}, {"retry-after": "60"})]
        )
        monkeypatch.setattr(httpx, "AsyncClient", Client)
        begin_organise(seconds=0.0)

        with pytest.raises(GroqRateLimited):
            asyncio.run(organiser.assign(["One thing."]))
        assert len(sent) == 1

    def test_an_exhausted_budget_is_retried_with_more_room(self, monkeypatch):
        """Groq reports this as 400 json_validate_failed with an empty generation, which reads
        exactly like a broken prompt and is really a budget that ran out."""
        import asyncio
        import httpx

        organiser, Client, sent = self._organiser([
            (400, {"error": {
                "code": "json_validate_failed",
                "message": "Failed to validate JSON.",
                "failed_generation": "",
            }}, None),
            self._ok({"threads": {"work": [1]}}),
        ])
        monkeypatch.setattr(httpx, "AsyncClient", Client)

        threads = asyncio.run(organiser.assign([f"Line {i}." for i in range(100)]))
        assert threads == {"work": [1]}
        assert len(sent) == 2
        # Retrying the identical request would be pointless. More room, less thinking.
        assert sent[1]["max_completion_tokens"] > sent[0]["max_completion_tokens"]
        assert sent[1]["reasoning_effort"] == "low"

    def test_an_empty_answer_counts_as_an_exhausted_budget(self, monkeypatch):
        """The same failure sometimes arrives as a 200 with nothing in it."""
        import asyncio
        import httpx

        organiser, Client, sent = self._organiser([
            (200, {"choices": [{"message": {"content": "   "}}]}, None),
            self._ok({"threads": {"work": [1]}}),
        ])
        monkeypatch.setattr(httpx, "AsyncClient", Client)

        assert asyncio.run(organiser.assign(["One thing."])) == {"work": [1]}
        assert len(sent) == 2

    def test_a_provider_error_says_what_the_provider_said(self, monkeypatch):
        """Every 4xx used to become "Groq organising failed (400)." The real cause was in the
        body all along, and throwing it away is what made this bug invisible from outside."""
        import asyncio
        import httpx
        from app.providers.groq import GroqError

        organiser, Client, _ = self._organiser([
            (400, {"error": {"code": "model_decommissioned",
                             "message": "`some-model` has been decommissioned."}}, None),
        ])
        monkeypatch.setattr(httpx, "AsyncClient", Client)

        with pytest.raises(GroqError) as caught:
            asyncio.run(organiser.assign(["One thing."]))
        assert "decommissioned" in str(caught.value)

    def test_the_deadline_covers_the_whole_organise_not_each_call(self, monkeypatch):
        """A long entry is six or seven calls. Two minutes each is twelve minutes, which is
        not a bound on anything — the clock has to start once and cover all of them."""
        import asyncio
        import httpx
        from app.providers.groq import GroqRateLimited, begin_organise

        organiser, Client, sent = self._organiser([
            self._ok({"threads": {"work": [1]}}),
            (429, {"error": {"message": "slow down"}}, {"retry-after": "60"}),
        ])
        monkeypatch.setattr(httpx, "AsyncClient", Client)

        async def both():
            begin_organise(seconds=0.05)
            await organiser.assign(["One thing."])
            await asyncio.sleep(0.1)
            # The first call spent the budget; the second must not get a fresh one.
            await organiser.write("work", ["One thing."])

        with pytest.raises(GroqRateLimited):
            asyncio.run(both())
        assert len(sent) == 2
