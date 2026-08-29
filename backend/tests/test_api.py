"""End-to-end flow: register, check status, edit until the quota runs out."""

from __future__ import annotations

import io
from datetime import timedelta

import pymupdf
import pytest

from app.core.timeutils import utcnow
from app.services import subscription

REGISTER = "/api/v1/auth/register"
LOGIN = "/api/v1/auth/login"
STATUS = "/api/v1/users/me/status"
COMPRESS = "/api/v1/pdf/compress"


def sample_pdf(pages: int = 2) -> bytes:
    doc = pymupdf.open()
    for index in range(pages):
        doc.new_page().insert_text(pymupdf.Point(72, 72), f"Page {index + 1}")
    data = doc.tobytes()
    doc.close()
    return data


def upload(data: bytes | None = None, name: str = "doc.pdf"):
    payload = data if data is not None else sample_pdf()
    return {"file": (name, io.BytesIO(payload), "application/pdf")}


@pytest.fixture
async def auth(client):
    response = await client.post(
        REGISTER, json={"email": "user@example.com", "password": "sup3rsecret"}
    )
    assert response.status_code == 201, response.text
    token = response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


async def test_health(client):
    response = await client.get("/health")
    assert response.status_code == 200


async def test_register_rejects_a_duplicate_email(client):
    payload = {"email": "dupe@example.com", "password": "sup3rsecret"}
    assert (await client.post(REGISTER, json=payload)).status_code == 201

    response = await client.post(REGISTER, json=payload)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "conflict"


async def test_login_with_a_wrong_password_is_401(client, auth):
    response = await client.post(
        LOGIN, json={"email": "user@example.com", "password": "wrong-password"}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthenticated"


async def test_protected_route_requires_a_token(client):
    response = await client.get(STATUS)
    assert response.status_code == 401


async def test_status_reports_the_free_quota(client, auth):
    body = (await client.get(STATUS, headers=auth)).json()

    assert body["is_premium"] is False
    assert body["quota"]["limit"] == 2  # set by the client fixture
    assert body["quota"]["remaining"] == 2


async def test_refresh_rotates_and_revokes_the_old_token(client):
    tokens = (
        await client.post(
            REGISTER, json={"email": "rot@example.com", "password": "sup3rsecret"}
        )
    ).json()

    rotated = await client.post(
        "/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert rotated.status_code == 200
    assert rotated.json()["refresh_token"] != tokens["refresh_token"]

    # The original token is now dead — replaying it must fail.
    replay = await client.post(
        "/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert replay.status_code == 401


async def test_compress_returns_a_pdf_and_charges_one_edit(client, auth):
    response = await client.post(COMPRESS, headers=auth, files=upload())

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/pdf"
    assert response.content.startswith(b"%PDF-")
    assert response.headers["x-quota-remaining"] == "1"

    body = (await client.get(STATUS, headers=auth)).json()
    assert body["quota"]["used"] == 1


async def test_quota_exhaustion_returns_403_with_a_reset_time(client, auth):
    for _ in range(2):
        used = await client.post(COMPRESS, headers=auth, files=upload())
        assert used.status_code == 200

    response = await client.post(COMPRESS, headers=auth, files=upload())

    assert response.status_code == 403
    error = response.json()["error"]
    assert error["code"] == "quota_exceeded"
    assert "resets_at" in error["details"]


async def test_a_rejected_file_does_not_consume_quota(client, auth):
    response = await client.post(COMPRESS, headers=auth, files=upload(b"not a pdf"))
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_pdf"

    body = (await client.get(STATUS, headers=auth)).json()
    assert body["quota"]["used"] == 0


async def test_premium_bypasses_the_quota(client, auth, db):
    from sqlalchemy import select

    from app.models.user import User

    found = await db.execute(select(User).where(User.email == "user@example.com"))
    user = found.scalar_one()
    await subscription.grant_manual_premium(
        db, user.id, until=utcnow() + timedelta(days=30)
    )
    await db.commit()

    for _ in range(3):  # more than the free limit of 2
        response = await client.post(COMPRESS, headers=auth, files=upload())
        assert response.status_code == 200

    body = (await client.get(STATUS, headers=auth)).json()
    assert body["is_premium"] is True
    assert body["quota"]["limit"] is None


async def test_temp_files_are_cleaned_up(client, auth):
    from app.core.config import settings

    response = await client.post(COMPRESS, headers=auth, files=upload())
    assert response.status_code == 200

    leftovers = list(settings.temp_path.glob("*"))
    assert leftovers == []


async def test_merge_needs_two_files(client, auth):
    response = await client.post(
        "/api/v1/pdf/merge",
        headers=auth,
        files=[("files", ("a.pdf", io.BytesIO(sample_pdf()), "application/pdf"))],
    )
    assert response.status_code == 422


async def test_merge_combines_uploads(client, auth):
    response = await client.post(
        "/api/v1/pdf/merge",
        headers=auth,
        files=[
            ("files", ("a.pdf", io.BytesIO(sample_pdf(2)), "application/pdf")),
            ("files", ("b.pdf", io.BytesIO(sample_pdf(3)), "application/pdf")),
        ],
    )

    assert response.status_code == 200
    with pymupdf.open(stream=response.content, filetype="pdf") as doc:
        assert doc.page_count == 5


async def test_split_one_range_returns_a_pdf(client, auth):
    response = await client.post(
        "/api/v1/pdf/split",
        headers=auth,
        files=upload(sample_pdf(5)),
        data={"page_ranges": "2-3"},
    )

    assert response.status_code == 200
    with pymupdf.open(stream=response.content, filetype="pdf") as doc:
        assert doc.page_count == 2


async def test_split_several_ranges_returns_a_zip(client, auth):
    response = await client.post(
        "/api/v1/pdf/split",
        headers=auth,
        files=upload(sample_pdf(6)),
        data={"page_ranges": "1-2,5-6"},
    )

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/zip"


async def test_add_text_stamps_the_page(client, auth):
    response = await client.post(
        "/api/v1/pdf/add-text",
        headers=auth,
        files=upload(sample_pdf(2)),
        data={"text": "Approved", "page": "1", "x": "72", "y": "72"},
    )

    assert response.status_code == 200
    with pymupdf.open(stream=response.content, filetype="pdf") as doc:
        assert "Approved" in doc[0].get_text()


async def test_upload_over_the_size_limit_is_rejected(client, auth, monkeypatch):
    from app.core.config import settings

    monkeypatch.setattr(settings, "max_upload_bytes", 1024)
    oversized = sample_pdf(1) + b"\n%" + b"padding" * 500

    response = await client.post(COMPRESS, headers=auth, files=upload(oversized))

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "file_too_large"
