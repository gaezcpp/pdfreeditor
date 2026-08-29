"""Temporary file handling for uploads and results.

Uploads are streamed to disk in chunks and hard-capped mid-stream, so a 5 GB
upload is aborted after the first megabyte over the limit instead of being
buffered in memory first. Every path handed out here is registered on a
``TempWorkspace`` whose ``cleanup`` deletes the lot — including the response
file, which is deleted by a Starlette background task after the bytes are sent.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from fastapi import UploadFile

from app.core.config import settings
from app.core.errors import InvalidPdfError, PayloadTooLargeError

logger = logging.getLogger(__name__)

CHUNK_SIZE = 1024 * 1024
PDF_MAGIC = b"%PDF-"


@dataclass
class TempWorkspace:
    """Owns every temp path created for a single request."""

    request_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    paths: list[Path] = field(default_factory=list)

    def new_path(self, suffix: str = ".pdf") -> Path:
        path = settings.temp_path / f"{self.request_id}-{uuid.uuid4().hex}{suffix}"
        self.paths.append(path)
        return path

    def cleanup(self) -> None:
        for path in self.paths:
            try:
                path.unlink(missing_ok=True)
            except OSError:  # pragma: no cover - best effort, never fail a request
                logger.warning("Could not delete temp file %s", path, exc_info=True)
        self.paths.clear()

    def __enter__(self) -> TempWorkspace:
        return self

    def __exit__(self, *_exc: object) -> None:
        self.cleanup()


async def save_upload(
    upload: UploadFile,
    workspace: TempWorkspace,
    *,
    max_bytes: int | None = None,
) -> tuple[Path, int]:
    """Stream an upload to a temp file. Returns (path, size_in_bytes).

    Raises before the whole body is read if it exceeds the cap, and rejects
    anything that does not start with the PDF magic bytes — the declared
    content-type is client-supplied and cannot be trusted.
    """
    max_bytes = max_bytes or settings.max_upload_bytes
    path = workspace.new_path()
    size = 0
    first_chunk = True

    with path.open("wb") as buffer:
        while chunk := await upload.read(CHUNK_SIZE):
            if first_chunk:
                if not chunk.startswith(PDF_MAGIC):
                    raise InvalidPdfError(
                        f"'{_safe_name(upload)}' is not a PDF file."
                    )
                first_chunk = False

            size += len(chunk)
            if size > max_bytes:
                raise PayloadTooLargeError(
                    f"'{_safe_name(upload)}' exceeds the "
                    f"{max_bytes // (1024 * 1024)} MB upload limit.",
                    details={"max_bytes": max_bytes},
                )
            buffer.write(chunk)

    if size == 0:
        raise InvalidPdfError(f"'{_safe_name(upload)}' is empty.")

    return path, size


def _safe_name(upload: UploadFile) -> str:
    """Client-supplied filenames are echoed in errors — strip path separators."""
    name = (upload.filename or "file").replace("\\", "/").split("/")[-1]
    return name[:100] or "file"
