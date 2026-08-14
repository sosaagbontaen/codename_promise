"""Wire contracts.

Field names here are load-bearing: they must match the Codable structs in
``Core/Sources/CodenamePromiseCore/Networking/HTTPServices.swift`` exactly. A rename on
either side is a silent breakage, since JSON decoding failures surface to the user as a
vague "the server sent something unexpected".
"""

from __future__ import annotations

import re
from typing import List, Optional

from pydantic import BaseModel, Field, field_validator

_ENTRY_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class EntryDateMixin(BaseModel):
    """Shared validation for the calendar day an entry belongs to.

    The client sends ``yyyy-MM-dd`` deliberately — it is a calendar day, not an instant, and
    converting it to a datetime here would reintroduce exactly the timezone ambiguity that
    ADR-006 exists to remove.
    """

    entry_date: str

    @field_validator("entry_date")
    @classmethod
    def _check_shape(cls, value: str) -> str:
        if not _ENTRY_DATE.match(value):
            raise ValueError("entry_date must be yyyy-MM-dd")
        return value


# --- Transcription -------------------------------------------------------------------

class TranscriptionResponse(BaseModel):
    text: str


# --- Formatting ----------------------------------------------------------------------

class FormatRequest(BaseModel):
    raw_text: str
    draft_id: str


class Correction(BaseModel):
    """A word the formatter changed, and what it changed it to."""

    original: str
    replacement: str


class FormatResponse(BaseModel):
    formatted_text: str
    formatter_version: str
    #: Typos the formatter fixed. Surfaced so the user can say "no, that word was right" and
    #: protect it — which is the only realistic way they discover the vocabulary feature.
    corrections: List[Correction] = Field(default_factory=list)


class VocabularyTerm(BaseModel):
    term: str


# --- Notion --------------------------------------------------------------------------

class EnsurePageRequest(EntryDateMixin):
    title: Optional[str] = None
    existing_page_id: Optional[str] = None


class EnsurePageResponse(BaseModel):
    page_id: str


class UploadFileResponse(BaseModel):
    file_id: str


class AttachedFile(BaseModel):
    """An uploaded file and what kind of block it should become."""

    id: str
    #: "photo" or "video". Drives whether Notion renders a picture or a player rather than a
    #: download link.
    kind: str = "photo"


class InsertContentRequest(BaseModel):
    page_id: str
    formatted_text: str
    attached_files: List[AttachedFile] = Field(default_factory=list)
    #: Older clients sent bare ids with no kind. Treated as photos.
    attached_file_ids: List[str] = Field(default_factory=list)

    @property
    def files(self) -> List[dict]:
        if self.attached_files:
            return [{"id": f.id, "kind": f.kind} for f in self.attached_files]
        return [{"id": file_id, "kind": "photo"} for file_id in self.attached_file_ids]
    # Blocks written by an earlier, interrupted attempt. Their presence means "replace
    # these", which is how a resumed sync avoids appending a second copy. See ADR-005.
    replace_block_ids: List[str] = Field(default_factory=list)


class InsertContentResponse(BaseModel):
    block_ids: List[str]


class UpdatePropertiesRequest(EntryDateMixin):
    page_id: str
    title: Optional[str] = None


class EmptyResponse(BaseModel):
    pass
