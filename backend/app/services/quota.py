"""Weekly edit quota: window arithmetic and race-free consumption.

Design notes
------------
* **Rolling window, not a reset job.** The current window is derived from the
  clock (Monday 00:00 UTC). A user's counter is reset lazily the first time they
  are charged in a new window, so there is no scheduled task to fall behind, no
  thundering herd at midnight, and no drift if a worker misses a run.
* **One statement per charge.** Consumption is a single conditional ``UPDATE``
  with ``RETURNING``. Two concurrent uploads cannot both read "1 edit left" and
  both succeed — the database serializes them on the row.
* **Reserve, then refund.** Callers charge *before* processing and refund if
  processing fails. Checking first and charging later would leave a window in
  which parallel requests both pass the check.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import case, or_, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.timeutils import as_utc, utcnow
from app.models.user import User

UNLIMITED = -1


def current_period_start(now: datetime | None = None) -> datetime:
    """Start of the quota window containing ``now`` — Monday 00:00 UTC."""
    now = as_utc(now or utcnow())
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight - timedelta(days=midnight.weekday())


def next_period_start(now: datetime | None = None) -> datetime:
    return current_period_start(now) + timedelta(days=7)


@dataclass(frozen=True)
class QuotaStatus:
    is_premium: bool
    limit: int  # UNLIMITED for premium
    used: int
    remaining: int  # UNLIMITED for premium
    period_start: datetime
    period_end: datetime

    @property
    def is_unlimited(self) -> bool:
        return self.limit == UNLIMITED


def get_status(user: User, now: datetime | None = None) -> QuotaStatus:
    """Read-only view of the user's quota, with the stale window folded in.

    A counter left over from an earlier week reads as 0 used without touching
    the row; the stored value is only rewritten when an edit is actually charged.
    """
    now = now or utcnow()
    period_start = current_period_start(now)
    period_end = period_start + timedelta(days=7)

    if user.is_premium_at(now):
        return QuotaStatus(
            is_premium=True,
            limit=UNLIMITED,
            used=0,
            remaining=UNLIMITED,
            period_start=period_start,
            period_end=period_end,
        )

    stored_start = as_utc(user.quota_period_start)
    used = user.edits_used if stored_start >= period_start else 0
    limit = settings.free_weekly_edit_quota
    return QuotaStatus(
        is_premium=False,
        limit=limit,
        used=used,
        remaining=max(limit - used, 0),
        period_start=period_start,
        period_end=period_end,
    )


async def try_consume(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    limit: int,
    now: datetime | None = None,
) -> int | None:
    """Atomically charge one edit. Returns edits used after the charge, or None.

    ``None`` means the quota is exhausted and nothing was written. The caller
    must commit; the row stays locked until then, which is what keeps two
    parallel uploads from sharing the last remaining edit.
    """
    period_start = current_period_start(now)

    is_new_period = User.quota_period_start < period_start
    stmt = (
        update(User)
        .where(
            User.id == user_id,
            User.is_active.is_(True),
            # A new window always has room; inside the window, respect the limit.
            or_(is_new_period, User.edits_used < limit),
        )
        .values(
            edits_used=case((is_new_period, 1), else_=User.edits_used + 1),
            quota_period_start=period_start,
        )
        .returning(User.edits_used)
        # The database is the authority here. Letting the ORM mirror the change
        # onto in-session objects would also make it re-evaluate the WHERE clause
        # in Python against a stale copy.
        .execution_options(synchronize_session=False)
    )
    result = await db.execute(stmt)
    return result.scalar_one_or_none()


async def refund(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    now: datetime | None = None,
) -> None:
    """Give back one edit after a failed operation.

    Guarded by the window: if the week rolled over between the charge and the
    failure, the charge no longer belongs to the current counter and refunding
    it would hand out a free edit.
    """
    period_start = current_period_start(now)
    stmt = (
        update(User)
        .where(
            User.id == user_id,
            User.quota_period_start == period_start,
            User.edits_used > 0,
        )
        .values(edits_used=User.edits_used - 1)
        .execution_options(synchronize_session=False)
    )
    await db.execute(stmt)
