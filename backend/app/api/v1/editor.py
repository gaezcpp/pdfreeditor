"""WYSIWYG editing endpoints.

Opening a session and previewing edits are free; the quota is charged once, on
save. Every call re-checks that the session belongs to the caller — a session id
on its own grants nothing.

The CPU work (PyMuPDF rebuilds the document on every edit) is offloaded inside
``services.editor``, so these handlers stay thin.
"""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, File, Query, Response, UploadFile, status
from fastapi.responses import FileResponse

from app.api.deps import CurrentUser, DbSession
from app.core.errors import InvalidPdfError
from app.models.enums import PdfAction
from app.schemas.editor import (
    AddTextIn,
    DeleteObjectIn,
    MoveIn,
    ReplaceTextIn,
    ScaleImageIn,
    SessionOut,
    StyleTextIn,
)
from app.services import editor
from app.services.edit_pipeline import EditResult, run_edit
from app.services.pdf.storage import TempWorkspace, save_upload

router = APIRouter(prefix="/editor", tags=["editor"])

ALLOWED_IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}

# A comfortable default width in PDF points for a newly placed image; the
# height follows from the file's own aspect ratio.
DEFAULT_IMAGE_WIDTH = 200.0


def _require_image_suffix(filename: str | None) -> str:
    suffix = Path(filename or "").suffix.lower()
    if suffix not in ALLOWED_IMAGE_SUFFIXES:
        raise InvalidPdfError("Choose a PNG, JPEG, or WebP image.")
    return suffix


@router.post(
    "/sessions", response_model=SessionOut, status_code=status.HTTP_201_CREATED
)
async def open_session(
    user: CurrentUser,
    db: DbSession,
    file: Annotated[UploadFile, File(description="The PDF to edit.")],
) -> SessionOut:
    """Upload a document and read back everything on it that can be edited."""
    with TempWorkspace() as workspace:
        source, _ = await save_upload(file, workspace)
        view = await editor.open_session(
            db, user, source=source, filename=file.filename or "document.pdf"
        )
    await db.commit()
    return SessionOut.from_view(view)


@router.get("/sessions/{session_id}", response_model=SessionOut)
async def read_session(
    session_id: uuid.UUID, user: CurrentUser, db: DbSession
) -> SessionOut:
    session = await editor.load_session(db, user, session_id)
    return SessionOut.from_view(await editor.view(session))


@router.get("/sessions/{session_id}/pages/{page_number}", response_class=Response)
async def render_page(
    session_id: uuid.UUID,
    page_number: int,
    user: CurrentUser,
    db: DbSession,
    dpi: Annotated[int, Query(ge=48, le=200)] = 110,
) -> Response:
    """The page as a PNG, with pending edits applied — the editor's canvas."""
    session = await editor.load_session(db, user, session_id)
    png = await editor.render(session, page_number, dpi=dpi)
    return Response(
        content=png,
        media_type="image/png",
        # The revision tells the client whether what it is looking at is current.
        headers={"Cache-Control": "no-store", "X-Revision": str(session.revision)},
    )


@router.post("/sessions/{session_id}/text", response_model=SessionOut)
async def replace_text(
    session_id: uuid.UUID, payload: ReplaceTextIn, user: CurrentUser, db: DbSession
) -> SessionOut:
    """Change the words in one text object, keeping its place, size, and colour.

    Clearing the text is the same as deleting the object, which is what a user
    who selects-all-and-deletes expects.
    """
    session = await editor.load_session(db, user, session_id)
    view = await editor.add_operation(
        db,
        session,
        {
            "type": "replace_text" if payload.text.strip() else "delete_text",
            "page": payload.page,
            "span": payload.span,
            "text": payload.text,
        },
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/text/delete", response_model=SessionOut)
async def delete_text(
    session_id: uuid.UUID, payload: DeleteObjectIn, user: CurrentUser, db: DbSession
) -> SessionOut:
    session = await editor.load_session(db, user, session_id)
    view = await editor.add_operation(
        db,
        session,
        {"type": "delete_text", "page": payload.page, "span": payload.index},
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/text/add", response_model=SessionOut)
async def add_text(
    session_id: uuid.UUID, payload: AddTextIn, user: CurrentUser, db: DbSession
) -> SessionOut:
    session = await editor.load_session(db, user, session_id)
    view = await editor.add_operation(
        db,
        session,
        {
            "type": "add_text",
            "page": payload.page,
            # Assigned now and stored in the operation, so the new run keeps the
            # same handle every time the log is replayed.
            "id": await editor.next_object_id(session, payload.page),
            "text": payload.text,
            "x": payload.x,
            "y": payload.y,
            "size": payload.size,
            "color": payload.color,
        },
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/images/delete", response_model=SessionOut)
async def delete_image(
    session_id: uuid.UUID, payload: DeleteObjectIn, user: CurrentUser, db: DbSession
) -> SessionOut:
    session = await editor.load_session(db, user, session_id)
    view = await editor.add_operation(
        db,
        session,
        {"type": "delete_image", "page": payload.page, "image": payload.index},
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/images/replace", response_model=SessionOut)
async def replace_image(
    session_id: uuid.UUID,
    user: CurrentUser,
    db: DbSession,
    page: Annotated[int, Query(ge=1)],
    index: Annotated[int, Query(ge=0)],
    file: Annotated[UploadFile, File(description="PNG, JPEG, or WebP.")],
) -> SessionOut:
    """Swap one image for another, keeping the original's position and size."""
    session = await editor.load_session(db, user, session_id)

    suffix = _require_image_suffix(file.filename)

    asset = await editor.store_asset(session, await file.read(), suffix)
    pixels_wide, pixels_high = await editor.probe_asset(session, asset)
    view = await editor.add_operation(
        db,
        session,
        {
            "type": "replace_image",
            "page": page,
            "image": index,
            "asset": asset,
            "width": pixels_wide,
            "height": pixels_high,
        },
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/text/move", response_model=SessionOut)
async def move_text(
    session_id: uuid.UUID, payload: MoveIn, user: CurrentUser, db: DbSession
) -> SessionOut:
    """Drag a text run to a new place on the page."""
    session = await editor.load_session(db, user, session_id)
    view = await editor.add_operation(
        db,
        session,
        {
            "type": "move_text",
            "page": payload.page,
            "span": payload.index,
            "dx": payload.dx,
            "dy": payload.dy,
        },
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/text/style", response_model=SessionOut)
async def style_text(
    session_id: uuid.UUID, payload: StyleTextIn, user: CurrentUser, db: DbSession
) -> SessionOut:
    """Change a run's font size or colour, leaving its words and baseline."""
    session = await editor.load_session(db, user, session_id)
    view = await editor.add_operation(
        db,
        session,
        {
            "type": "style_text",
            "page": payload.page,
            "span": payload.index,
            "size": payload.size,
            "color": payload.color,
        },
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/images/move", response_model=SessionOut)
async def move_image(
    session_id: uuid.UUID, payload: MoveIn, user: CurrentUser, db: DbSession
) -> SessionOut:
    session = await editor.load_session(db, user, session_id)
    view = await editor.add_operation(
        db,
        session,
        {
            "type": "move_image",
            "page": payload.page,
            "image": payload.index,
            "dx": payload.dx,
            "dy": payload.dy,
        },
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/images/scale", response_model=SessionOut)
async def scale_image(
    session_id: uuid.UUID, payload: ScaleImageIn, user: CurrentUser, db: DbSession
) -> SessionOut:
    """Resize an image about its top-left, so it grows without also moving."""
    session = await editor.load_session(db, user, session_id)
    view = await editor.add_operation(
        db,
        session,
        {
            "type": "scale_image",
            "page": payload.page,
            "image": payload.index,
            "scale": payload.scale,
        },
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/images/add", response_model=SessionOut)
async def add_image(
    session_id: uuid.UUID,
    user: CurrentUser,
    db: DbSession,
    page: Annotated[int, Query(ge=1)],
    x: Annotated[float, Query(ge=0)],
    y: Annotated[float, Query(ge=0)],
    file: Annotated[UploadFile, File(description="PNG, JPEG, or WebP.")],
    width: Annotated[float | None, Query(gt=0, le=2000)] = None,
) -> SessionOut:
    """Place a new image on the page, sized to keep its aspect ratio."""
    session = await editor.load_session(db, user, session_id)
    suffix = _require_image_suffix(file.filename)

    asset = await editor.store_asset(session, await file.read(), suffix)
    pixels_wide, pixels_high = await editor.probe_asset(session, asset)

    box_width = width or DEFAULT_IMAGE_WIDTH
    box_height = box_width * (pixels_high / pixels_wide)

    view = await editor.add_operation(
        db,
        session,
        {
            "type": "add_image",
            "page": page,
            "id": await editor.next_object_id(session, page),
            "asset": asset,
            "x": x,
            "y": y,
            "width": box_width,
            "height": box_height,
        },
    )
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/undo", response_model=SessionOut)
async def undo(session_id: uuid.UUID, user: CurrentUser, db: DbSession) -> SessionOut:
    session = await editor.load_session(db, user, session_id)
    view = await editor.undo(db, session)
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/reset", response_model=SessionOut)
async def reset(session_id: uuid.UUID, user: CurrentUser, db: DbSession) -> SessionOut:
    session = await editor.load_session(db, user, session_id)
    view = await editor.reset(db, session)
    await db.commit()
    return SessionOut.from_view(view)


@router.post("/sessions/{session_id}/save", response_class=FileResponse)
async def save(session_id: uuid.UUID, user: CurrentUser, db: DbSession) -> FileResponse:
    """Charge one edit, download the result, and end the session."""
    session = await editor.load_session(db, user, session_id)
    filename = _saved_name(session.original_filename)
    page_count = session.page_count

    async def produce(workspace: TempWorkspace) -> EditResult:
        built = await editor.build(session)
        destination = workspace.new_path()
        # Copy out of the session folder: the response streams after the session
        # (and its directory) has been deleted.
        destination.write_bytes(built.read_bytes())
        return EditResult(
            path=destination,
            filename=filename,
            page_count=page_count,
            input_bytes=destination.stat().st_size,
        )

    response = await run_edit(db, user, action=PdfAction.EDIT, produce=produce)
    await editor.close(db, session)
    await db.commit()
    return response


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def discard(session_id: uuid.UUID, user: CurrentUser, db: DbSession) -> Response:
    """Throw the session away without saving."""
    session = await editor.load_session(db, user, session_id)
    await editor.close(db, session)
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _saved_name(original: str) -> str:
    stem = Path(original).stem or "document"
    cleaned = "".join(ch for ch in stem if ch.isalnum() or ch in "-_ ").strip()
    return f"{(cleaned or 'document')[:60]}-edited.pdf"
