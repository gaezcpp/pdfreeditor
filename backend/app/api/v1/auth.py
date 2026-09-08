from __future__ import annotations

import logging

from fastapi import APIRouter, Response, status
from fastapi.concurrency import run_in_threadpool

from app.api.deps import CurrentUser, DbSession
from app.schemas.auth import (
    LoginRequest,
    PasswordResetConfirm,
    PasswordResetRequest,
    RefreshRequest,
    RegisterRequest,
    TokenResponse,
)
from app.schemas.user import UserOut
from app.services import auth as auth_service
from app.services.mail import send_password_reset_email

router = APIRouter(prefix="/auth", tags=["auth"])
logger = logging.getLogger(__name__)


@router.post(
    "/register",
    response_model=TokenResponse,
    status_code=status.HTTP_201_CREATED,
)
async def register(payload: RegisterRequest, db: DbSession) -> TokenResponse:
    """Create an account and sign the device in immediately."""
    user = await auth_service.register(
        db,
        email=payload.email,
        password=payload.password,
        full_name=payload.full_name,
    )
    access, refresh, expires_in = await auth_service.issue_tokens(
        db, user, device_label=payload.device_label
    )
    await db.commit()
    return TokenResponse(
        access_token=access, refresh_token=refresh, expires_in=expires_in
    )


@router.post("/login", response_model=TokenResponse)
async def login(payload: LoginRequest, db: DbSession) -> TokenResponse:
    user = await auth_service.authenticate(
        db, email=payload.email, password=payload.password
    )
    access, refresh, expires_in = await auth_service.issue_tokens(
        db, user, device_label=payload.device_label
    )
    await db.commit()
    return TokenResponse(
        access_token=access, refresh_token=refresh, expires_in=expires_in
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh(payload: RefreshRequest, db: DbSession) -> TokenResponse:
    """Rotate a refresh token: the old one is revoked as the new pair is issued."""
    _, access, new_refresh, expires_in = await auth_service.rotate_refresh_token(
        db, raw_token=payload.refresh_token
    )
    await db.commit()
    return TokenResponse(
        access_token=access, refresh_token=new_refresh, expires_in=expires_in
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(payload: RefreshRequest, db: DbSession) -> Response:
    """Sign out one device. Idempotent — an unknown token still returns 204."""
    await auth_service.revoke_refresh_token(db, raw_token=payload.refresh_token)
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/password-reset/request")
async def password_reset_request(
    payload: PasswordResetRequest, db: DbSession
) -> dict[str, str]:
    raw = await auth_service.request_password_reset(db, email=payload.email)
    await db.commit()
    if raw is not None:
        # SMTP can replace this delivery path without changing token semantics.
        try:
            await run_in_threadpool(send_password_reset_email, payload.email, raw)
        except RuntimeError:
            if auth_service.settings.is_production:
                logger.exception("Password reset email delivery is not configured.")
            else:
                logger.info("Development password reset token: %s", raw)
    return {"message": "If the account exists, reset instructions have been sent."}


@router.post("/password-reset/confirm", status_code=status.HTTP_204_NO_CONTENT)
async def password_reset_confirm(
    payload: PasswordResetConfirm, db: DbSession
) -> Response:
    await auth_service.reset_password(
        db, raw_token=payload.token, password=payload.password
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser) -> UserOut:
    return UserOut.model_validate(user)
