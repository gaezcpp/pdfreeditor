"""Projection: the current state derived from the original plus the edit log.

The editor addresses objects by index, so an index has to keep meaning the same
thing for a whole session. Re-reading them from an already-edited PDF does not:
delete one run and everything below shifts up, so the next edit lands on the
wrong object. These pin the identity rules that prevent that.
"""

from __future__ import annotations

from pathlib import Path

import pymupdf
import pytest

from app.core.errors import InvalidPdfError
from app.services.pdf import document

FIXTURE = Path(__file__).parent / "fixtures" / "qr-label.pdf"

NUMBER = "148100011059"
NEIGHBOUR = "ASS1"


@pytest.fixture
def original() -> list[document.PageContents]:
    return document.read_contents(FIXTURE)


def texts(pages: list[document.PageContents]) -> list[str]:
    return [span.text for span in pages[0].spans]


def indices(pages: list[document.PageContents]) -> list[int]:
    return [span.index for span in pages[0].spans]


def test_no_operations_is_the_original(original):
    assert texts(document.project(original, [])) == texts(original)


def test_deleting_a_run_does_not_renumber_the_others(original):
    """The regression this whole design exists for.

    Before, the client was shown indices read back from the edited PDF, so after
    a deletion "CPP PLANT" answered to index 1 — which on replay still meant the
    deleted ASS1, and the next edit hit the wrong object.
    """
    after = document.project(
        original, [{"type": "delete_text", "page": 1, "span": 1}]
    )

    assert texts(after) == [NUMBER, "CPP PLANT 1 LINE CPM1", "781-1(30)"]
    # 1 is gone; 2 and 3 keep the handles they started with.
    assert indices(after) == [0, 2, 3]


def test_editing_after_a_deletion_still_targets_the_right_run(original):
    after = document.project(
        original,
        [
            {"type": "delete_text", "page": 1, "span": 1},
            {"type": "replace_text", "page": 1, "span": 2, "text": "CHANGED"},
        ],
    )

    assert "CHANGED" in texts(after)
    assert NUMBER in texts(after)  # untouched


def test_moving_a_run_shifts_its_box_and_baseline(original):
    before = original[0].spans[0]

    after = document.project(
        original, [{"type": "move_text", "page": 1, "span": 0, "dx": 20, "dy": -10}]
    )
    moved = after[0].spans[0]

    assert moved.origin[0] == pytest.approx(before.origin[0] + 20)
    assert moved.origin[1] == pytest.approx(before.origin[1] - 10)
    # The overlay outline has to follow, or selection stops matching the pixels.
    assert moved.bbox[0] == pytest.approx(before.bbox[0] + 20, abs=2)


def test_moves_accumulate(original):
    after = document.project(
        original,
        [
            {"type": "move_text", "page": 1, "span": 0, "dx": 10, "dy": 0},
            {"type": "move_text", "page": 1, "span": 0, "dx": 5, "dy": 0},
        ],
    )

    assert after[0].spans[0].origin[0] == pytest.approx(
        original[0].spans[0].origin[0] + 15
    )


def test_font_size_changes_the_box_too(original):
    before = original[0].spans[0]

    after = document.project(
        original, [{"type": "style_text", "page": 1, "span": 0, "size": 60}]
    )
    bigger = after[0].spans[0]

    assert bigger.size == 60
    assert bigger.bbox[2] - bigger.bbox[0] > before.bbox[2] - before.bbox[0]


def test_font_size_is_clamped(original):
    after = document.project(
        original, [{"type": "style_text", "page": 1, "span": 0, "size": 5000}]
    )

    assert after[0].spans[0].size == document.MAX_FONT_SIZE


def test_added_text_gets_the_id_it_was_given(original):
    after = document.project(
        original,
        [
            {
                "type": "add_text",
                "page": 1,
                "id": 99,
                "text": "DRAFT",
                "x": 50,
                "y": 100,
                "size": 24,
            }
        ],
    )

    added = after[0].spans[-1]
    assert added.index == 99
    assert added.added is True
    assert added.text == "DRAFT"


def test_added_text_can_then_be_moved(original):
    """Added objects need stable handles as much as original ones do."""
    after = document.project(
        original,
        [
            {
                "type": "add_text",
                "page": 1,
                "id": 99,
                "text": "DRAFT",
                "x": 50,
                "y": 100,
                "size": 24,
            },
            {"type": "move_text", "page": 1, "span": 99, "dx": 30, "dy": 40},
        ],
    )

    added = next(span for span in after[0].spans if span.index == 99)
    assert added.origin == pytest.approx((80, 140))


def test_next_object_id_avoids_every_handle_in_use(original):
    assert document.next_object_id(original, 1) == 4  # 4 spans, 1 image at index 0

    after = document.project(
        original,
        [{"type": "add_text", "page": 1, "id": 4, "text": "x", "x": 1, "y": 1}],
    )
    assert document.next_object_id(after, 1) == 5


def test_moving_an_image_shifts_its_box(original):
    before = original[0].images[0]

    after = document.project(
        original, [{"type": "move_image", "page": 1, "image": 0, "dx": 15, "dy": 25}]
    )
    moved = after[0].images[0]

    assert moved.bbox[0] == pytest.approx(before.bbox[0] + 15)
    assert moved.bbox[1] == pytest.approx(before.bbox[1] + 25)


def test_scaling_an_image_grows_it_without_moving_it(original):
    before = original[0].images[0]

    after = document.project(
        original, [{"type": "scale_image", "page": 1, "image": 0, "scale": 0.5}]
    )
    scaled = after[0].images[0]

    # Top-left pinned: a resize that also moved would fight the drag gesture.
    assert scaled.bbox[0] == pytest.approx(before.bbox[0])
    assert scaled.bbox[1] == pytest.approx(before.bbox[1])
    assert (scaled.bbox[2] - scaled.bbox[0]) == pytest.approx(
        (before.bbox[2] - before.bbox[0]) * 0.5
    )


def test_added_image_lands_where_it_was_placed(original):
    after = document.project(
        original,
        [
            {
                "type": "add_image",
                "page": 1,
                "id": 50,
                "asset": "logo.png",
                "x": 30,
                "y": 40,
                "width": 100,
                "height": 60,
            }
        ],
    )

    added = after[0].images[-1]
    assert added.index == 50
    assert added.added is True
    assert added.bbox == pytest.approx((30, 40, 130, 100))


def test_editing_a_missing_object_is_rejected(original):
    with pytest.raises(InvalidPdfError):
        document.project(
            original, [{"type": "move_text", "page": 1, "span": 999, "dx": 1, "dy": 1}]
        )


def test_clearing_the_text_deletes_the_run(original):
    after = document.project(
        original, [{"type": "replace_text", "page": 1, "span": 0, "text": "   "}]
    )

    assert NUMBER not in texts(after)
    assert NEIGHBOUR in texts(after)


# --- The projection has to match what actually gets drawn -------------------


def rendered_text(path: Path) -> str:
    with pymupdf.open(path) as doc:
        return doc[0].get_text()


def test_a_move_survives_rendering(tmp_path: Path):
    out = tmp_path / "out.pdf"
    document.apply_operations(
        FIXTURE, out, [{"type": "move_text", "page": 1, "span": 0, "dx": 0, "dy": -60}]
    )

    text = rendered_text(out)
    assert NUMBER in text
    assert NEIGHBOUR in text  # the neighbour it was overlapping survives

    with pymupdf.open(out) as doc:
        span = next(
            s
            for block in doc[0].get_text("dict")["blocks"]
            if block["type"] == 0
            for line in block["lines"]
            for s in line["spans"]
            if s["text"] == NUMBER
        )
        # 661.12 is the baseline, not the box's top edge — a move shifts the
        # baseline, and confusing the two is an easy way to write a wrong test.
        assert span["origin"][1] == pytest.approx(661.12 - 60, abs=2)


def test_a_size_change_survives_rendering(tmp_path: Path):
    out = tmp_path / "out.pdf"
    document.apply_operations(
        FIXTURE, out, [{"type": "style_text", "page": 1, "span": 0, "size": 12}]
    )

    with pymupdf.open(out) as doc:
        span = next(
            s
            for block in doc[0].get_text("dict")["blocks"]
            if block["type"] == 0
            for line in block["lines"]
            for s in line["spans"]
            if s["text"] == NUMBER
        )
        assert span["size"] == pytest.approx(12, abs=0.5)


def test_a_moved_image_survives_rendering(tmp_path: Path):
    out = tmp_path / "out.pdf"
    document.apply_operations(
        FIXTURE, out, [{"type": "move_image", "page": 1, "image": 0, "dx": 0, "dy": -80}]
    )

    pages = document.read_contents(out)
    assert len(pages[0].images) == 1
    assert pages[0].images[0].bbox[1] == pytest.approx(148.48 - 80, abs=3)
    # Moving the QR must not take the label text with it.
    assert NUMBER in rendered_text(out)


def test_an_added_image_survives_rendering(tmp_path: Path):
    assets = tmp_path / "assets"
    assets.mkdir()
    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 40, 40))
    pixmap.set_rect(pixmap.irect, (10, 200, 90))
    (assets / "logo.png").write_bytes(pixmap.tobytes("png"))

    out = tmp_path / "out.pdf"
    document.apply_operations(
        FIXTURE,
        out,
        [
            {
                "type": "add_image",
                "page": 1,
                "id": 50,
                "asset": "logo.png",
                "x": 40,
                "y": 40,
                "width": 80,
                "height": 80,
            }
        ],
        asset_dir=assets,
    )

    pages = document.read_contents(out)
    assert len(pages[0].images) == 2  # the QR plus the new one
    assert NUMBER in rendered_text(out)
