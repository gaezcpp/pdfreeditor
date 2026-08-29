"""Typed application errors and the handlers that turn them into JSON.

Every error the client can act on carries a stable machine-readable ``code`` so
the Flutter app can branch on it (e.g. show the paywall on ``quota_exceeded``)
instead of parsing human-readable messages.
"""

from __future__ import annotations

from fastapi import FastAPI, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


class AppError(Exception):
    status_code: int = status.HTTP_400_BAD_REQUEST
    code: str = "bad_request"

    def __init__(self, message: str, *, details: dict | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.details = details or {}


class AuthenticationError(AppError):
    status_code = status.HTTP_401_UNAUTHORIZED
    code = "unauthenticated"


class PermissionError_(AppError):
    status_code = status.HTTP_403_FORBIDDEN
    code = "forbidden"


class NotFoundError(AppError):
    status_code = status.HTTP_404_NOT_FOUND
    code = "not_found"


class ConflictError(AppError):
    status_code = status.HTTP_409_CONFLICT
    code = "conflict"


class QuotaExceededError(AppError):
    """Free user has used every edit in the current weekly window."""

    status_code = status.HTTP_403_FORBIDDEN
    code = "quota_exceeded"


class InvalidPdfError(AppError):
    status_code = status.HTTP_422_UNPROCESSABLE_ENTITY
    code = "invalid_pdf"


class PayloadTooLargeError(AppError):
    status_code = status.HTTP_413_REQUEST_ENTITY_TOO_LARGE
    code = "file_too_large"


class PdfProcessingError(AppError):
    status_code = status.HTTP_422_UNPROCESSABLE_ENTITY
    code = "pdf_processing_failed"


def _payload(code: str, message: str, details: dict | None = None) -> dict:
    body: dict = {"error": {"code": code, "message": message}}
    if details:
        body["error"]["details"] = details
    return body


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error(_: Request, exc: AppError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=_payload(exc.code, exc.message, exc.details),
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_error(
        _: Request, exc: RequestValidationError
    ) -> JSONResponse:
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            content=_payload(
                "validation_error",
                "One or more fields are invalid.",
                {"fields": jsonable_encoder(exc.errors())},
            ),
        )
