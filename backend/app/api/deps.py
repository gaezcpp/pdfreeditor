"""Shared FastAPI dependencies: the current user and the quota gate."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AuthenticationError
from app.core.security import InvalidTokenError, decode_access_token
from app.core.timeutils import utcnow
from app.db.session import get_db
from app.models.user import User
from app.services import quota

# auto_error=False so a missing header raises our JSON error shape, not FastAPI's.
bearer_scheme = HTTPBearer(auto_error=False)

DbSession = Annotated[AsyncSession, Depends(get_db)]


async def get_current_user(
    db: DbSession,
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ] = None,
) -> User:
    if credentials is None or not credentials.credentials:
        raise AuthenticationError("Missing authentication token.")

    try:
        user_id = decode_access_token(credentials.credentials)
    except InvalidTokenError as exc:
        raise AuthenticationError("Invalid or expired token.") from exc

    user = await db.get(User, user_id)
    if user is None or not user.is_active:
        raise AuthenticationError("This account is no longer available.")
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


async def get_quota_status(user: CurrentUser) -> quota.QuotaStatus:
    """Advisory read of the quota — informational only.

    Charging still happens atomically inside the endpoint. Gating on this value
    alone would let two parallel uploads both see the last edit as available.
    """
    return quota.get_status(user, utcnow())


QuotaStatusDep = Annotated[quota.QuotaStatus, Depends(get_quota_status)]
