"""FastAPI application factory."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.api.v1.router import api_router
from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.db.session import SessionFactory, engine
from app.services import editor
from app.services.pdf.storage import TempWorkspace

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI):
    settings.temp_path.mkdir(parents=True, exist_ok=True)
    settings.session_path.mkdir(parents=True, exist_ok=True)
    _sweep_orphaned_temp_files()
    await _sweep_expired_sessions()
    yield
    await engine.dispose()


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.project_name,
        version="0.1.0",
        docs_url="/docs" if not settings.is_production else None,
        redoc_url=None,
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.allowed_origins,
        allow_credentials=False,  # tokens travel in the Authorization header
        allow_methods=["*"],
        allow_headers=["*"],
        expose_headers=["Content-Disposition", "X-Quota-Remaining"],
    )

    register_exception_handlers(app)
    app.include_router(api_router, prefix=settings.api_v1_prefix)

    @app.get("/health", tags=["ops"])
    async def health() -> dict[str, str]:
        return {"status": "ok", "environment": settings.environment}

    _mount_web_app(app)
    return app


def _mount_web_app(app: FastAPI) -> None:
    """Serve the built Flutter web app at the site root, if it exists.

    Mounted last on purpose: FastAPI matches routes in registration order, so
    the API and /health keep their paths and only what is left falls through to
    static files.
    """
    web_app = settings.web_app_path
    if web_app is None:
        logger.info("No built web app found; serving the API only.")
        return

    app.mount("/", StaticFiles(directory=web_app, html=True), name="web")
    logger.info("Serving the web app from %s", web_app)


def _sweep_orphaned_temp_files() -> None:
    """Delete leftovers from a crash or a hard restart.

    The happy path already deletes everything after each response; this only
    covers the case where the process died mid-request.
    """
    workspace = TempWorkspace()
    workspace.paths = list(settings.temp_path.glob("*"))
    if workspace.paths:
        logger.info("Sweeping %d orphaned temp file(s).", len(workspace.paths))
    workspace.cleanup()


async def _sweep_expired_sessions() -> None:
    """Reclaim disk from editing sessions nobody came back to.

    Not required for correctness — an expired session is already refused — but
    without it their working copies accumulate.
    """
    try:
        async with SessionFactory() as db:
            closed = await editor.sweep_expired(db)
            await db.commit()
        if closed:
            logger.info("Closed %d expired editing session(s).", closed)
    except Exception:  # pragma: no cover - never block startup on housekeeping
        logger.warning("Could not sweep expired editing sessions.", exc_info=True)


app = create_app()
