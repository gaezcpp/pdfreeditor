"""PDF editing endpoints.

All four follow the same shape: validate cheaply, then hand a ``produce``
callback to :func:`app.services.edit_session.run_edit`, which owns quota,
logging, and temp-file lifetime. PyMuPDF calls go through ``run_in_threadpool``
so a large document cannot stall the event loop for every other request.
"""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, File, Form, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse

from app.api.deps import CurrentUser, DbSession
from app.core.config import settings
from app.core.errors import InvalidPdfError
from app.models.enums import PdfAction
from app.services.edit_pipeline import EditResult, run_edit
from app.services.pdf import operations, ranges
from app.services.pdf.storage import TempWorkspace, save_upload

router = APIRouter(prefix="/pdf", tags=["pdf"])


async def _page_operation(
    *, user, db, file, action: PdfAction, pages: list[int], operation, suffix: str
) -> FileResponse:
    async def produce(workspace: TempWorkspace) -> EditResult:
        source, size = await save_upload(file, workspace)
        info = await run_in_threadpool(operations.inspect, source)
        destination = workspace.new_path()
        await run_in_threadpool(operation, source, destination, pages=pages)
        return EditResult(
            path=destination,
            filename=_output_name(file, suffix),
            page_count=info.page_count,
            input_bytes=size,
        )

    return await run_edit(db, user, action=action, produce=produce)


def _parse_pages(value: str, page_count: int) -> list[int]:
    groups = ranges.parse_ranges(value, page_count=page_count)
    return [page for group in groups for page in group]


@router.post("/rotate", response_class=FileResponse)
async def rotate(
    user: CurrentUser, db: DbSession,
    file: Annotated[UploadFile, File()],
    pages: Annotated[str, Form(min_length=1, max_length=500)],
    degrees: Annotated[int, Form()] = 90,
) -> FileResponse:
    async def operation(source, destination, *, pages):
        await run_in_threadpool(
            operations.rotate_pages,
            source,
            destination,
            pages=pages,
            degrees=degrees,
        )

    async def produce(workspace):
        source, size = await save_upload(file, workspace)
        info = await run_in_threadpool(operations.inspect, source)
        destination = workspace.new_path()
        page_list = _parse_pages(pages, info.page_count)
        await operation(source, destination, pages=page_list)
        return EditResult(
            path=destination,
            filename=_output_name(file, "rotated"),
            page_count=info.page_count,
            input_bytes=size,
        )

    return await run_edit(db, user, action=PdfAction.ROTATE, produce=produce)


@router.post("/delete-pages", response_class=FileResponse)
async def delete_pages(
    user: CurrentUser, db: DbSession,
    file: Annotated[UploadFile, File()],
    pages: Annotated[str, Form(min_length=1, max_length=500)],
) -> FileResponse:
    async def produce(workspace):
        source, size = await save_upload(file, workspace)
        info = await run_in_threadpool(operations.inspect, source)
        destination = workspace.new_path()
        page_list = _parse_pages(pages, info.page_count)
        await run_in_threadpool(
            operations.delete_pages, source, destination, pages=page_list
        )
        return EditResult(
            path=destination,
            filename=_output_name(file, "trimmed"),
            page_count=info.page_count - len(set(page_list)),
            input_bytes=size,
        )

    return await run_edit(db, user, action=PdfAction.DELETE_PAGES, produce=produce)


@router.post("/reorder-pages", response_class=FileResponse)
async def reorder_pages(
    user: CurrentUser, db: DbSession,
    file: Annotated[UploadFile, File()],
    order: Annotated[str, Form(min_length=1, max_length=2000)],
) -> FileResponse:
    async def produce(workspace):
        source, size = await save_upload(file, workspace)
        info = await run_in_threadpool(operations.inspect, source)
        destination = workspace.new_path()
        try:
            page_order = [int(item.strip()) for item in order.split(",")]
        except ValueError as exc:
            raise InvalidPdfError("Order must be comma-separated page numbers.") from exc
        await run_in_threadpool(
            operations.reorder_pages, source, destination, order=page_order
        )
        return EditResult(
            path=destination,
            filename=_output_name(file, "reordered"),
            page_count=info.page_count,
            input_bytes=size,
        )

    return await run_edit(db, user, action=PdfAction.REORDER_PAGES, produce=produce)


@router.post("/compress", response_class=FileResponse)
async def compress(
    user: CurrentUser,
    db: DbSession,
    file: Annotated[UploadFile, File(description="The PDF to compress.")],
    image_quality: Annotated[
        int | None,
        Form(
            ge=1,
            le=100,
            description="Re-encode images as JPEG at this quality (lossy).",
        ),
    ] = None,
) -> FileResponse:
    async def produce(workspace: TempWorkspace) -> EditResult:
        source, size = await save_upload(file, workspace)
        info = await run_in_threadpool(operations.inspect, source)
        destination = workspace.new_path()
        await run_in_threadpool(
            operations.compress, source, destination, image_quality=image_quality
        )
        return EditResult(
            path=destination,
            filename=_output_name(file, "compressed"),
            page_count=info.page_count,
            input_bytes=size,
        )

    return await run_edit(db, user, action=PdfAction.COMPRESS, produce=produce)


@router.post("/merge", response_class=FileResponse)
async def merge(
    user: CurrentUser,
    db: DbSession,
    files: Annotated[list[UploadFile], File(description="Two or more PDFs, in order.")],
) -> FileResponse:
    if len(files) < 2:
        raise InvalidPdfError("Select at least two PDFs to merge.")
    if len(files) > settings.max_merge_files:
        raise InvalidPdfError(
            f"At most {settings.max_merge_files} files can be merged at once.",
            details={"max_files": settings.max_merge_files},
        )

    async def produce(workspace: TempWorkspace) -> EditResult:
        sources: list[Path] = []
        total_bytes = 0
        total_pages = 0
        for upload in files:
            path, size = await save_upload(upload, workspace)
            info = await run_in_threadpool(operations.inspect, path)
            sources.append(path)
            total_bytes += size
            total_pages += info.page_count

        if total_pages > settings.max_pdf_pages:
            raise InvalidPdfError(
                f"The merged document would have {total_pages} pages; the limit "
                f"is {settings.max_pdf_pages}.",
                details={"page_count": total_pages},
            )

        destination = workspace.new_path()
        await run_in_threadpool(operations.merge, sources, destination)
        return EditResult(
            path=destination,
            filename="merged.pdf",
            page_count=total_pages,
            input_bytes=total_bytes,
        )

    return await run_edit(db, user, action=PdfAction.MERGE, produce=produce)


@router.post("/split", response_class=FileResponse)
async def split(
    user: CurrentUser,
    db: DbSession,
    file: Annotated[UploadFile, File(description="The PDF to split.")],
    page_ranges: Annotated[
        str,
        Form(
            min_length=1,
            max_length=500,
            description='Comma-separated 1-based ranges, e.g. "1-3,7,10-12".',
        ),
    ],
) -> FileResponse:
    """Extract pages. One range returns a PDF; several return a ZIP of parts."""

    async def produce(workspace: TempWorkspace) -> EditResult:
        source, size = await save_upload(file, workspace)
        info = await run_in_threadpool(operations.inspect, source)
        groups = ranges.parse_ranges(page_ranges, page_count=info.page_count)

        if len(groups) == 1:
            destination = workspace.new_path()
            pages = groups[0]
            await run_in_threadpool(
                operations.extract_pages, source, destination, pages=pages
            )
            return EditResult(
                path=destination,
                filename=_output_name(file, "pages"),
                page_count=len(pages),
                input_bytes=size,
            )

        destination = workspace.new_path(".zip")
        part_paths = [workspace.new_path() for _ in groups]
        await run_in_threadpool(
            operations.split_to_zip,
            source,
            destination,
            ranges=groups,
            part_paths=part_paths,
            stem=Path(_output_name(file, "part")).stem,
        )
        return EditResult(
            path=destination,
            filename=f"{_stem(file)}-split.zip",
            media_type="application/zip",
            page_count=sum(len(group) for group in groups),
            input_bytes=size,
        )

    return await run_edit(db, user, action=PdfAction.SPLIT, produce=produce)


@router.post("/add-text", response_class=FileResponse)
async def add_text(
    user: CurrentUser,
    db: DbSession,
    file: Annotated[UploadFile, File(description="The PDF to stamp.")],
    text: Annotated[str, Form(min_length=1, max_length=2000)],
    page: Annotated[int, Form(ge=1, description="1-based page number.")],
    x: Annotated[float, Form(ge=0, description="Points from the left edge.")],
    y: Annotated[float, Form(ge=0, description="Points from the top edge.")],
    font_size: Annotated[float, Form(gt=0, le=400)] = 12.0,
    color: Annotated[
        str, Form(pattern=r"^#?[0-9a-fA-F]{6}$", description="Hex RGB, e.g. #1a1a1a.")
    ] = "#000000",
) -> FileResponse:
    rgb = _hex_to_rgb(color)

    async def produce(workspace: TempWorkspace) -> EditResult:
        source, size = await save_upload(file, workspace)
        info = await run_in_threadpool(operations.inspect, source)
        destination = workspace.new_path()
        await run_in_threadpool(
            lambda: operations.add_text(
                source,
                destination,
                page_number=page,
                text=text,
                x=x,
                y=y,
                font_size=font_size,
                color=rgb,
            )
        )
        return EditResult(
            path=destination,
            filename=_output_name(file, "edited"),
            page_count=info.page_count,
            input_bytes=size,
        )

    return await run_edit(db, user, action=PdfAction.ADD_TEXT, produce=produce)


def _stem(upload: UploadFile) -> str:
    """A safe stem for the download name — never trust the client's path."""
    raw = (upload.filename or "document").replace("\\", "/").split("/")[-1]
    stem = Path(raw).stem or "document"
    cleaned = "".join(ch for ch in stem if ch.isalnum() or ch in "-_ ").strip()
    return (cleaned or "document")[:60]


def _output_name(upload: UploadFile, suffix: str) -> str:
    return f"{_stem(upload)}-{suffix}.pdf"


def _hex_to_rgb(value: str) -> tuple[float, float, float]:
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) / 255 for i in (0, 2, 4))  # type: ignore[return-value]
