from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import DateTime, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.timeutils import as_utc
from app.db.base import GUID, Base, TimestampMixin

if TYPE_CHECKING:
    from app.models.user import User


class RefreshToken(TimestampMixin, Base):
    """A rotating refresh token, stored only as a SHA-256 hash.

    Rotation is enforced by ``revoked_at``: refreshing marks the old row revoked
    and issues a new one, so a stolen token stops working the moment the real
    device refreshes.
    """

    __tablename__ = "refresh_tokens"

    id: Mapped[uuid.UUID] = mapped_column(GUID(), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        GUID(), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # unique + index is one unique index, not a constraint plus an index.
    token_hash: Mapped[str] = mapped_column(
        String(64), nullable=False, unique=True, index=True
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    device_label: Mapped[str | None] = mapped_column(String(120))

    user: Mapped[User] = relationship(back_populates="refresh_tokens")

    def is_usable_at(self, now: datetime) -> bool:
        return self.revoked_at is None and as_utc(self.expires_at) > as_utc(now)
