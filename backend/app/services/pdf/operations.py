"""PDF manipulation built on PyMuPDF.

Every function here is synchronous, pure with respect to the database, and
takes/returns filesystem paths — so each one can be unit-tested with nothing but
a temp directory. PyMuPDF is CPU-bound and releases no useful concurrency, so
the API layer runs these in a worker thread rather than on the event loop.
"""

from __future__ import annotations

import logging
import zipfile
from dataclasses import dataclass
from pathlib import Path

import pymupdf

from app.core.config import settings
from app.core.errors import InvalidPdfError, PdfProcessingError

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class PdfInfo:
    page_count: int
    is_encrypted: bool


def inspect(path: Path) -> PdfInfo:
    """Open a PDF far enough to validate it, without processing it.

    Rejects encrypted and oversized documents up front so a malformed or
    deliberately expensive file never reaches the processing step.
    """
    try:
        with pymupdf.open(path) as doc:
            if doc.needs_pass:
                raise InvalidPdfError(
                    "This PDF is password protected. Remove the password and try again."
                )
            page_count = doc.page_count
    except InvalidPdfError:
        raise
    except Exception as exc:
        raise InvalidPdfError("This file could not be read as a PDF.") from exc

    if page_count == 0:
        raise InvalidPdfError("This PDF has no pages.")
    if page_count > settings.max_pdf_pages:
        raise InvalidPdfError(
            f"This PDF has {page_count} pages; the limit is "
            f"{settings.max_pdf_pages}.",
            details={"page_count": page_count, "max_pages": settings.max_pdf_pages},
        )
    return PdfInfo(page_count=page_count, is_encrypted=False)


def compress(
    source: Path, destination: Path, *, image_quality: int | None = None
) -> Path:
    """Rewrite a PDF with deduplicated objects and recompressed streams.

    ``image_quality`` (1-100) additionally re-encodes embedded images as JPEG,
    which is where the real savings are in scanned documents — at the cost of
    being lossy, so it stays opt-in.
    """
    try:
        with pymupdf.open(source) as doc:
            if image_quality is not None:
                _recompress_images(doc, image_quality)
            doc.save(
                destination,
                garbage=4,          # drop unreferenced objects
                deflate=True,
                deflate_images=True,
                deflate_fonts=True,
                clean=True,
                linear=True,        # web-optimized byte order
            )
    except Exception as exc:
        raise PdfProcessingError("Could not compress this PDF.") from exc
    return destination


def merge(sources: list[Path], destination: Path) -> Path:
    if len(sources) < 2:
        raise InvalidPdfError("Merging needs at least two files.")
    try:
        with pymupdf.open() as out:
            for source in sources:
                with pymupdf.open(source) as doc:
                    out.insert_pdf(doc)
            out.save(destination, garbage=4, deflate=True)
    except Exception as exc:
        raise PdfProcessingError("Could not merge these PDFs.") from exc
    return destination


def extract_pages(source: Path, destination: Path, *, pages: list[int]) -> Path:
    """Build a new PDF from ``pages`` (1-based, in the order given)."""
    try:
        with pymupdf.open(source) as doc, pymupdf.open() as out:
            for page_number in pages:
                index = page_number - 1
                out.insert_pdf(doc, from_page=index, to_page=index)
            out.save(destination, garbage=4, deflate=True)
    except Exception as exc:
        raise PdfProcessingError("Could not split this PDF.") from exc
    return destination


def split_to_zip(
    source: Path,
    destination: Path,
    *,
    ranges: list[list[int]],
    part_paths: list[Path],
    stem: str = "part",
) -> Path:
    """Write one PDF per range and bundle them into a single ZIP.

    ``part_paths`` is supplied by the caller (one per range) so the temp
    workspace owns every intermediate file and can delete them afterwards.
    """
    if len(part_paths) < len(ranges):
        raise PdfProcessingError("Not enough temp slots for the requested ranges.")

    for pages, part_path in zip(ranges, part_paths, strict=False):
        extract_pages(source, part_path, pages=pages)

    try:
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
            for index, part_path in enumerate(part_paths[: len(ranges)], start=1):
                archive.write(part_path, arcname=f"{stem}-{index}.pdf")
    except OSError as exc:
        raise PdfProcessingError("Could not package the split files.") from exc
    return destination


def add_text(
    source: Path,
    destination: Path,
    *,
    page_number: int,
    text: str,
    x: float,
    y: float,
    font_size: float = 12.0,
    color: tuple[float, float, float] = (0.0, 0.0, 0.0),
    font_name: str = "helv",
) -> Path:
    """Stamp text onto one page. ``x``/``y`` are PDF points from the top-left."""
    try:
        with pymupdf.open(source) as doc:
            if not 1 <= page_number <= doc.page_count:
                raise InvalidPdfError(
                    f"Page {page_number} does not exist; this PDF has "
                    f"{doc.page_count} pages."
                )
            page = doc[page_number - 1]
            page.insert_text(
                pymupdf.Point(x, y),
                text,
                fontsize=font_size,
                fontname=font_name,
                color=color,
            )
            doc.save(destination, garbage=4, deflate=True)
    except InvalidPdfError:
        raise
    except Exception as exc:
        raise PdfProcessingError("Could not add text to this PDF.") from exc
    return destination


def _recompress_images(doc: pymupdf.Document, quality: int) -> None:
    quality = max(1, min(quality, 100))
    for page in doc:
        for image in page.get_images(full=True):
            xref = image[0]
            try:
                pixmap = pymupdf.Pixmap(doc, xref)
                if pixmap.alpha or pixmap.colorspace is None or pixmap.n > 3:
                    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pixmap)
                jpeg = pixmap.tobytes("jpeg", jpg_quality=quality)
                pixmap = None
                # replace_image rewrites the stream *and* its filter metadata;
                # update_stream alone would leave the object describing itself
                # as the old codec.
                page.replace_image(xref, stream=jpeg)
            except Exception:  # noqa: S112
                # A single unconvertible image should not fail the whole job.
                logger.debug("Skipped image xref %s during recompression", xref)
                continue
