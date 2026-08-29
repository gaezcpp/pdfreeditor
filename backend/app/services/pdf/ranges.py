"""Parsing of user-supplied page selections like ``"1-3,7,10-12"``.

Kept separate from the PDF operations so the (fiddly, off-by-one-prone) parsing
rules can be tested without opening a document.
"""

from __future__ import annotations

from app.core.errors import InvalidPdfError

MAX_RANGES = 50


def parse_ranges(spec: str, *, page_count: int) -> list[list[int]]:
    """Return one list of 1-based page numbers per comma-separated group.

    ``"1-3,7"`` over a 10-page document yields ``[[1, 2, 3], [7]]``. Descending
    bounds (``5-2``) are accepted and produce pages in reverse order, which is
    the least surprising reading of what the user typed.
    """
    groups = [chunk.strip() for chunk in spec.split(",") if chunk.strip()]
    if not groups:
        raise InvalidPdfError("No pages selected.")
    if len(groups) > MAX_RANGES:
        raise InvalidPdfError(f"At most {MAX_RANGES} ranges can be requested at once.")

    parsed: list[list[int]] = []
    for group in groups:
        parsed.append(_parse_group(group, page_count=page_count))
    return parsed


def flatten(ranges: list[list[int]]) -> list[int]:
    return [page for group in ranges for page in group]


def _parse_group(group: str, *, page_count: int) -> list[int]:
    if "-" in group:
        raw_start, _, raw_end = group.partition("-")
        start = _parse_page(raw_start, group, page_count)
        end = _parse_page(raw_end, group, page_count)
        step = 1 if end >= start else -1
        return list(range(start, end + step, step))

    return [_parse_page(group, group, page_count)]


def _parse_page(raw: str, group: str, page_count: int) -> int:
    raw = raw.strip()
    if not raw.isdigit():
        raise InvalidPdfError(f"'{group[:20]}' is not a valid page range.")
    page = int(raw)
    if not 1 <= page <= page_count:
        raise InvalidPdfError(
            f"Page {page} is out of range; this PDF has {page_count} pages.",
            details={"page_count": page_count},
        )
    return page
