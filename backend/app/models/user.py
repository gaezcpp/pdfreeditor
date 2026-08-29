from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

import sqlalchemy as sa
from sqlalchemy import Boolean, CheckConstraint, DateTime, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.timeutils import as_utc
from app.db.base import GUID, Base, TimestampMixin
from app.models.enums import Plan

if TYPE_CHECKING:
    from app.models.edit_session import EditSession
    from app.models.refresh_token import RefreshToken
    from app.models.subscription import Subscription
    from app.models.usage_log import UsageLog


class User(TimestampMixin, Base):
    """A registered account plus its denormalized entitlement and quota state.

    ``plan`` / ``premium_until`` are a cache of the authoritative rows in
    ``subscriptions`` so the hot upload path needs no join. They are only ever
    written by ``services.subscription.sync_entitlement``.

    Quota uses a rolling window instead of a scheduled reset job: the current
    week's start is derived from the clock, and ``edits_used`` is lazily reset
    the first time a user is charged in a new window. No cron, no drift, and a
    user who never returns is never touched.
    """

    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint("edits_used >= 0", name="edits_used_non_negative"),
    )

    id: Mapped[uuid.UUID] = mapped_column(GUID(), primary_key=True, default=uuid.uuid4)

    email: Mapped[str] = mapped_column(String(320), unique=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    full_name: Mapped[str | None] = mapped_column(String(120))

    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default=sa.true(), nullable=False
    )

    # --- Entitlement cache ---------------------------------------------------
    plan: Mapped[str] = mapped_column(
        String(20), default=Plan.FREE, server_default=Plan.FREE, nullable=False
    )
    premium_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # --- Quota window --------------------------------------------------------
    quota_period_start: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    edits_used: Mapped[int] = mapped_column(
        Integer, default=0, server_default="0", nullable=False
    )

    subscriptions: Mapped[list[Subscription]] = relationship(
        back_populates="user", cascade="all, delete-orphan", lazy="selectin"
    )
    usage_logs: Mapped[list[UsageLog]] = relationship(
        back_populates="user", cascade="all, delete-orphan", lazy="noload"
    )
    refresh_tokens: Mapped[list[RefreshToken]] = relationship(
        back_populates="user", cascade="all, delete-orphan", lazy="noload"
    )
    edit_sessions: Mapped[list[EditSession]] = relationship(
        back_populates="user", cascade="all, delete-orphan", lazy="noload"
    )

    def is_premium_at(self, now: datetime) -> bool:
        if self.plan != Plan.PREMIUM:
            return False
        return self.premium_until is None or as_utc(self.premium_until) > as_utc(now)
