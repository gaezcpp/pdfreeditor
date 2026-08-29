"""Application settings, loaded once from the environment / .env file."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_ROOT / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- General -------------------------------------------------------------
    project_name: str = "PDFree Editor API"
    api_v1_prefix: str = "/api/v1"
    environment: str = "development"
    debug: bool = False

    # --- Security ------------------------------------------------------------
    # Placeholder only; get_settings() refuses to start production with it.
    secret_key: str = "change-me-please-this-is-not-safe-for-production"  # noqa: S105
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 30

    # --- Database ------------------------------------------------------------
    database_url: str = "postgresql+asyncpg://pdfree:pdfree@localhost:5432/pdfree"
    db_echo: bool = False

    # --- Quota ---------------------------------------------------------------
    free_weekly_edit_quota: int = 5

    # --- Uploads -------------------------------------------------------------
    max_upload_bytes: int = 25 * 1024 * 1024
    max_pdf_pages: int = 500
    max_merge_files: int = 10
    temp_dir: Path = Path("var/tmp")

    # --- Editor sessions -----------------------------------------------------
    # Kept separate from temp_dir: temp files are swept on startup, session
    # working copies must survive for as long as someone is editing.
    session_dir: Path = Path("var/sessions")
    session_ttl_minutes: int = 60
    max_session_operations: int = 200
    max_image_upload_bytes: int = 8 * 1024 * 1024
    render_max_dpi: int = 200

    # --- Web app -------------------------------------------------------------
    # Serving the built Flutter web app from this same server means the page and
    # the API share an origin: one port to open on a phone, no CORS, and no
    # second static server to remember to start. Ignored when not built yet.
    web_app_dir: Path = Path("../build/web")
    serve_web_app: bool = True

    # --- CORS ----------------------------------------------------------------
    # Kept as a raw string, not a list: pydantic-settings JSON-decodes complex
    # types straight from the environment, before any validator runs, so a
    # plain `CORS_ORIGINS=*` would fail to parse. Split in `allowed_origins`.
    cors_origins: str = "*"

    @property
    def allowed_origins(self) -> list[str]:
        """CORS origins, comma-separated in the environment."""
        return [item.strip() for item in self.cors_origins.split(",") if item.strip()]

    @property
    def is_production(self) -> bool:
        return self.environment.lower() in {"production", "prod"}

    @property
    def temp_path(self) -> Path:
        """Absolute temp directory, created on first access."""
        return self._resolved(self.temp_dir)

    @property
    def session_path(self) -> Path:
        """Absolute editor-session directory, created on first access."""
        return self._resolved(self.session_dir)

    @property
    def web_app_path(self) -> Path | None:
        """The built web app, or None when it has not been built."""
        if not self.serve_web_app:
            return None
        path = self.web_app_dir
        if not path.is_absolute():
            path = (BACKEND_ROOT / path).resolve()
        return path if (path / "index.html").is_file() else None

    def _resolved(self, path: Path) -> Path:
        if not path.is_absolute():
            path = BACKEND_ROOT / path
        path.mkdir(parents=True, exist_ok=True)
        return path


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    if settings.is_production and settings.secret_key.startswith("change-me"):
        raise RuntimeError("SECRET_KEY must be set to a real secret in production.")
    return settings


settings = get_settings()
