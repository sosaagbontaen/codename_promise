"""Turning a rambling transcript into a journal entry, accountably.

The product's whole claim: talk for ten minutes, jumping between subjects and doubling back,
and get the entry you would have written if you had the patience to write it. That means
grouping thoughts that are far apart, which the copy-editing `Formatter` cannot do and must
not try — it exists to preserve wording exactly (see `wordguard`).

**Two passes, because they need different things.** Assigning every line to a thread needs to
see the whole transcript and produces almost no text. Writing a section needs no global view
at all and produces prose. Doing both in one response was measurably worse: on an eight-minute
entry it lost about a third of the day, and the cause was reasoning tokens eating the
completion budget until the model returned an empty string.

Splitting them also makes fidelity structural rather than instructed. Pass two is shown only
the lines belonging to its own thread, so it cannot quote a line it never saw.

Grouping still happens globally, in pass one. Only the writing is local.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Protocol, Sequence

from .dropguard import Audit, repair

#: Bumped when the prompts change enough that output would differ. Stored with an entry so a
#: re-organise can be offered when it would actually produce something new.
ORGANISER_VERSION = "organise-2026-09"

_SENTENCE_BREAK = re.compile(r"(?<=[.!?])\s+")


def split_sentences(transcript: str) -> List[str]:
    """One line per sentence, which is the unit everything downstream counts in.

    Speech-to-text returns punctuated prose with no paragraphs, so sentence boundaries are
    the only structure available. Fragments like "Um." survive as their own line rather than
    being merged away, because the accounting has to name them to drop them.
    """
    flat = " ".join(transcript.split())
    return [s.strip() for s in _SENTENCE_BREAK.split(flat) if s.strip()]


class ThreadAssigner(Protocol):
    """Pass one. Every line number to a thread name, seeing the whole transcript."""

    async def assign(self, sentences: Sequence[str]) -> Dict[str, List[int]]: ...


class SectionWriter(Protocol):
    """Pass two. One thread's lines to prose, seeing nothing else."""

    async def write(self, thread: str, lines: Sequence[str]) -> Dict[str, str]: ...


@dataclass
class Organised:
    sentences: List[str]
    sections: List[Dict] = field(default_factory=list)
    dropped: List[int] = field(default_factory=list)
    #: What the guard had to put back. Non-empty is not an error but is worth watching: a
    #: rising number means the prompts are drifting away from the guarantee.
    repaired: Audit = field(default_factory=Audit)
    version: str = ORGANISER_VERSION


#: Threads named by the assigner that mean "discard", not a subject.
FILLER_THREAD = "filler"


async def organise(
    transcript: str,
    assigner: ThreadAssigner,
    writer: SectionWriter,
) -> Organised:
    sentences = split_sentences(transcript)
    if not sentences:
        return Organised(sentences=[])

    threads = await assigner.assign(sentences)

    # Only ever index lines that exist. A model inventing line 200 must not crash the entry.
    valid = range(1, len(sentences) + 1)
    threads = {
        name: sorted({i for i in lines if i in valid})
        for name, lines in threads.items()
    }

    dropped = list(threads.pop(FILLER_THREAD, []))
    sections: List[Dict] = []
    for name, lines in threads.items():
        if not lines:
            continue
        written = await writer.write(name, [sentences[i - 1] for i in lines])
        sections.append(
            {
                "heading": (written.get("heading") or name).strip(),
                "body": (written.get("body") or "").strip(),
                "sources": lines,
            }
        )

    # Order by where the thread starts, so the entry still reads in the order the day went.
    sections.sort(key=lambda s: min(s["sources"]))

    repaired = repair(sentences, sections, dropped)
    return Organised(
        sentences=sentences,
        sections=sections,
        dropped=sorted(dropped),
        repaired=repaired,
    )
