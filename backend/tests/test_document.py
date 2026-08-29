"""Object-level editing, exercised on a real label PDF.

The fixture is a genuine QR label: an image plus four overlapping text runs in
subset-embedded Lato. Synthetic PDFs would not reproduce either the overlap or
the font-substitution path, which are the two things most likely to break.
"""

from __future__ import annotations

from pathlib import Path

import pymupdf
import pytest

from app.core.errors import InvalidPdfError, PdfProcessingError
from app.services.pdf import document

FIXTURE = Path(__file__).parent / "fixtures" / "qr-label.pdf"

LABEL_NUMBER = "148100011059"
NEIGHBOUR = "ASS1"


@pytest.fixture
def label() -> Path:
    return FIXTURE


def page_text(path: Path) -> str:
    with pymupdf.open(path) as doc:
        return doc[0].get_text()


def image_count(path: Path) -> int:
    with pymupdf.open(path) as doc:
        return len(doc[0].get_images(full=True))


def test_reads_every_text_run_and_image(label):
    pages = document.read_contents(label)

    assert len(pages) == 1
    page = pages[0]
    assert [span.text for span in page.spans] == [
        LABEL_NUMBER,
        NEIGHBOUR,
        "CPP PLANT 1 LINE CPM1",
        "781-1(30)",
    ]
    assert len(page.images) == 1
    assert page.images[0].width == 528


def test_span_carries_what_the_editor_needs_to_redraw_it(label):
    span = document.read_contents(label)[0].spans[0]

    assert span.font == "Lato-Black"
    assert span.color == "#111827"
    assert round(span.size, 1) == 29.4
    # Black is a bold weight, so the substitute must be a bold face.
    assert span.substitute_font == "hebo"


@pytest.mark.parametrize(
    ("font", "expected"),
    [
        ("Lato-Black", "hebo"),
        ("Lato-Bold", "hebo"),
        ("Helvetica", "helv"),
        ("Times-Italic", "heit"),
        ("Arial-BoldItalic", "hebi"),
    ],
)
def test_substitute_font_matches_weight_and_slant(font, expected):
    assert document.substitute_font_for(font) == expected


def test_replacing_text_keeps_the_rest_of_the_page(label, tmp_path: Path):
    out = tmp_path / "out.pdf"
    document.apply_operations(
        label,
        out,
        [{"type": "replace_text", "page": 1, "span": 0, "text": "148100011062"}],
    )

    text = page_text(out)
    assert "148100011062" in text
    assert LABEL_NUMBER not in text
    # The QR is the whole point of the label; a text edit must not disturb it.
    assert image_count(out) == 1
    assert "CPP PLANT 1 LINE CPM1" in text


def test_an_overlapping_neighbour_survives_the_edit(label, tmp_path: Path):
    """The regression this whole design exists for.

    'ASS1' overlaps the number's box. Redaction erases every glyph meeting the
    rect, so without redrawing the neighbours, editing the number silently
    deletes the line below it.
    """
    out = tmp_path / "out.pdf"
    document.apply_operations(
        label,
        out,
        [{"type": "replace_text", "page": 1, "span": 0, "text": "999"}],
    )

    assert NEIGHBOUR in page_text(out)


def test_text_can_be_deleted(label, tmp_path: Path):
    out = tmp_path / "out.pdf"
    document.apply_operations(
        label, out, [{"type": "delete_text", "page": 1, "span": 0}]
    )

    text = page_text(out)
    assert LABEL_NUMBER not in text
    assert NEIGHBOUR in text  # still only the targeted run goes


def test_image_can_be_deleted(label, tmp_path: Path):
    out = tmp_path / "out.pdf"
    document.apply_operations(
        label, out, [{"type": "delete_image", "page": 1, "image": 0}]
    )

    assert image_count(out) == 0
    # Removing the QR must not take the text with it.
    assert LABEL_NUMBER in page_text(out)


def test_image_can_be_replaced(label, tmp_path: Path):
    assets = tmp_path / "assets"
    assets.mkdir()
    replacement = assets / "new.png"
    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 64, 64))
    pixmap.set_rect(pixmap.irect, (0, 128, 255))
    replacement.write_bytes(pixmap.tobytes("png"))

    out = tmp_path / "out.pdf"
    document.apply_operations(
        label,
        out,
        [{"type": "replace_image", "page": 1, "image": 0, "asset": "new.png"}],
        asset_dir=assets,
    )

    # PyMuPDF leaves a second reference to the same xref behind after a
    # replacement; the editor must still see exactly one image on the page.
    images = document.read_contents(out)[0].images
    assert len(images) == 1
    assert images[0].width == 64  # the replacement, not the original 528px QR


def test_replacement_image_must_stay_inside_the_session(label, tmp_path: Path):
    assets = tmp_path / "assets"
    assets.mkdir()
    (tmp_path / "outside.png").write_bytes(b"not really a png")

    with pytest.raises(PdfProcessingError):
        document.apply_operations(
            label,
            tmp_path / "out.pdf",
            [
                {
                    "type": "replace_image",
                    "page": 1,
                    "image": 0,
                    "asset": "../outside.png",
                }
            ],
            asset_dir=assets,
        )


def test_several_edits_apply_together(label, tmp_path: Path):
    out = tmp_path / "out.pdf"
    document.apply_operations(
        label,
        out,
        [
            {"type": "replace_text", "page": 1, "span": 0, "text": "148100011062"},
            {"type": "replace_text", "page": 1, "span": 3, "text": "781-1(31)"},
            {"type": "delete_image", "page": 1, "image": 0},
        ],
    )

    text = page_text(out)
    assert "148100011062" in text
    assert "781-1(31)" in text
    assert image_count(out) == 0


def test_add_text_places_a_new_run(label, tmp_path: Path):
    out = tmp_path / "out.pdf"
    document.apply_operations(
        label,
        out,
        [
            {
                "type": "add_text",
                "page": 1,
                "id": 100,
                "text": "DRAFT",
                "x": 60,
                "y": 100,
                "size": 24,
                "color": "#ff0000",
            }
        ],
    )

    assert "DRAFT" in page_text(out)


def test_unknown_object_is_rejected(label, tmp_path: Path):
    with pytest.raises(InvalidPdfError):
        document.apply_operations(
            label,
            tmp_path / "out.pdf",
            [{"type": "replace_text", "page": 1, "span": 99, "text": "x"}],
        )


def test_render_produces_a_png(label):
    png = document.render_page(label, 1, dpi=72)

    assert png.startswith(b"\x89PNG")


def test_render_rejects_a_missing_page(label):
    with pytest.raises(InvalidPdfError):
        document.render_page(label, 5)
