"""Verification that formatting corrected the user's text rather than rewriting it.

The distinction this module exists to draw is between two things that look similar to a
language model and are completely different to a person:

* **Correcting** — ``softwaaarre`` → ``software``, splitting ``twowordsruntogether``. The
  user meant a word and mistyped it. Fixing that is a service.
* **Authoring** — ``went for a jog`` where they wrote ``ran five miles``, or dropping a line
  because it looked unimportant. That is the model putting its own words in someone's
  journal, and it is the thing the product exists to prevent.

The rule, then, is not "no word may change". It is:

1. A word may be replaced by one that is *recognisably the same word*, judged by string
   similarity. That covers typos, doubled letters, stray keystrokes.
2. A long run-together token may be split into words it contains.
3. Anything else introduced is authoring. Anything dropped without a replacement is
   summarising. Both are rejected.
4. **Protected terms are exempt from rule 1.** Names, slang and coinages look exactly like
   typos to a spellchecker, so the user can mark them and they must then survive verbatim.

Rule 4 is the important one for a journal. "Amaka", "wagwan", "engqchineers" as an in-joke —
a model will confidently "fix" all of these, and being repeatedly corrected on your own
vocabulary is precisely the experience of having your voice overwritten.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from difflib import SequenceMatcher
from typing import Dict, FrozenSet, List, Sequence, Set, Tuple

_WORD = re.compile(r"[a-z0-9']+")

#: How alike two words must be to count as a correction rather than a replacement.
#: 0.72 accepts ``softwaaarre``→``software`` (~0.84) and rejects ``ran``→``jogged`` (~0.2).
SIMILARITY_THRESHOLD = 0.72

#: A token this long that vanishes may have been split into the words it contains.
RUN_ON_LENGTH = 10

#: Words a formatter may introduce as structure rather than content.
STRUCTURAL_WORDS: Set[str] = {str(digit) for digit in range(10)}


def tokenize(text: str) -> List[str]:
    """Lowercased word tokens. Punctuation and markdown markers are not words."""
    return _WORD.findall(text.lower())


@dataclass
class Analysis:
    """What changed between the user's text and the formatter's output."""

    #: (original, replacement) pairs judged to be corrections of the same word.
    corrections: List[Tuple[str, str]] = field(default_factory=list)
    #: Words with no plausible original — the model wrote these.
    invented: Set[str] = field(default_factory=set)
    #: Words with no replacement — the model discarded these.
    lost: Set[str] = field(default_factory=set)
    #: Protected terms the model altered or removed despite being told not to.
    violated_protected: Set[str] = field(default_factory=set)

    @property
    def is_acceptable(self) -> bool:
        return not (self.invented or self.lost or self.violated_protected)


def analyse(
    raw_text: str,
    formatted_text: str,
    protected: Sequence[str] = (),
) -> Analysis:
    """Compare the two texts and classify every difference."""
    protected_set: FrozenSet[str] = frozenset(
        token for term in protected for token in tokenize(term)
    )

    raw_tokens = set(tokenize(raw_text))
    formatted_tokens = set(tokenize(formatted_text))

    lost = raw_tokens - formatted_tokens
    invented = formatted_tokens - raw_tokens - STRUCTURAL_WORDS

    analysis = Analysis()

    # A protected term that the user wrote must appear untouched. Checked before the
    # similarity pass, so a "helpful" near-miss on someone's name is still a violation.
    analysis.violated_protected = {word for word in lost if word in protected_set}
    lost -= analysis.violated_protected

    remaining_lost = set(lost)
    remaining_invented = set(invented)

    # Pass 1: for each word that disappeared, look for a recognisably-similar word anywhere
    # in the output.
    #
    # Searching *all* output tokens rather than only the newly-introduced ones matters more
    # than it looks. If the author wrote both "software" and "softwaaarre", correcting the
    # typo produces a word that was already present — so the correction is invisible to a
    # set difference, and the typo reads as a plain deletion. That misdiagnosis then made
    # the retry ask the model to restore a word it had not actually removed.
    for original in sorted(remaining_lost):
        best_match, best_score = None, 0.0
        for candidate in formatted_tokens:
            score = SequenceMatcher(None, original, candidate).ratio()
            if score > best_score:
                best_match, best_score = candidate, score
        if best_match is not None and best_score >= SIMILARITY_THRESHOLD:
            analysis.corrections.append((original, best_match))
            remaining_lost.discard(original)
            remaining_invented.discard(best_match)

    # Pass 2: a long token that vanished may have been split into words it contains.
    for original in sorted(remaining_lost):
        if len(original) < RUN_ON_LENGTH:
            continue
        pieces = {
            word for word in remaining_invented if len(word) >= 2 and word in original
        }
        if pieces:
            analysis.corrections.append((original, " ".join(sorted(pieces))))
            remaining_lost.discard(original)
            remaining_invented -= pieces

    analysis.invented = remaining_invented
    analysis.lost = remaining_lost
    return analysis


class FormattingAlteredWordsError(Exception):
    """Raised when formatted output rewrites rather than corrects."""

    def __init__(self, analysis: Analysis) -> None:
        self.analysis = analysis
        self.invented = analysis.invented
        self.lost = analysis.lost
        self.violated_protected = analysis.violated_protected

        parts: List[str] = []
        if analysis.violated_protected:
            parts.append(
                "changed words you marked as correct: "
                + ", ".join(sorted(analysis.violated_protected))
            )
        if analysis.invented:
            parts.append("added " + ", ".join(sorted(analysis.invented)[:8]))
        if analysis.lost:
            parts.append("dropped " + ", ".join(sorted(analysis.lost)[:8]))
        super().__init__(
            "Formatting changed the wording (" + "; ".join(parts) + "), so it was not applied."
        )


def verify_preserves_wording(
    raw_text: str,
    formatted_text: str,
    protected: Sequence[str] = (),
) -> Analysis:
    """Raise unless the output only restructures and corrects ``raw_text``.

    Returns the analysis on success, so callers can report which corrections were made —
    which is how the user discovers a word they should protect.
    """
    analysis = analyse(raw_text, formatted_text, protected)
    if not analysis.is_acceptable:
        raise FormattingAlteredWordsError(analysis)
    return analysis


# Retained for callers that only want the raw sets.

def introduced_words(raw_text: str, formatted_text: str) -> Set[str]:
    return set(tokenize(formatted_text)) - set(tokenize(raw_text)) - STRUCTURAL_WORDS


def dropped_words(raw_text: str, formatted_text: str) -> Set[str]:
    return set(tokenize(raw_text)) - set(tokenize(formatted_text))
