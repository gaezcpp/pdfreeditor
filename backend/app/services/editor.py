"""Editor sessions: hold a document open, accumulate edits, then save once.

Lifecycle
---------
``open_session`` stores the upload under ``var/sessions/<id>/original.pdf`` and
reads its objects. Each edit appends to the session's operation log and bumps a
revision. Renders and the final save are built by replaying that log onto the
original, with the built file cached per revision so repeated renders are free.

Quota is charged on **save**, never on opening or previewing — one saved
document is one edit, however many tweaks it took to get there.

This is a deliberate exception to the project's "delete the upload as soon as
the request ends" rule: an editor cannot work that way. The mitigations are a
hard TTL, per-user ownership checks on every call, deletion on save or discard,
and a sweep of expired sessions at startup.
"""

from __future__ import annotations

import logging
import shutil
import uuid
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path

from anyio import to_thread
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.errors import (
    ConflictError,
    InvalidPdfError,
    NotFoundError,
    PdfProcessingError,
)
from app.core.timeutils import utcnow
from app.models.edit_session import EditSession
from app.models.user import User
from app.services.pdf import document
from app.services.pdf.operations import inspect as inspect_pdf

logger = logging.getLogger(__name__)

ORIGINAL_NAME = "original.pdf"
ASSETS_DIR = "assets"


@dataclass(frozen=True)
class SessionView:
    """A session plus the object model of its current, edited state."""

    session: EditSession
    pages: list[document.PageContents]


def session_root(session_id: uuid.UUID) -> Path:
    return settings.session_path / str(session_id)


def original_path(session_id: uuid.UUID) -> Path:
    return session_root(session_id) / ORIGINAL_NAME


def asset_dir(session_id: uuid.UUID) -> Path:
    path = session_root(session_id) / ASSETS_DIR
    path.mkdir(parents=True, exist_ok=True)
    return path


async def open_session(
    db: AsyncSession,
    user: User,
    *,
    source: Path,
    filename: str,
) -> SessionView:
    """Take ownership of an uploaded PDF and start editing it."""
    info = await to_thread.run_sync(inspect_pdf, source)

    session = EditSession(
        user_id=user.id,
        original_filename=filename,
        page_count=info.page_count,
        operations_json="[]",
        revision=0,
        expires_at=utcnow() + timedelta(minutes=settings.session_ttl_minutes),
    )
    db.add(session)
    await db.flush()

    root = session_root(session.id)
    root.mkdir(parents=True, exist_ok=True)
    await to_thread.run_sync(shutil.copyfile, source, root / ORIGINAL_NAME)

    return await view(session)


async def load_session(
    db: AsyncSession, user: User, session_id: uuid.UUID
) -> EditSession:
    """Fetch a session the user owns, or explain why it cannot be used."""
    result = await db.execute(
        select(EditSession).where(
            EditSession.id == session_id,
            EditSession.user_id == user.id,
        )
    )
    session = result.scalar_one_or_none()
    if session is None:
        raise NotFoundError("This editing session no longer exists.")
    if not session.is_open_at(utcnow()):
        raise ConflictError(
            "This editing session has ended. Open the document again to keep editing."
        )
    if not original_path(session.id).is_file():
        raise ConflictError("The document for this session is no longer available.")
    return session


async def view(session: EditSession) -> SessionView:
    """The session's object model as it currently stands, edits included.

    Projected from the untouched original plus the edit log, never parsed back
    out of the rendered PDF. Re-reading the render would renumber everything
    after a deletion, and the next edit would land on the wrong object.
    """
    pages = await to_thread.run_sync(_project_current, session)
    return SessionView(session=session, pages=pages)


async def next_object_id(session: EditSession, page_number: int) -> int:
    """An id for an object about to be added, unique for this document."""
    pages = await to_thread.run_sync(_project_current, session)
    return document.next_object_id(pages, page_number)


async def add_operation(
    db: AsyncSession, session: EditSession, operation: dict
) -> SessionView:
    operations = session.operations
    if len(operations) >= settings.max_session_operations:
        raise ConflictError(
            f"This session has reached its limit of "
            f"{settings.max_session_operations} edits. Save and reopen to continue."
        )

    operations.append(operation)
    return await _apply(db, session, operations)


async def undo(db: AsyncSession, session: EditSession) -> SessionView:
    operations = session.operations
    if not operations:
        raise ConflictError("There is nothing to undo.")

    operations.pop()
    return await _apply(db, session, operations)


async def reset(db: AsyncSession, session: EditSession) -> SessionView:
    return await _apply(db, session, [])


async def render(session: EditSession, page_number: int, *, dpi: int) -> bytes:
    dpi = max(48, min(dpi, settings.render_max_dpi))
    return await to_thread.run_sync(_render_built, session, page_number, dpi)


async def build(session: EditSession) -> Path:
    """The path to the document with every pending edit applied."""
    return await to_thread.run_sync(built_path, session)


async def _apply(
    db: AsyncSession, session: EditSession, operations: list[dict]
) -> SessionView:
    # Rebuilding the PDF is CPU work; keep it off the event loop.
    await to_thread.run_sync(_commit_operations, session, operations)
    await db.flush()
    return await view(session)


def _original_contents(session: EditSession) -> list[document.PageContents]:
    return document.read_contents(original_path(session.id))


def _project_current(session: EditSession) -> list[document.PageContents]:
    return document.project(_original_contents(session), session.operations)


def _render_built(session: EditSession, page_number: int, dpi: int) -> bytes:
    return document.render_page(built_path(session), page_number, dpi=dpi)


def built_path(session: EditSession) -> Path:
    """The document with every pending edit applied, rebuilt only when stale.

    Revision 0 is the original itself, so an untouched session costs nothing.
    """
    root = session_root(session.id)
    source = root / ORIGINAL_NAME
    if session.revision == 0:
        return source

    target = root / f"build-{session.revision}.pdf"
    if target.is_file():
        return target

    document.apply_operations(
        source, target, session.operations, asset_dir=asset_dir(session.id)
    )
    _drop_stale_builds(root, keep=target.name)
    return target


async def store_asset(session: EditSession, data: bytes, suffix: str) -> str:
    """Save a replacement image inside the session and return its handle."""
    if len(data) > settings.max_image_upload_bytes:
        limit_mb = settings.max_image_upload_bytes // (1024 * 1024)
        raise InvalidPdfError(f"Images must be {limit_mb} MB or smaller.")
    if not data:
        raise InvalidPdfError("That image file is empty.")

    name = f"{uuid.uuid4().hex}{suffix}"
    (asset_dir(session.id) / name).write_bytes(data)
    return name


async def probe_asset(session: EditSession, asset: str) -> tuple[int, int]:
    """The pixel size of a stored asset, for placing it at the right shape."""
    path = asset_dir(session.id) / Path(asset).name
    return await to_thread.run_sync(document.probe_image, path)


async def close(db: AsyncSession, session: EditSession) -> None:
    """End a session and delete everything it was holding."""
    session.closed_at = utcnow()
    await db.flush()
    discard_files(session.id)


def discard_files(session_id: uuid.UUID) -> None:
    shutil.rmtree(session_root(session_id), ignore_errors=True)


async def sweep_expired(db: AsyncSession) -> int:
    """Close sessions past their TTL and delete their files.

    Correctness does not depend on this — ``load_session`` already refuses an
    expired session. It is what stops the disk filling up.
    """
    now = utcnow()
    result = await db.execute(
        select(EditSession).where(
            EditSession.closed_at.is_(None),
            EditSession.expires_at <= now,
        )
    )
    expired = list(result.scalars())
    for session in expired:
        session.closed_at = now
        discard_files(session.id)
    return len(expired)


def _commit_operations(session: EditSession, operations: list[dict]) -> None:
    previous_operations = session.operations_json
    previous_revision = session.revision

    session.operations = operations
    session.revision += 1

    # Build now so a bad edit fails on the request that made it, not later at
    # save time. On failure the session is restored exactly as it was.
    try:
        built_path(session)
    except (InvalidPdfError, PdfProcessingError):
        session.operations_json = previous_operations
        session.revision = previous_revision
        raise


def _drop_stale_builds(root: Path, *, keep: str) -> None:
    for path in root.glob("build-*.pdf"):
        if path.name != keep:
            try:
                path.unlink()
            except OSError:  # pragma: no cover - best effort
                logger.debug("Could not remove stale build %s", path)
