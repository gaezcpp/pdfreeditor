"""Registration, login, and refresh-token rotation."""

from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.errors import AuthenticationError, ConflictError
from app.core.security import (
    create_access_token,
    generate_refresh_token,
    hash_password,
    hash_refresh_token,
    verify_password,
)
from app.core.timeutils import utcnow
from app.models.refresh_token import RefreshToken
from app.models.user import User
from app.services import quota


def normalize_email(email: str) -> str:
    return email.strip().lower()


async def register(
    db: AsyncSession,
    *,
    email: str,
    password: str,
    full_name: str | None = None,
) -> User:
    email = normalize_email(email)
    user = User(
        email=email,
        password_hash=hash_password(password),
        full_name=full_name,
        quota_period_start=quota.current_period_start(),
        edits_used=0,
    )
    db.add(user)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        # Don't leak which addresses exist beyond what signup inherently reveals.
        raise ConflictError("An account with this email already exists.") from exc
    return user


async def authenticate(db: AsyncSession, *, email: str, password: str) -> User:
    result = await db.execute(select(User).where(User.email == normalize_email(email)))
    user = result.scalar_one_or_none()

    # Hash even when the user is missing so response time does not reveal
    # whether the address is registered.
    password_hash = user.password_hash if user else _DUMMY_HASH
    password_ok = verify_password(password, password_hash)

    if user is None or not password_ok:
        raise AuthenticationError("Incorrect email or password.")
    if not user.is_active:
        raise AuthenticationError("This account has been disabled.")
    return user


async def issue_tokens(
    db: AsyncSession,
    user: User,
    *,
    device_label: str | None = None,
) -> tuple[str, str, int]:
    """Return (access_token, refresh_token, access_expires_in_seconds)."""
    access_token, expires_in = create_access_token(user.id)
    raw_refresh, refresh_hash = generate_refresh_token()

    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=refresh_hash,
            expires_at=utcnow() + timedelta(days=settings.refresh_token_expire_days),
            device_label=device_label,
        )
    )
    await db.flush()
    return access_token, raw_refresh, expires_in


async def rotate_refresh_token(
    db: AsyncSession, *, raw_token: str
) -> tuple[User, str, str, int]:
    """Exchange a refresh token for a new pair, revoking the old one."""
    now = utcnow()
    result = await db.execute(
        select(RefreshToken).where(
            RefreshToken.token_hash == hash_refresh_token(raw_token)
        )
    )
    token = result.scalar_one_or_none()
    if token is None or not token.is_usable_at(now):
        raise AuthenticationError("This session has expired. Please sign in again.")

    user = await db.get(User, token.user_id)
    if user is None or not user.is_active:
        raise AuthenticationError("This account is no longer available.")

    token.revoked_at = now
    access_token, raw_refresh, expires_in = await issue_tokens(
        db, user, device_label=token.device_label
    )
    return user, access_token, raw_refresh, expires_in


async def revoke_refresh_token(db: AsyncSession, *, raw_token: str) -> None:
    """Log out one device. Unknown tokens are a no-op, never an error."""
    result = await db.execute(
        select(RefreshToken).where(
            RefreshToken.token_hash == hash_refresh_token(raw_token)
        )
    )
    token = result.scalar_one_or_none()
    if token is not None and token.revoked_at is None:
        token.revoked_at = utcnow()


# A valid bcrypt hash of a value nothing can match, used for timing parity.
_DUMMY_HASH = "$2b$12$C6UzMDM.H6dfI/f/IKcEe.7ZG5Q1ZKq0Q3rGkq0Zk1nJc5Z2i0Zqu"
