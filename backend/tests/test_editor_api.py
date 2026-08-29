"""The editor session lifecycle, end to end over HTTP."""

from __future__ import annotations

import io
from datetime import timedelta
from pathlib import Path

import pytest

from app.core.timeutils import utcnow

FIXTURE = Path(__file__).parent / "fixtures" / "qr-label.pdf"
SESSIONS = "/api/v1/editor/sessions"
STATUS = "/api/v1/users/me/status"

LABEL_NUMBER = "148100011059"
NEIGHBOUR = "ASS1"


@pytest.fixture
def label_bytes() -> bytes:
    return FIXTURE.read_bytes()


@pytest.fixture
async def auth(client):
    response = await client.post(
        "/api/v1/auth/register",
        json={"email": "editor@example.com", "password": "sup3rsecret"},
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


def span_texts(session: dict) -> list[str]:
    return [span["text"] for span in session["pages"][0]["spans"]]


async def test_opening_a_session_lists_editable_objects(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    assert session["page_count"] == 1
    assert span_texts(session)[0] == LABEL_NUMBER
    assert len(session["pages"][0]["images"]) == 1
    # The editor needs the substitute up front to warn about the typeface.
    assert session["pages"][0]["spans"][0]["substitute_font"] == "hebo"


async def test_opening_a_session_does_not_charge_quota(client, auth, label_bytes):
    await open_session(client, auth, label_bytes)

    status = (await client.get(STATUS, headers=auth)).json()
    assert status["quota"]["used"] == 0


async def test_page_renders_as_png(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.get(
        f"{SESSIONS}/{session['id']}/pages/1?dpi=72", headers=auth
    )

    assert response.status_code == 200
    assert response.headers["content-type"] == "image/png"
    assert response.content.startswith(b"\x89PNG")


async def test_replacing_text_updates_the_document(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.post(
        f"{SESSIONS}/{session['id']}/text",
        headers=auth,
        json={"page": 1, "span": 0, "text": "148100011062"},
    )

    assert response.status_code == 200
    updated = response.json()
    assert "148100011062" in span_texts(updated)
    assert LABEL_NUMBER not in span_texts(updated)
    # The neighbour whose box overlaps the edited one must still be there.
    assert NEIGHBOUR in span_texts(updated)
    assert updated["revision"] == 1


async def test_undo_puts_the_original_text_back(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    await client.post(
        f"{SESSIONS}/{session['id']}/text",
        headers=auth,
        json={"page": 1, "span": 0, "text": "999"},
    )

    response = await client.post(f"{SESSIONS}/{session['id']}/undo", headers=auth)

    assert response.status_code == 200
    assert LABEL_NUMBER in span_texts(response.json())


async def test_undo_with_nothing_to_undo_is_a_conflict(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.post(f"{SESSIONS}/{session['id']}/undo", headers=auth)

    assert response.status_code == 409


async def test_deleting_the_image_keeps_the_text(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.post(
        f"{SESSIONS}/{session['id']}/images/delete",
        headers=auth,
        json={"page": 1, "index": 0},
    )

    assert response.status_code == 200
    updated = response.json()
    assert updated["pages"][0]["images"] == []
    # The QR box overlaps the number; removing it must not take the text too.
    assert LABEL_NUMBER in span_texts(updated)


async def test_clearing_text_deletes_the_object(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.post(
        f"{SESSIONS}/{session['id']}/text",
        headers=auth,
        json={"page": 1, "span": 0, "text": "   "},
    )

    assert LABEL_NUMBER not in span_texts(response.json())


async def test_editing_an_object_that_does_not_exist_is_422(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.post(
        f"{SESSIONS}/{session['id']}/text",
        headers=auth,
        json={"page": 1, "span": 99, "text": "x"},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_pdf"


async def test_a_rejected_edit_leaves_the_session_usable(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    await client.post(
        f"{SESSIONS}/{session['id']}/text",
        headers=auth,
        json={"page": 1, "span": 99, "text": "x"},
    )

    current = await client.get(f"{SESSIONS}/{session['id']}", headers=auth)

    assert current.status_code == 200
    assert current.json()["revision"] == 0
    assert LABEL_NUMBER in span_texts(current.json())


async def test_saving_charges_one_edit_and_returns_the_pdf(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    for span, text in ((0, "148100011062"), (3, "781-1(31)")):
        await client.post(
            f"{SESSIONS}/{session['id']}/text",
            headers=auth,
            json={"page": 1, "span": span, "text": text},
        )

    response = await client.post(f"{SESSIONS}/{session['id']}/save", headers=auth)

    assert response.status_code == 200
    assert response.content.startswith(b"%PDF-")
    assert "qr-label-edited.pdf" in response.headers["content-disposition"]
    # Many tweaks, exactly one edit charged.
    status = (await client.get(STATUS, headers=auth)).json()
    assert status["quota"]["used"] == 1


async def test_a_saved_session_cannot_be_used_again(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    await client.post(f"{SESSIONS}/{session['id']}/save", headers=auth)

    response = await client.get(f"{SESSIONS}/{session['id']}", headers=auth)

    assert response.status_code == 409


async def test_discarding_ends_the_session_without_charging(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.delete(f"{SESSIONS}/{session['id']}", headers=auth)

    assert response.status_code == 204
    status = (await client.get(STATUS, headers=auth)).json()
    assert status["quota"]["used"] == 0


async def test_another_user_cannot_touch_the_session(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)
    other = await client.post(
        "/api/v1/auth/register",
        json={"email": "intruder@example.com", "password": "sup3rsecret"},
    )
    intruder = {"Authorization": f"Bearer {other.json()['access_token']}"}

    # A session id is not a capability: ownership is re-checked on every call.
    seen = await client.get(f"{SESSIONS}/{session['id']}", headers=intruder)
    edited = await client.post(
        f"{SESSIONS}/{session['id']}/text",
        headers=intruder,
        json={"page": 1, "span": 0, "text": "hacked"},
    )

    assert seen.status_code == 404
    assert edited.status_code == 404


async def test_an_expired_session_is_refused(client, auth, label_bytes, db):
    from sqlalchemy import select

    from app.models.edit_session import EditSession

    session = await open_session(client, auth, label_bytes)
    found = await db.execute(
        select(EditSession).where(EditSession.id == session["id"])
    )
    row = found.scalar_one()
    row.expires_at = utcnow() - timedelta(minutes=1)
    await db.commit()

    response = await client.get(f"{SESSIONS}/{session['id']}", headers=auth)

    assert response.status_code == 409


async def test_replacing_the_image_keeps_one_image(client, auth, label_bytes):
    import pymupdf

    session = await open_session(client, auth, label_bytes)
    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 64, 64))
    pixmap.set_rect(pixmap.irect, (0, 128, 255))

    response = await client.post(
        f"{SESSIONS}/{session['id']}/images/replace?page=1&index=0",
        headers=auth,
        files={"file": ("new.png", io.BytesIO(pixmap.tobytes("png")), "image/png")},
    )

    assert response.status_code == 200
    images = response.json()["pages"][0]["images"]
    assert len(images) == 1
    assert images[0]["width"] == 64


async def test_a_non_image_upload_is_rejected(client, auth, label_bytes):
    session = await open_session(client, auth, label_bytes)

    response = await client.post(
        f"{SESSIONS}/{session['id']}/images/replace?page=1&index=0",
        headers=auth,
        files={"file": ("payload.exe", io.BytesIO(b"MZ"), "application/octet-stream")},
    )

    assert response.status_code == 422


async def test_editor_requires_authentication(client, label_bytes):
    response = await client.post(
        SESSIONS,
        files={"file": ("qr.pdf", io.BytesIO(label_bytes), "application/pdf")},
    )

    assert response.status_code == 401
