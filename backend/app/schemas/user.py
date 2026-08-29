from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr

from app.services.quota import UNLIMITED, QuotaStatus


class QuotaOut(BaseModel):
    """Quota as the app should display it.

    ``limit`` and ``remaining`` are ``null`` for premium users rather than a
    sentinel number, so the UI branches on absence instead of on -1.
    """

    limit: int | None
    used: int
    remaining: int | None
    period_start: datetime
    period_end: datetime

    @classmethod
    def from_status(cls, status: QuotaStatus) -> QuotaOut:
        return cls(
            limit=None if status.limit == UNLIMITED else status.limit,
            used=status.used,
            remaining=None if status.remaining == UNLIMITED else status.remaining,
            period_start=status.period_start,
            period_end=status.period_end,
        )


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: EmailStr
    full_name: str | None
    plan: str
    created_at: datetime


class UserStatusOut(BaseModel):
    """Response of ``GET /users/me/status`` — the paywall's single source."""

    user: UserOut
    is_premium: bool
    premium_until: datetime | None
    quota: QuotaOut
