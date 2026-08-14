"""Words the formatter must never "correct".

Names, slang, coinages and in-jokes are indistinguishable from typos to a spellchecker, and
a model will confidently fix all of them. Being repeatedly corrected on your own vocabulary
is exactly the experience of having your voice overwritten — so the user gets to say which
words are already right.

Two mechanisms, because a list nobody maintains is worthless:

* The terms are injected into the prompt, so the model is told up front.
* They are enforced by `wordguard`, so a model that ignores the instruction is caught.

Discovery matters as much as storage: the user learns which words to protect by seeing what
got corrected, which is why `/format` reports its corrections back.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import List, Optional, Set


class VocabularyStore:
    """A user's protected terms, persisted as a JSON list."""

    def __init__(self, path: Optional[Path] = None) -> None:
        self._path = Path(path) if path else Path(os.environ.get("CP_STATE_DIR", ".state")) / "vocabulary.json"
        self._cached: Optional[List[str]] = None

    def all(self) -> List[str]:
        if self._cached is None:
            self._cached = self._read()
        return list(self._cached)

    def add(self, term: str) -> List[str]:
        term = term.strip()
        if not term:
            return self.all()
        current = self.all()
        # Case-insensitive de-dupe, but the user's own capitalisation is what gets stored —
        # "Amaka" should come back as "Amaka".
        if term.lower() not in {t.lower() for t in current}:
            current.append(term)
            self._write(current)
        return current

    def remove(self, term: str) -> List[str]:
        current = [t for t in self.all() if t.lower() != term.strip().lower()]
        self._write(current)
        return current

    def contains(self, term: str) -> bool:
        return term.strip().lower() in {t.lower() for t in self.all()}

    def _read(self) -> List[str]:
        if not self._path.exists():
            return []
        try:
            data = json.loads(self._path.read_text())
            return [str(t) for t in data] if isinstance(data, list) else []
        except json.JSONDecodeError:
            # A corrupt vocabulary means "no protected terms", never a crash. The cost is a
            # spurious correction, not a lost entry.
            return []

    def _write(self, terms: List[str]) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(json.dumps(terms, indent=2, ensure_ascii=False))
        self._cached = terms


class InMemoryVocabularyStore(VocabularyStore):
    def __init__(self, terms: Optional[List[str]] = None) -> None:
        self._cached = list(terms or [])

    def _write(self, terms: List[str]) -> None:
        self._cached = terms
