"""Verification that organising rearranged the user's day rather than summarising it.

`wordguard` protects the copy-editor by asking *is every word still theirs?* An organiser
cannot pass that and must not be asked to: grouping a ramble means dropping "um" and moving
minute eight next to minute one. So this asks the two weaker questions that still keep the
promise.

**Is every line accounted for?** Every numbered sentence must appear in exactly one section
or be listed as dropped. Nothing may vanish without saying so.

**Is what was dropped actually filler?** This is the one that had to be learned. Accounting
alone was passed, perfectly, by a model that declared 36% of an eight-minute entry to be
filler. Among what it discarded:

    I sit with something way too long before I ask anyone.
    That's probably the actual thing today.
    Things I've decided to deal with later and later has quietly become never.

Those are the reflective lines, which are the reason somebody keeps a journal at all. Beside
"the boiler guy came at half seven" they look like asides, and a model optimising for a tidy
entry will bin them every time. So `dropped` is verified rather than believed, exactly as
`wordguard` verifies rather than believing the formatting prompt.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Sequence, Set

#: Words that can make up an entire line without the line meaning anything. Deliberately a
#: closed list: anything outside it is content, including words that look throwaway.
FILLER_WORDS: Set[str] = set(
    """um uh er erm hmm mm mmm okay ok right so anyway well yeah yes no nope oh ah
    what else let me think where was i now then and but like just actually basically
    i mean you know sort of kind of a the it that this is was s t""".split()
)

#: A line longer than this is content whatever it is made of. Real filler is short; the
#: threshold is what stops "I always do that" being reclassified as noise.
MAX_FILLER_WORDS = 6

_WORD = re.compile(r"[a-z']+")


def droppable(sentence: str) -> bool:
    """Whether a line is filler *in fact*, rather than because a model said so."""
    words = _WORD.findall(sentence.lower())
    if not words:
        return True
    if len(words) > MAX_FILLER_WORDS:
        return False
    return all(word in FILLER_WORDS for word in words)


@dataclass
class Audit:
    """What the guard found. Empty lists mean the organisation is trustworthy."""

    #: Lines in no section and not declared dropped. Silent loss, the worst outcome.
    unaccounted: List[int] = field(default_factory=list)
    #: Lines the model wanted to discard that carry content.
    wrongly_dropped: List[int] = field(default_factory=list)
    #: Lines claimed by more than one section.
    duplicated: List[int] = field(default_factory=list)
    #: Source numbers that do not exist in the transcript.
    out_of_range: List[int] = field(default_factory=list)

    @property
    def is_clean(self) -> bool:
        return not (
            self.unaccounted or self.wrongly_dropped or self.duplicated or self.out_of_range
        )


def audit(
    sentences: Sequence[str],
    sections: Sequence[Dict],
    dropped: Sequence[int],
) -> Audit:
    """Check an organised entry against the transcript it came from."""
    total = len(sentences)
    every = set(range(1, total + 1))

    seen: Set[int] = set()
    duplicated: List[int] = []
    for section in sections:
        for index in section.get("sources", []):
            if index in seen:
                duplicated.append(index)
            seen.add(index)

    dropped_set = set(dropped)
    accounted = seen | dropped_set

    return Audit(
        unaccounted=sorted(every - accounted),
        wrongly_dropped=sorted(
            i for i in dropped_set if i in every and not droppable(sentences[i - 1])
        ),
        duplicated=sorted(set(duplicated)),
        out_of_range=sorted(accounted - every),
    )


def repair(
    sentences: Sequence[str],
    sections: List[Dict],
    dropped: List[int],
) -> Audit:
    """Put back everything that should not have gone, in place.

    The guard does not only detect. A line that was lost or wrongly discarded is attached to
    the section nearest to it, so an imperfect plan costs a slightly worse grouping rather
    than a sentence out of somebody's day. Returns the audit of what had to be repaired,
    which is worth logging: a high number means the prompt is drifting.
    """
    found = audit(sentences, sections, dropped)
    if not sections:
        return found

    for index in found.wrongly_dropped:
        dropped.remove(index)
    for index in sorted(found.wrongly_dropped + found.unaccounted):
        nearest = min(
            sections,
            key=lambda s: min((abs(index - j) for j in s.get("sources", [])), default=10**6),
        )
        nearest["sources"] = sorted(set(nearest.get("sources", []) + [index]))
    return found
