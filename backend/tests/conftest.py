"""Test fixtures: a throwaway SQLite database and an httpx client on the app.

SQLite stands in for PostgreSQL here. It exercises the same SQL that the quota
logic emits (conditional UPDATE ... RETURNING) without needing a server; the
GUID type and ``as_utc`` helper exist to keep that substitution honest.
"""

from __future__ import annotations

import os
from collections.abc import AsyncGenerator
from pathlib import Path

import pytest
import pytest_asyncio

os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///:memory:")
os.environ.setdefault("SECRET_KEY", "test-secret-key-not-used-in-production")

from httpx import ASGITransport, AsyncClient  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app import models  # noqa: E402,F401  — registers tables
from app.core.config import settings  # noqa: E402
from app.db.base import Base  # noqa: E402
from app.db.session import get_db  # noqa: E402
from app.main import create_app  # noqa: E402


@pytest.fixture(scope="session")
def anyio_backend() -> str:
    return "asyncio"


@pytest_asyncio.fixture
async def engine(tmp_path: Path):
    # A file-backed database, so the app and the test share one connection pool.
    url = f"sqlite+aiosqlite:///{(tmp_path / 'test.db').as_posix()}"
    engine = create_async_engine(url, future=True)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()


@pytest_asyncio.fixture
async def session_factory(engine):
    return async_sessionmaker(bind=engine, class_=AsyncSession, expire_on_commit=False)


@pytest_asyncio.fixture
async def db(session_factory) -> AsyncGenerator[AsyncSession, None]:
    async with session_factory() as session:
        yield session


@pytest_asyncio.fixture
async def client(session_factory, tmp_path: Path) -> AsyncGenerator[AsyncClient, None]:
    settings.temp_dir = tmp_path / "tmp"
    # Editor sessions keep working copies on disk; give each test its own
    # directory so one test cannot see or sweep another's.
    settings.session_dir = tmp_path / "sessions"
    settings.free_weekly_edit_quota = 2
    # The API tests are about the API. Serving the built web app at "/" would
    # turn every unknown path into index.html and hide real 404s.
    settings.serve_web_app = False

    app = create_app()

    async def override_get_db() -> AsyncGenerator[AsyncSession, None]:
        async with session_factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as http:
        yield http
