"""Groq Cloud providers.

Groq exposes an OpenAI-compatible surface, so a single HTTP shape covers both Whisper
transcription and the chat model used for formatting. That also means swapping to OpenAI (or
anything else OpenAI-compatible) is a base-URL change, not a rewrite.

The API key is read from the environment and never logged, never echoed in a response, and
never written to disk. See ADR-022.
"""

from __future__ import annotations

import json

from typing import Any, Dict, List, Optional, Sequence, Tuple, Set

import httpx

from ..wordguard import Analysis, FormattingAlteredWordsError, verify_preserves_wording

GROQ_BASE_URL = "https://api.groq.com/openai/v1"

#: Groq's Whisper deployment. Turbo is fast and cheap enough to retry freely, which matters
#: because the client queues recordings and drains them in bulk.
DEFAULT_TRANSCRIPTION_MODEL = "whisper-large-v3-turbo"
#: Retired models 404 at request time with nothing at startup to warn you, which is exactly
#: how `llama-3.3-70b-versatile` sat broken in a shipped build. `list_models` plus the
#: verification in `/health` is what turns the next retirement into a visible failure.
DEFAULT_FORMATTING_MODEL = "openai/gpt-oss-120b"

#: The prompt is a *request* to preserve wording. `wordguard` is the enforcement — see
#: `GroqFormatter.format`. Never rely on this text alone.
SYSTEM_PROMPT = """\
You are a copy-editor tidying up someone's personal journal entry.

FIX THESE:
- Typos: doubled letters, transposed letters, stray keystrokes.
  "softwaaarre" -> "software".  "engqchineers" -> "engineers".
- Words accidentally run together.
  "Sinceqwhendideggsbecomesoexpensive?" -> "Since when did eggs become so expensive?"
- Capitalisation and punctuation.

NEVER DO THESE:
- Never swap in a different word. "ran" stays "ran" — not "jogged". Fixing a misspelling is
  allowed; choosing a nicer word is not.
- Never add words of your own. No summary, no title, no commentary, no transitions.
- Never leave anything out. Every idea the author wrote must still appear, including
  greetings ("Howdy"), one-word lines and throwaway asides. You are not the judge of what
  matters in someone's journal.
- Never change tone, register or slang. Informal stays informal. "gonna" stays "gonna".
- Never "correct" anything in the PROTECTED list below. Those are names, slang or
  deliberate spellings, and they are already right.

ALSO DO:
- Group related sentences under "- " bullets, one idea each.
- Nest a supporting detail under the point it supports, using indentation.
- Reorder bullets so related ideas sit together.

Example.
Input:
  Howdy
  went to teh shops w/ Amaka
  boughtsomemilk

Output:
  - Howdy
  - went to the shops w/ Amaka
  - bought some milk

Note what happened there: "teh" was fixed, "boughtsomemilk" was separated, "w/" and "Howdy"
were left exactly as written, and nothing was added or removed.

Output markdown using only "- " bullets and indentation. Output nothing else: no preamble,
no explanation, no closing remark.\
"""


class GroqError(Exception):
    """Transport or API failure from Groq."""


class GroqTranscriber:
    """Whisper transcription via Groq."""

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_TRANSCRIPTION_MODEL,
        base_url: str = GROQ_BASE_URL,
        timeout: float = 120.0,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout

    async def transcribe(self, audio: bytes, filename: str) -> str:
        files = {"file": (filename, audio, "audio/m4a")}
        data = {
            "model": self._model,
            "response_format": "json",
            # Nudges Whisper away from inventing punctuation-heavy prose for hesitant speech.
            "temperature": "0",
        }
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.post(
                    f"{self._base_url}/audio/transcriptions",
                    headers={"Authorization": f"Bearer {self._api_key}"},
                    files=files,
                    data=data,
                )
        except httpx.HTTPError as exc:
            raise GroqError(f"Could not reach Groq: {exc}") from exc

        if response.status_code >= 400:
            raise GroqError(f"Groq transcription failed ({response.status_code}).")

        payload: Dict[str, Any] = response.json()
        return (payload.get("text") or "").strip()


class GroqFormatter:
    """Structuring via a Groq chat model, with the output verified before it is trusted."""

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_FORMATTING_MODEL,
        base_url: str = GROQ_BASE_URL,
        timeout: float = 60.0,
        enforce_wording: bool = True,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout
        self._enforce_wording = enforce_wording
        #: Corrections made by the last successful call, so the caller can show the user
        #: what changed — that is how they discover a word worth protecting.
        self.last_analysis: Optional[Analysis] = None
        #: How many pieces of a long entry kept the author's own text because structuring
        #: them faithfully wasn't possible.
        self.chunks_left_unformatted = 0

    async def complete(self, messages: List[Dict[str, str]]) -> str:
        """One chat completion. Separated so the retry logic above it is testable."""
        body = {
            "model": self._model,
            "messages": messages,
            # Deterministic-ish: the same entry should format the same way twice, and
            # creativity is precisely what we do not want here. Note that temperature 0 is
            # not a guarantee — observed output still varies run to run, which is exactly
            # why `wordguard` exists rather than trusting the prompt.
            "temperature": 0,
        }
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.post(
                    f"{self._base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self._api_key}",
                        "Content-Type": "application/json",
                    },
                    json=body,
                )
        except httpx.HTTPError as exc:
            raise GroqError(f"Could not reach Groq: {exc}") from exc

        if response.status_code >= 400:
            raise GroqError(f"Groq formatting failed ({response.status_code}).")

        payload = response.json()
        try:
            return payload["choices"][0]["message"]["content"].strip()
        except (KeyError, IndexError, AttributeError) as exc:
            raise GroqError("Groq returned an unexpected response shape.") from exc

    #: Above this, the entry is formatted in pieces.
    #:
    #: Long input is where models drift: asked to restructure two thousand words they start
    #: paraphrasing somewhere in the middle, the guard correctly rejects the whole thing, and
    #: the user gets a 422 on the entry they most wanted help with. Smaller pieces stay
    #: faithful, and a piece that still fails only costs that piece.
    CHUNK_THRESHOLD = 1200

    async def format(self, raw_text: str, protected: Sequence[str] = ()) -> str:
        chunks = _split_for_formatting(raw_text, self.CHUNK_THRESHOLD)
        if len(chunks) == 1:
            return await self._format_chunk(raw_text, protected)

        formatted_parts: List[str] = []
        corrections: List[Tuple[str, str]] = []
        fell_back = 0

        for chunk in chunks:
            try:
                part = await self._format_chunk(chunk, protected)
                if self.last_analysis:
                    corrections.extend(self.last_analysis.corrections)
            except FormattingAlteredWordsError:
                # This piece couldn't be structured faithfully. Keep the author's own text
                # for it rather than failing the whole entry — partial structure with their
                # exact words beats a 422 on two thousand words of reflection.
                part = chunk.strip()
                fell_back += 1
            formatted_parts.append(part)

        merged = Analysis()
        merged.corrections = corrections
        self.last_analysis = merged
        self.chunks_left_unformatted = fell_back
        return "\n".join(p for p in formatted_parts if p)

    async def _format_chunk(self, raw_text: str, protected: Sequence[str]) -> str:
        system = SYSTEM_PROMPT
        if protected:
            system += "\n\nPROTECTED — reproduce these exactly, never 'correct' them:\n"
            system += "\n".join(f"- {term}" for term in protected)

        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": raw_text},
        ]
        formatted = await self.complete(messages)

        if not self._enforce_wording:
            return formatted

        try:
            self.last_analysis = verify_preserves_wording(raw_text, formatted, protected)
            return formatted
        except FormattingAlteredWordsError as first_failure:
            # Observed behaviour: models drop short standalone lines — a "Howdy" on its own
            # gets judged as noise — intermittently, even at temperature 0. Naming the exact
            # words back to the model corrects it far more often than re-rolling the same
            # request would. One retry only: a model that ignores a specific, concrete
            # correction is not going to be talked round by a third attempt.
            messages += [
                {"role": "assistant", "content": formatted},
                {"role": "user", "content": _correction_message(first_failure)},
            ]
            second = await self.complete(messages)
            self.last_analysis = verify_preserves_wording(raw_text, second, protected)
            return second


def _split_for_formatting(text: str, threshold: int) -> List[str]:
    """Split a long entry on blank lines, packing paragraphs up to roughly ``threshold``.

    Splits only at boundaries the author already made, so no sentence is ever cut in half —
    each piece is something they wrote as a unit.
    """
    if len(text) <= threshold:
        return [text]

    paragraphs = [p for p in text.split("\n\n") if p.strip()]
    if len(paragraphs) <= 1:
        # One long block with no blank lines. Fall back to line boundaries.
        paragraphs = [line for line in text.splitlines() if line.strip()]
    if len(paragraphs) <= 1:
        return [text]

    chunks: List[str] = []
    current = ""
    for paragraph in paragraphs:
        candidate = f"{current}\n\n{paragraph}" if current else paragraph
        if current and len(candidate) > threshold:
            chunks.append(current)
            current = paragraph
        else:
            current = candidate
    if current:
        chunks.append(current)
    return chunks


def _correction_message(failure: FormattingAlteredWordsError) -> str:
    """Tell the model precisely what it got wrong, in its own terms."""
    parts = []
    if failure.lost:
        words = ", ".join(sorted(failure.lost))
        parts.append(
            f"You removed these words, which the author wrote: {words}. "
            "Put every one of them back, exactly as written."
        )
    if failure.invented:
        words = ", ".join(sorted(failure.invented))
        parts.append(
            f"You added these words, which the author never wrote: {words}. "
            "Remove them."
        )
    if failure.violated_protected:
        words = ", ".join(sorted(failure.violated_protected))
        parts.append(
            f"You changed these words, which the author has marked as already correct: "
            f"{words}. They are names or deliberate spellings — reproduce them exactly."
        )
    parts.append(
        "Output the entry again. Reorganise and fix obvious typos, but do not substitute "
        "different words, add anything, or leave anything out."
    )
    return " ".join(parts)


async def list_models(api_key: str, base_url: str = GROQ_BASE_URL) -> Set[str]:
    """Model ids this account can actually call.

    Exists because a provider can retire a model underneath a running app. Nothing in the
    request path notices until a user hits it, and then the failure is a 404 from a request
    nobody changed. Asking up front is a few hundred milliseconds and turns that into
    something a deploy check can see.
    """
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.get(f"{base_url.rstrip('/')}/models", headers=headers)
    except httpx.HTTPError as exc:
        raise GroqError(f"Could not reach Groq to list models: {exc}") from exc
    if response.status_code >= 400:
        raise GroqError(f"Groq returned {response.status_code} listing models.")
    return {m.get("id", "") for m in response.json().get("data", [])}


ASSIGN_PROMPT = """You are reading a transcript of someone talking freely about their day, \
numbered one sentence per line. People do not talk in order: they start a subject, wander off, \
and come back to it many lines later.

Assign every line to a thread. A thread is one subject, however scattered. If they discuss work \
at line 3 and return to work at line 60, both lines get the thread "work". Never create two \
threads for the same subject.

Lines that are pure filler ("um", "where was I", false starts carrying no content) get the \
thread "filler". Be sparing: a line with a real subject and a verb is not filler, however \
small it seems. Reflections about themselves are the point of the entry, not padding.

HOW MANY THREADS
A day has a few real subjects, not fifteen. Aim for four to eight, plus "filler". If you find \
yourself naming a thread for a single passing mention, put that line with the nearest larger \
thread instead. Threads are subjects, not moments: work is one thread even if it covers a \
deploy, a colleague and a worry about next quarter, and a person is not a separate thread from \
the subject they came up in.

Reply with JSON only. Every line number from 1 to the last must appear exactly once:
{"threads": {"work": [3,4,60], "brother": [22,23], "filler": [10,16]}}"""

WRITE_PROMPT = """You are writing one section of someone's journal from their own spoken words.

You are given the lines they said about this one subject, in the order they said them. Write \
them as a few sentences of flowing prose.

- Use their words and phrasing. Keep their slang and their humour. You are arranging what they \
said, not rewriting it.
- Never add a fact, a feeling or a conclusion they did not say.
- Never soften an uncomfortable thought. If they said something bleak about themselves, it stays.
- Do not add a heading inside the body, a preamble, or a closing summary.

Reply with JSON only: {"heading": "a short heading in their voice", "body": "the prose"}"""


class GroqRateLimited(GroqError):
    """The provider is rate limiting, which is a wait rather than a failure.

    Worth its own type because the free tier caps tokens per minute, and one long entry is
    most of a minute's budget: a user with an eight-minute recording will meet this in normal
    use, not only under load.
    """

    def __init__(self, message: str, retry_after: Optional[str] = None) -> None:
        super().__init__(message)
        self.retry_after = retry_after


class GroqOrganiser:
    """Both passes of the organiser against a Groq chat model.

    `reasoning_effort` is set explicitly and deliberately. These are reasoning models and
    reasoning counts against `max_completion_tokens`: left at the default, the assignment pass
    spent 84% of its allowance thinking and returned an empty string, which the API reports as
    `400 json_validate_failed` and which reads exactly like a broken prompt. "medium" also
    groups better than "low", which split a colleague out of the work thread.
    """

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_FORMATTING_MODEL,
        base_url: str = GROQ_BASE_URL,
        timeout: float = 120.0,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout

    async def _json_call(self, system: str, user: str, max_tokens: int) -> Dict[str, Any]:
        body = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.3,
            "max_completion_tokens": max_tokens,
            "reasoning_effort": "medium",
            "response_format": {"type": "json_object"},
        }
        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.post(
                    f"{self._base_url}/chat/completions", headers=headers, json=body
                )
        except httpx.HTTPError as exc:
            raise GroqError(f"Could not reach Groq: {exc}") from exc

        if response.status_code == 429:
            # Not a fault, a queue. Raised distinctly so the route can answer 429 with the
            # provider's own Retry-After instead of a 502, which would tell the client the
            # server is broken and invite it to hammer a bucket that needs a minute.
            raise GroqRateLimited(
                "Too many requests just now.",
                retry_after=response.headers.get("retry-after"),
            )
        if response.status_code >= 400:
            raise GroqError(f"Groq organising failed ({response.status_code}).")
        try:
            return json.loads(response.json()["choices"][0]["message"]["content"])
        except (KeyError, ValueError) as exc:
            raise GroqError("Groq returned something that was not the expected JSON.") from exc

    async def assign(self, sentences: Sequence[str]) -> Dict[str, List[int]]:
        numbered = "\n".join(f"{i}. {s}" for i, s in enumerate(sentences, 1))
        tail = f"\n\n(That is {len(sentences)} lines. Assign every one.)"
        payload = await self._json_call(ASSIGN_PROMPT, numbered + tail, 6000)
        threads = payload.get("threads", {})
        return {
            str(name): [int(i) for i in lines if isinstance(i, (int, float))]
            for name, lines in threads.items()
            if isinstance(lines, list)
        }

    async def write(self, thread: str, lines: Sequence[str]) -> Dict[str, str]:
        payload = await self._json_call(WRITE_PROMPT, "\n".join(lines), 2500)
        return {
            "heading": str(payload.get("heading", thread)),
            "body": str(payload.get("body", "")),
        }
