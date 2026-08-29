from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field

from app.services.editor import SessionView

HEX_COLOR = r"^#[0-9a-fA-F]{6}$"


class TextSpanOut(BaseModel):
    """One editable run of text, positioned in PDF points from the top-left."""

    index: int
    text: str
    bbox: list[float]
    font: str
    size: float
    color: str
    # The base-14 face a replacement will actually be drawn in, so the editor
    # can warn that the typeface will change before the user commits.
    substitute_font: str
    added: bool = False


class ImageOut(BaseModel):
    index: int
    bbox: list[float]
    width: int
    height: int
    added: bool = False


class PageOut(BaseModel):
    number: int
    width: float
    height: float
    spans: list[TextSpanOut]
    images: list[ImageOut]


class SessionOut(BaseModel):
    id: uuid.UUID
    filename: str
    page_count: int
    revision: int
    expires_at: datetime
    operation_count: int
    pages: list[PageOut]

    @classmethod
    def from_view(cls, view: SessionView) -> SessionOut:
        session = view.session
        return cls(
            id=session.id,
            filename=session.original_filename,
            page_count=session.page_count,
            revision=session.revision,
            expires_at=session.expires_at,
            operation_count=len(session.operations),
            pages=[
                PageOut(
                    number=page.number,
                    width=page.width,
                    height=page.height,
                    spans=[
                        TextSpanOut(
                            index=span.index,
                            text=span.text,
                            bbox=list(span.bbox),
                            font=span.font,
                            size=span.size,
                            color=span.color,
                            substitute_font=span.substitute_font,
                            added=span.added,
                        )
                        for span in page.spans
                    ],
                    images=[
                        ImageOut(
                            index=image.index,
                            bbox=list(image.bbox),
                            width=image.width,
                            height=image.height,
                            added=image.added,
                        )
                        for image in page.images
                    ],
                )
                for page in view.pages
            ],
        )


class ReplaceTextIn(BaseModel):
    page: int = Field(ge=1)
    span: int = Field(ge=0)
    text: str = Field(max_length=2000)


class DeleteObjectIn(BaseModel):
    page: int = Field(ge=1)
    index: int = Field(ge=0)


class AddTextIn(BaseModel):
    page: int = Field(ge=1)
    text: str = Field(min_length=1, max_length=2000)
    # The baseline's left end, in PDF points from the page's top-left.
    x: float = Field(ge=0)
    y: float = Field(ge=0)
    size: float = Field(default=14, ge=4, le=400)
    color: str = Field(default="#000000", pattern=HEX_COLOR)


class MoveIn(BaseModel):
    """A drag, expressed as a delta rather than a destination.

    Deltas replay correctly on top of earlier moves; an absolute position
    recorded against a stale layout would jump the object back.
    """

    page: int = Field(ge=1)
    index: int = Field(ge=0)
    dx: float
    dy: float


class StyleTextIn(BaseModel):
    page: int = Field(ge=1)
    index: int = Field(ge=0)
    size: float | None = Field(default=None, ge=4, le=400)
    color: str | None = Field(default=None, pattern=HEX_COLOR)


class ScaleImageIn(BaseModel):
    page: int = Field(ge=1)
    index: int = Field(ge=0)
    scale: float = Field(gt=0.05, le=20)
