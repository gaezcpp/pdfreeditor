"""Object-level PDF editing: read a page's contents, and rewrite them.

This is what backs the WYSIWYG editor, and it works differently from the
whole-file tools in ``operations.py``. Those transform a document; this one
exposes the individual text runs and images on a page so the client can address
them one at a time.

Three constraints shape everything here.

**Replacing text means erasing and redrawing it.** A PDF has no editable text
model — a "word" is a positioned run of glyph codes. Changing one means
redacting the old run and drawing a new one at the same baseline.

**The original font usually cannot be reused.** Real-world PDFs embed *subsets*:
only the glyphs the document already uses, addressed by glyph id with the
unicode cmap stripped. Typing a character the subset lacks would render nothing.
So edited text is drawn in a base-14 substitute matched to the original's weight
and slant. Position, size, and colour are preserved exactly; the typeface is an
approximation.

**Object identity has to survive editing.** Indices are the handles the client
edits by, and re-reading them from an already-edited PDF makes them drift: after
deleting one run, everything below it shifts up, and the next edit lands on the
wrong object. So the current state is *projected* from the untouched original
plus the operation log — never parsed back out of the rendered result.
"""

from __future__ import annotations

import copy
import logging
from dataclasses import dataclass, field, replace
from pathlib import Path

import pymupdf

from app.core.errors import InvalidPdfError, PdfProcessingError

logger = logging.getLogger(__name__)

# Base-14 fonts are always present in any PDF reader, so a document edited here
# stays portable without embedding anything new.
_BASE14 = {
    (False, False): "helv",
    (True, False): "hebo",
    (False, True): "heit",
    (True, True): "hebi",
}

_BOLD_HINTS = ("bold", "black", "heavy", "semibold", "extrabold", "demi")
_ITALIC_HINTS = ("italic", "oblique")

MAX_TEXT_LENGTH = 2000
MIN_FONT_SIZE = 4.0
MAX_FONT_SIZE = 400.0
MIN_IMAGE_SIDE = 8.0


@dataclass(frozen=True)
class TextSpan:
    """One positioned run of text, as the editor addresses it.

    ``index`` is the stable handle. For runs that came with the document it is
    their position in the original; for runs the user added it is an id the
    server assigned when the operation was recorded.
    """

    index: int
    text: str
    bbox: tuple[float, float, float, float]
    origin: tuple[float, float]
    font: str
    size: float
    color: str  # "#rrggbb"
    added: bool = False

    @property
    def substitute_font(self) -> str:
        return substitute_font_for(self.font)


@dataclass(frozen=True)
class ImageObject:
    index: int
    xref: int  # 0 for an image the user added
    bbox: tuple[float, float, float, float]
    width: int
    height: int
    # Set when the pixels come from an uploaded file rather than the original.
    asset: str | None = None
    added: bool = False


@dataclass
class PageContents:
    number: int  # 1-based
    width: float
    height: float
    spans: list[TextSpan] = field(default_factory=list)
    images: list[ImageObject] = field(default_factory=list)


def substitute_font_for(font_name: str) -> str:
    """Pick the base-14 face closest to an embedded font's weight and slant."""
    lowered = font_name.lower()
    bold = any(hint in lowered for hint in _BOLD_HINTS)
    italic = any(hint in lowered for hint in _ITALIC_HINTS)
    return _BASE14[(bold, italic)]


def text_bbox(
    text: str,
    *,
    origin: tuple[float, float],
    size: float,
    font: str,
) -> tuple[float, float, float, float]:
    """The box a run of text will occupy, measured in the font it is drawn in.

    The client draws its selection outlines from this, so it has to match what
    actually lands on the page rather than being estimated from the old box.
    """
    face = pymupdf.Font(substitute_font_for(font))
    width = face.text_length(text, size)
    ascender = face.ascender * size
    descender = face.descender * size
    x, y = origin
    return (x, y - ascender, x + width, y - descender)


def probe_image(path: Path) -> tuple[int, int]:
    """The pixel size of an image file, for placing and reporting it."""
    try:
        pixmap = pymupdf.Pixmap(str(path))
        return pixmap.width, pixmap.height
    except Exception as exc:
        raise InvalidPdfError("That file could not be read as an image.") from exc


def read_contents(path: Path) -> list[PageContents]:
    """List every text span and image on every page, in document order."""
    try:
        with pymupdf.open(path) as doc:
            if doc.needs_pass:
                raise InvalidPdfError("This PDF is password protected.")
            return [_read_page(page, number) for number, page in enumerate(doc, 1)]
    except InvalidPdfError:
        raise
    except Exception as exc:
        raise InvalidPdfError("This file could not be read as a PDF.") from exc


def _read_page(page: pymupdf.Page, number: int) -> PageContents:
    contents = PageContents(
        number=number,
        width=page.rect.width,
        height=page.rect.height,
    )

    span_index = 0
    for block in page.get_text("dict")["blocks"]:
        if block["type"] != 0:
            continue
        for line in block["lines"]:
            for span in line["spans"]:
                contents.spans.append(
                    TextSpan(
                        index=span_index,
                        text=span["text"],
                        bbox=tuple(span["bbox"]),
                        origin=tuple(span["origin"]),
                        font=span["font"],
                        size=span["size"],
                        color=_int_to_hex(span["color"]),
                    )
                )
                span_index += 1

    # One entry per placement. A page can list the same xref more than once —
    # replacing an image leaves a second reference behind — and the editor must
    # show one box per thing the reader can see, not one per resource entry.
    seen: set[tuple[int, tuple[int, ...]]] = set()
    for info in page.get_images(full=True):
        xref = info[0]
        for rect in page.get_image_rects(xref):
            key = (xref, tuple(round(value) for value in rect))
            if key in seen:
                continue
            seen.add(key)
            contents.images.append(
                ImageObject(
                    index=len(contents.images),
                    xref=xref,
                    bbox=tuple(rect),
                    width=info[2],
                    height=info[3],
                )
            )

    return contents


# --- Projection -------------------------------------------------------------


def next_object_id(pages: list[PageContents], page_number: int) -> int:
    """An id for a newly added object that no existing one can collide with."""
    page = _find_page(pages, page_number)
    used = [span.index for span in page.spans] + [img.index for img in page.images]
    return max(used, default=-1) + 1


def project(
    pages: list[PageContents], operations: list[dict]
) -> list[PageContents]:
    """The document's current state: the original with the edit log applied.

    Pure, and deliberately independent of the rendered PDF. Deriving the view
    this way is what keeps an object's index meaning the same thing for the
    whole session, however much is deleted or added around it.
    """
    projected = copy.deepcopy(pages)
    by_number = {page.number: page for page in projected}

    for operation in operations:
        page = by_number.get(int(operation["page"]))
        if page is None:
            continue
        _project_one(page, operation)

    return projected


def _project_one(page: PageContents, operation: dict) -> None:
    kind = operation["type"]

    if kind in {"replace_text", "delete_text", "move_text", "style_text"}:
        _project_text(page, operation, kind)
    elif kind == "add_text":
        page.spans.append(_new_span(operation))
    elif kind == "delete_image":
        page.images = [
            image for image in page.images if image.index != int(operation["image"])
        ]
    elif kind in {"move_image", "scale_image", "replace_image"}:
        _project_image(page, operation, kind)
    elif kind == "add_image":
        page.images.append(_new_image(operation))


def _project_text(page: PageContents, operation: dict, kind: str) -> None:
    index = int(operation["span"])
    position = _index_of(page.spans, index)
    if position is None:
        raise InvalidPdfError(f"There is no text object {index} on this page.")

    if kind == "delete_text":
        page.spans.pop(position)
        return

    span = page.spans[position]
    text = span.text
    origin = span.origin
    size = span.size
    color = span.color

    if kind == "replace_text":
        text = str(operation["text"])[:MAX_TEXT_LENGTH]
        if not text.strip():
            page.spans.pop(position)
            return
    elif kind == "move_text":
        origin = (
            origin[0] + float(operation.get("dx", 0)),
            origin[1] + float(operation.get("dy", 0)),
        )
    elif kind == "style_text":
        if operation.get("size") is not None:
            size = _clamp(float(operation["size"]), MIN_FONT_SIZE, MAX_FONT_SIZE)
        if operation.get("color"):
            color = str(operation["color"])

    page.spans[position] = replace(
        span,
        text=text,
        origin=origin,
        size=size,
        color=color,
        bbox=text_bbox(text, origin=origin, size=size, font=span.font),
    )


def _project_image(page: PageContents, operation: dict, kind: str) -> None:
    index = int(operation["image"])
    position = _index_of(page.images, index)
    if position is None:
        raise InvalidPdfError(f"There is no image {index} on this page.")

    image = page.images[position]
    box = pymupdf.Rect(image.bbox)

    if kind == "move_image":
        box = box + (
            float(operation.get("dx", 0)),
            float(operation.get("dy", 0)),
            float(operation.get("dx", 0)),
            float(operation.get("dy", 0)),
        )
    elif kind == "scale_image":
        scale = max(0.05, float(operation.get("scale", 1)))
        # Grow from the top-left, so a resize does not also move the image.
        box = pymupdf.Rect(
            box.x0,
            box.y0,
            box.x0 + max(box.width * scale, MIN_IMAGE_SIDE),
            box.y0 + max(box.height * scale, MIN_IMAGE_SIDE),
        )

    asset = image.asset
    width, height = image.width, image.height
    if kind == "replace_image":
        asset = str(operation["asset"])
        # The op carries the new file's pixel size so the editor reports what is
        # actually on the page rather than the dimensions it replaced.
        width = int(operation.get("width", width))
        height = int(operation.get("height", height))

    page.images[position] = replace(
        image, bbox=tuple(box), asset=asset, width=width, height=height
    )


def _new_span(operation: dict) -> TextSpan:
    text = str(operation["text"])[:MAX_TEXT_LENGTH]
    size = _clamp(float(operation.get("size", 14)), MIN_FONT_SIZE, MAX_FONT_SIZE)
    font = str(operation.get("font") or "helv")
    origin = (float(operation["x"]), float(operation["y"]))
    return TextSpan(
        index=int(operation["id"]),
        text=text,
        bbox=text_bbox(text, origin=origin, size=size, font=font),
        origin=origin,
        font=font,
        size=size,
        color=str(operation.get("color", "#000000")),
        added=True,
    )


def _new_image(operation: dict) -> ImageObject:
    x = float(operation["x"])
    y = float(operation["y"])
    width = max(float(operation["width"]), MIN_IMAGE_SIDE)
    height = max(float(operation["height"]), MIN_IMAGE_SIDE)
    return ImageObject(
        index=int(operation["id"]),
        xref=0,
        bbox=(x, y, x + width, y + height),
        width=int(width),
        height=int(height),
        asset=str(operation["asset"]),
        added=True,
    )


# --- Rendering --------------------------------------------------------------


def render_page(path: Path, page_number: int, *, dpi: int = 110) -> bytes:
    """Rasterize one page to PNG — the canvas the editor draws its overlay on."""
    try:
        with pymupdf.open(path) as doc:
            if not 1 <= page_number <= doc.page_count:
                raise InvalidPdfError(
                    f"Page {page_number} does not exist; this PDF has "
                    f"{doc.page_count} pages."
                )
            return doc[page_number - 1].get_pixmap(dpi=dpi).tobytes("png")
    except InvalidPdfError:
        raise
    except Exception as exc:
        raise PdfProcessingError("Could not render this page.") from exc


def apply_operations(
    source: Path,
    destination: Path,
    operations: list[dict],
    *,
    asset_dir: Path | None = None,
) -> Path:
    """Replay an edit list onto a pristine copy of the original.

    Replaying from the original rather than mutating in place is what keeps
    object indices meaningful, makes undo a matter of dropping the last entry,
    and stops redaction artifacts compounding edit after edit.
    """
    try:
        with pymupdf.open(source) as doc:
            original = [_read_page(page, number) for number, page in enumerate(doc, 1)]
            final = project(original, operations)

            for number, page in enumerate(doc, 1):
                _render_page_edits(
                    page,
                    before=_find_page(original, number),
                    after=_find_page(final, number),
                    asset_dir=asset_dir,
                )

            doc.save(destination, garbage=4, deflate=True)
    except (InvalidPdfError, PdfProcessingError):
        raise
    except Exception as exc:
        raise PdfProcessingError("Could not apply these edits.") from exc
    return destination


def _render_page_edits(
    page: pymupdf.Page,
    *,
    before: PageContents,
    after: PageContents,
    asset_dir: Path | None,
) -> None:
    """Erase everything that must go in one pass, then draw what should stay.

    That order is the whole trick. Redaction is regional, not object-aware: it
    deletes whatever sits inside a rectangle. Every erase must therefore happen
    before any drawing, or a later erase wipes something just put back — which
    is exactly what removing a QR code does to the label printed across its
    bottom edge.
    """
    final_spans = {span.index: span for span in after.spans}
    final_images = {image.index: image for image in after.images}

    changed_spans = [
        span
        for span in before.spans
        if final_spans.get(span.index) != span  # edited, moved, restyled, or gone
    ]
    changed_images = [
        image
        for image in before.images
        if _image_geometry_changed(image, final_images.get(image.index))
    ]

    text_rects = [pymupdf.Rect(span.bbox) for span in changed_spans]
    image_rects = [pymupdf.Rect(image.bbox) for image in changed_images]
    affected = _overlap_closure(before.spans, text_rects + image_rects)

    # 1. Remove images that are going or moving. This erases text lying over
    #    them too; step 4 restores the runs that should survive.
    if image_rects:
        for rect in image_rects:
            page.add_redact_annot(rect)
        page.apply_redactions(images=pymupdf.PDF_REDACT_IMAGE_REMOVE)

    # 2. Place images at their new homes, and any the user added. Before the
    #    text so that text ends up on top and stays readable.
    for image in after.images:
        placed = final_images[image.index]
        original = _find_object(before.images, image.index)
        if original is not None and not _image_geometry_changed(original, placed):
            continue
        _insert_image(page, placed, original, asset_dir)

    # 3. Erase the changed runs and every run they touch, each by its full box.
    #    Redacting only the changed rect leaves a neighbour's uncovered halves
    #    behind as fragments — one line becoming "CPP PL" and "E CPM1".
    erase_text = text_rects + [pymupdf.Rect(span.bbox) for span in affected]
    if erase_text:
        for rect in erase_text:
            page.add_redact_annot(rect)
        # IMAGE_NONE: a text edit must never disturb artwork that stays.
        page.apply_redactions(images=pymupdf.PDF_REDACT_IMAGE_NONE)

    # 4. Draw the final state of everything that was erased, plus added runs.
    redraw = {span.index for span in affected} | {
        span.index for span in changed_spans
    }
    for span in after.spans:
        if span.added or span.index in redraw:
            _draw_span(page, span)

    # 5. Images whose pixels changed but whose box did not: swap in place, which
    #    preserves their position in the drawing order.
    for image in after.images:
        original = _find_object(before.images, image.index)
        if (
            original is not None
            and not _image_geometry_changed(original, image)
            and image.asset
            and image.asset != original.asset
        ):
            _replace_image_in_place(page, image, asset_dir)


def _image_geometry_changed(
    original: ImageObject, final: ImageObject | None
) -> bool:
    if final is None:
        return True  # deleted
    return not _rects_equal(original.bbox, final.bbox)


def _rects_equal(
    a: tuple[float, float, float, float], b: tuple[float, float, float, float]
) -> bool:
    return all(abs(x - y) < 0.01 for x, y in zip(a, b, strict=True))


def _insert_image(
    page: pymupdf.Page,
    image: ImageObject,
    original: ImageObject | None,
    asset_dir: Path | None,
) -> None:
    stream = _image_bytes(page.parent, image, original, asset_dir)
    try:
        page.insert_image(pymupdf.Rect(image.bbox), stream=stream)
    except Exception as exc:
        raise PdfProcessingError("Could not place that image.") from exc


def _replace_image_in_place(
    page: pymupdf.Page, image: ImageObject, asset_dir: Path | None
) -> None:
    path = _asset_path(image.asset, asset_dir)
    page.replace_image(image.xref, filename=str(path))


def _image_bytes(
    doc: pymupdf.Document,
    image: ImageObject,
    original: ImageObject | None,
    asset_dir: Path | None,
) -> bytes:
    if image.asset:
        return _asset_path(image.asset, asset_dir).read_bytes()
    if original is not None and original.xref:
        extracted = doc.extract_image(original.xref)
        if extracted and extracted.get("image"):
            return extracted["image"]
    raise PdfProcessingError("That image is no longer available.")


def _asset_path(asset: str | None, asset_dir: Path | None) -> Path:
    if not asset or asset_dir is None:
        raise PdfProcessingError("No image file was supplied.")

    # The name comes from the client; keep it inside the session folder.
    path = (asset_dir / Path(str(asset)).name).resolve()
    if not path.is_file() or asset_dir.resolve() not in path.parents:
        raise PdfProcessingError("That image is no longer available.")
    return path


def _overlap_closure(
    spans: list[TextSpan], erase_rects: list[pymupdf.Rect]
) -> list[TextSpan]:
    """Every span that will be erased, directly or by knock-on overlap.

    Erasing a neighbour by its full box can reach a third run that never met the
    original edit, so the set is grown to a fixed point instead of computed once.
    """
    if not erase_rects:
        return []

    selected = {
        span.index
        for span in spans
        if any(pymupdf.Rect(span.bbox).intersects(rect) for rect in erase_rects)
    }

    changed = True
    while changed:
        changed = False
        boxes = [
            pymupdf.Rect(span.bbox) for span in spans if span.index in selected
        ]
        for span in spans:
            if span.index in selected:
                continue
            if any(pymupdf.Rect(span.bbox).intersects(box) for box in boxes):
                selected.add(span.index)
                changed = True

    return [span for span in spans if span.index in selected]


def _draw_span(page: pymupdf.Page, span: TextSpan) -> None:
    if not span.text:
        return
    page.insert_text(
        span.origin,
        span.text,
        fontname=span.substitute_font,
        fontsize=span.size,
        color=_hex_to_rgb(span.color),
    )


def _find_page(pages: list[PageContents], number: int) -> PageContents:
    for page in pages:
        if page.number == number:
            return page
    raise InvalidPdfError(f"Page {number} does not exist.")


def _find_object(items, index: int):  # noqa: ANN001, ANN202
    for item in items:
        if item.index == index:
            return item
    return None


def _index_of(items, index: int) -> int | None:  # noqa: ANN001
    for position, item in enumerate(items):
        if item.index == index:
            return position
    return None


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(value, high))


def _int_to_hex(color: int) -> str:
    return f"#{color & 0xFFFFFF:06x}"


def _hex_to_rgb(value: str) -> tuple[float, float, float]:
    raw = value.lstrip("#")
    return tuple(int(raw[i : i + 2], 16) / 255 for i in (0, 2, 4))  # type: ignore[return-value]
