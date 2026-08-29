from __future__ import annotations

import json
import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.timeutils import as_utc
from app.db.base import GUID, Base, TimestampMixin

if TYPE_CHECKING:
    from app.models.user import User


class EditSession(TimestampMixin, Base):
    """An open editing session: one uploaded document plus its pending edits.

    The WYSIWYG editor is inherently multi-request — read the page, render it,
    change a word, render again — so the upload is held server-side for the
    length of the session instead of being re-sent each time.

    Edits are stored as an operation log rather than a mutated file. Replaying
    the log onto the pristine original on every change keeps object indices
    stable, makes undo a pop, and stops redaction artifacts from compounding.
    """

    __tablename__ = "edit_sessions"

    id: Mapped[uuid.UUID] = mapped_column(GUID(), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        GUID(), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    original_filename: Mapped[str] = mapped_column(String(255), nullable=False)
    page_count: Mapped[int] = mapped_column(Integer, nullable=False)

    # JSON text rather than a JSON column: the same DDL works on PostgreSQL and
    # on the SQLite used for local development and tests.
    operations_json: Mapped[str] = mapped_column(
        Text, nullable=False, default="[]", server_default="[]"
    )

    # Bumped on every change so a rendered page can be cached per revision.
    revision: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )

    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    user: Mapped[User] = relationship(back_populates="edit_sessions")

    @property
    def operations(self) -> list[dict]:
        return json.loads(self.operations_json)

    @operations.setter
    def operations(self, value: list[dict]) -> None:
        self.operations_json = json.dumps(value)

    def is_open_at(self, now: datetime) -> bool:
        return self.closed_at is None and as_utc(self.expires_at) > as_utc(now)
