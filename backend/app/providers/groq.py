"""Groq Cloud providers.

Groq exposes an OpenAI-compatible surface, so a single HTTP shape covers both Whisper
transcription and the chat model used for formatting. That also means swapping to OpenAI (or
anything else OpenAI-compatible) is a base-URL change, not a rewrite.

The API key is read from the environment and never logged, never echoed in a response, and
never written to disk. See ADR-022.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Sequence, Tuple

import httpx

from ..wordguard import Analysis, FormattingAlteredWordsError, verify_preserves_wording

GROQ_BASE_URL = "https://api.groq.com/openai/v1"

#: Groq's Whisper deployment. Turbo is fast and cheap enough to retry freely, which matters
#: because the client queues recordings and drains them in bulk.
DEFAULT_TRANSCRIPTION_MODEL = "whisper-large-v3-turbo"
DEFAULT_FORMATTING_MODEL = "llama-3.3-70b-versatile"

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
