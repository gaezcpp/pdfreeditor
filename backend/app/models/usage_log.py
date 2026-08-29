from __future__ import annotations

import uuid
from typing import TYPE_CHECKING

import sqlalchemy as sa
from sqlalchemy import Boolean, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import GUID, Base, TimestampMixin
from app.models.enums import UsageStatus

if TYPE_CHECKING:
    from app.models.user import User


class UsageLog(TimestampMixin, Base):
    """One row per attempted edit — the audit trail behind every quota change.

    Stores only metadata about the file (size, page count), never the file or
    its name's contents, so nothing user-uploaded outlives the request.
    """

    __tablename__ = "usage_logs"
    __table_args__ = (
        Index("ix_usage_logs_user_id_created_at", "user_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(GUID(), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        GUID(), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )

    action: Mapped[str] = mapped_column(String(30), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), default=UsageStatus.SUCCEEDED, nullable=False
    )

    input_bytes: Mapped[int | None] = mapped_column(Integer)
    output_bytes: Mapped[int | None] = mapped_column(Integer)
    page_count: Mapped[int | None] = mapped_column(Integer)
    duration_ms: Mapped[int | None] = mapped_column(Integer)

    # False for premium users, whose edits are logged but never charged.
    quota_charged: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default=sa.true(), nullable=False
    )
    error_code: Mapped[str | None] = mapped_column(String(50))
    error_message: Mapped[str | None] = mapped_column(Text)

    user: Mapped[User] = relationship(back_populates="usage_logs")
