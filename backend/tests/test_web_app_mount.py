"""Serving the built web app alongside the API.

One origin means a phone opens a single address and the page talks to the API
with no CORS and no second static server. The risk is the static mount
swallowing API paths, so that is what these pin.
"""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.config import settings
from app.main import create_app


@pytest.fixture
def built_web_app(tmp_path, monkeypatch):
    web = tmp_path / "web"
    web.mkdir()
    (web / "index.html").write_text("<html>PDFree</html>", encoding="utf-8")
    (web / "main.dart.js").write_text("// app", encoding="utf-8")

    monkeypatch.setattr(settings, "web_app_dir", web)
    monkeypatch.setattr(settings, "serve_web_app", True)
    return web


async def _client(app) -> AsyncClient:
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def test_serves_the_web_app_at_the_root(built_web_app):
    async with await _client(create_app()) as client:
        response = await client.get("/")

    assert response.status_code == 200
    assert "PDFree" in response.text


async def test_serves_the_app_assets(built_web_app):
    async with await _client(create_app()) as client:
        response = await client.get("/main.dart.js")

    assert response.status_code == 200


async def test_the_mount_does_not_swallow_the_api(built_web_app):
    async with await _client(create_app()) as client:
        health = await client.get("/health")
        api = await client.get("/api/v1/users/me/status")

    assert health.status_code == 200
    assert health.json()["status"] == "ok"
    # Unauthenticated, not index.html: the API still owns its own paths.
    assert api.status_code == 401
    assert api.json()["error"]["code"] == "unauthenticated"


async def test_api_only_when_the_web_app_is_not_built(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "web_app_dir", tmp_path / "missing")
    monkeypatch.setattr(settings, "serve_web_app", True)

    async with await _client(create_app()) as client:
        health = await client.get("/health")
        root = await client.get("/")

    assert health.status_code == 200
    assert root.status_code == 404  # nothing to serve, and nothing pretending to


async def test_serving_can_be_switched_off(built_web_app, monkeypatch):
    monkeypatch.setattr(settings, "serve_web_app", False)

    async with await _client(create_app()) as client:
        response = await client.get("/")

    assert response.status_code == 404
