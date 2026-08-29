"""The move, resize, and place-new-object endpoints, over HTTP.

The projection rules are covered in test_projection.py; these check the wiring
that sits above them — field names, ids assigned server-side, and the fact that
handles keep working across a sequence of edits.
"""

from __future__ import annotations

import io
from pathlib import Path

import pymupdf
import pytest

FIXTURE = Path(__file__).parent / "fixtures" / "qr-label.pdf"
SESSIONS = "/api/v1/editor/sessions"

NUMBER = "148100011059"


@pytest.fixture
def label_bytes() -> bytes:
    return FIXTURE.read_bytes()


@pytest.fixture
def logo_bytes() -> bytes:
    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 100, 50))
    pixmap.set_rect(pixmap.irect, (20, 120, 220))
    return pixmap.tobytes("png")


@pytest.fixture
async def auth(client):
    response = await client.post(
        "/api/v1/auth/register",
        json={"email": "tools@example.com", "password": "sup3rsecret"},
    )
    assert response.status_code == 201, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


async def open_session(client, auth, label_bytes: bytes) -> dict:
    response = await client.post(
        SESSIONS,
        headers=auth,
        files={"file": ("qr-label.pdf", io.BytesIO(label_bytes), "application/pdf")},
    )
    assert response.status_code == 201, response.text
    return response.json()


def spans(session: dict) -> list[dict]:
    return session["pages"][0]["spans"]


def images(session: dict) -> list[dict]:
    return session["pages"][0]["images"]


async def test_moving_text_shifts_its_box(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    before = spans(session)[0]["bbox"]

    response = await client.post(
        f"{SESSIONS}/{session['id']}/text/move",
        headers=auth,
        json={"page": 1, "index": 0, "dx": 25, "dy": -40},
    )

    assert response.status_code == 200
    after = spans(response.json())[0]["bbox"]
    assert after[0] == pytest.approx(before[0] + 25, abs=2)
    # Looser vertically: once a run is edited its box is computed from the
    # substitute font's ascender rather than the original's measured glyphs, so
    # it shifts a couple of points. That box is the truthful one — it describes
    # where the text will actually be drawn.
    assert after[1] == pytest.approx(before[1] - 40, abs=4)


async def test_changing_the_font_size_widens_the_box(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    before = spans(session)[0]

    response = await client.post(
        f"{SESSIONS}/{session['id']}/text/style",
        headers=auth,
        json={"page": 1, "index": 0, "size": 60},
    )

    after = spans(response.json())[0]
    assert after["size"] == 60
    assert (after["bbox"][2] - after["bbox"][0]) > (
        before["bbox"][2] - before["bbox"][0]
    )


async def test_an_added_run_can_be_moved_afterwards(client, auth, label_bytes):
    """New objects need handles that survive replay, same as original ones."""
    session = await open_session(client, auth, label_bytes)

    added = await client.post(
        f"{SESSIONS}/{session['id']}/text/add",
        headers=auth,
        json={"page": 1, "text": "REVISI B", "x": 60, "y": 120, "size": 28},
    )
    assert added.status_code == 200
    new_run = next(span for span in spans(added.json()) if span["added"])
    assert new_run["text"] == "REVISI B"

    moved = await client.post(
        f"{SESSIONS}/{session['id']}/text/move",
        headers=auth,
        json={"page": 1, "index": new_run["index"], "dx": 30, "dy": 10},
    )

    assert moved.status_code == 200
    same_run = next(
        span for span in spans(moved.json()) if span["index"] == new_run["index"]
    )
    assert same_run["bbox"][0] == pytest.approx(new_run["bbox"][0] + 30, abs=2)


async def test_editing_still_works_after_a_deletion(client, auth, label_bytes):
    """The handle-drift bug: indices must not renumber when something goes."""
    session = await open_session(client, auth, label_bytes)

    await client.post(
        f"{SESSIONS}/{session['id']}/text/delete",
        headers=auth,
        json={"page": 1, "index": 1},  # ASS1
    )
    response = await client.post(
        f"{SESSIONS}/{session['id']}/text",
        headers=auth,
        json={"page": 1, "span": 2, "text": "CHANGED"},  # still CPP PLANT
    )

    assert response.status_code == 200
    texts = [span["text"] for span in spans(response.json())]
    assert "CHANGED" in texts
    assert NUMBER in texts  # the run above was not disturbed


async def test_moving_and_scaling_an_image(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    before = images(session)[0]["bbox"]

    moved = await client.post(
        f"{SESSIONS}/{session['id']}/images/move",
        headers=auth,
        json={"page": 1, "index": 0, "dx": 40, "dy": 20},
    )
    assert moved.status_code == 200
    assert images(moved.json())[0]["bbox"][0] == pytest.approx(before[0] + 40, abs=1)

    scaled = await client.post(
        f"{SESSIONS}/{session['id']}/images/scale",
        headers=auth,
        json={"page": 1, "index": 0, "scale": 0.5},
    )
    assert scaled.status_code == 200
    box = images(scaled.json())[0]["bbox"]
    assert (box[2] - box[0]) == pytest.approx((before[2] - before[0]) * 0.5, abs=1)


async def test_adding_an_image_keeps_its_aspect_ratio(
    client, auth, label_bytes, logo_bytes
):
    session = await open_session(client, auth, label_bytes)

    response = await client.post(
        f"{SESSIONS}/{session['id']}/images/add?page=1&x=40&y=40&width=120",
        headers=auth,
        files={"file": ("logo.png", io.BytesIO(logo_bytes), "image/png")},
    )

    assert response.status_code == 200
    placed = next(image for image in images(response.json()) if image["added"])
    box = placed["bbox"]
    assert box[0] == pytest.approx(40)
    assert (box[2] - box[0]) == pytest.approx(120)
    # The source is 100x50, so the placed box must be half as tall as it is wide.
    assert (box[3] - box[1]) == pytest.approx(60)


async def test_an_added_image_can_be_moved(client, auth, label_bytes, logo_bytes):
    session = await open_session(client, auth, label_bytes)
    added = await client.post(
        f"{SESSIONS}/{session['id']}/images/add?page=1&x=40&y=40",
        headers=auth,
        files={"file": ("logo.png", io.BytesIO(logo_bytes), "image/png")},
    )
    placed = next(image for image in images(added.json()) if image["added"])

    moved = await client.post(
        f"{SESSIONS}/{session['id']}/images/move",
        headers=auth,
        json={"page": 1, "index": placed["index"], "dx": 25, "dy": 0},
    )

    same = next(
        image for image in images(moved.json()) if image["index"] == placed["index"]
    )
    assert same["bbox"][0] == pytest.approx(65)


async def test_a_full_editing_session_saves_everything(
    client, auth, label_bytes, logo_bytes
):
    session = await open_session(client, auth, label_bytes)
    sid = session["id"]

    await client.post(
        f"{SESSIONS}/{sid}/text",
        headers=auth,
        json={"page": 1, "span": 0, "text": "148100011062"},
    )
    await client.post(
        f"{SESSIONS}/{sid}/text/style",
        headers=auth,
        json={"page": 1, "index": 0, "size": 40},
    )
    await client.post(
        f"{SESSIONS}/{sid}/images/scale",
        headers=auth,
        json={"page": 1, "index": 0, "scale": 0.6},
    )
    await client.post(
        f"{SESSIONS}/{sid}/text/add",
        headers=auth,
        json={"page": 1, "text": "REVISI B", "x": 60, "y": 120, "size": 26},
    )
    await client.post(
        f"{SESSIONS}/{sid}/images/add?page=1&x=400&y=60&width=80",
        headers=auth,
        files={"file": ("logo.png", io.BytesIO(logo_bytes), "image/png")},
    )

    saved = await client.post(f"{SESSIONS}/{sid}/save", headers=auth)

    assert saved.status_code == 200
    with pymupdf.open(stream=saved.content, filetype="pdf") as doc:
        text = doc[0].get_text()
        assert "148100011062" in text
        assert "REVISI B" in text
        assert "ASS1" in text  # the overlapping neighbour survived it all
        assert len(doc[0].get_images(full=True)) >= 2

    # Five tweaks, one edit charged.
    status = (await client.get("/api/v1/users/me/status", headers=auth)).json()
    assert status["quota"]["used"] == 1


async def test_undo_walks_back_one_tool_at_a_time(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    sid = session["id"]

    await client.post(
        f"{SESSIONS}/{sid}/text/move",
        headers=auth,
        json={"page": 1, "index": 0, "dx": 50, "dy": 0},
    )
    after_move = await client.post(
        f"{SESSIONS}/{sid}/text/style",
        headers=auth,
        json={"page": 1, "index": 0, "size": 50},
    )
    assert after_move.json()["operation_count"] == 2

    undone = await client.post(f"{SESSIONS}/{sid}/undo", headers=auth)

    assert undone.json()["operation_count"] == 1
    assert spans(undone.json())[0]["size"] != 50  # the size change went, the move stayed


async def test_font_size_out_of_range_is_rejected(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.post(
        f"{SESSIONS}/{session['id']}/text/style",
        headers=auth,
        json={"page": 1, "index": 0, "size": 9000},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"
