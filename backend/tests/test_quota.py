"""The quota rules the business model rests on."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from app.models.enums import Plan
from app.models.user import User
from app.services import quota

LIMIT = 3


def _user(**overrides) -> User:
    defaults = dict(
        email="a@example.com",
        password_hash="x",
        plan=Plan.FREE,
        quota_period_start=quota.current_period_start(),
        edits_used=0,
    )
    defaults.update(overrides)
    return User(**defaults)


async def _add(db, user: User) -> User:
    db.add(user)
    await db.commit()
    return user


def test_period_start_is_monday_midnight_utc():
    friday = datetime(2026, 8, 28, 17, 30, tzinfo=UTC)
    assert quota.current_period_start(friday) == datetime(
        2026, 8, 24, tzinfo=UTC
    )


def test_period_start_is_stable_across_the_whole_week():
    monday = datetime(2026, 8, 24, 0, 0, tzinfo=UTC)
    sunday_night = datetime(2026, 8, 30, 23, 59, 59, tzinfo=UTC)
    assert quota.current_period_start(monday) == quota.current_period_start(sunday_night)


async def test_consume_stops_at_the_limit(db):
    user = await _add(db, _user())

    for expected in (1, 2, 3):
        assert await quota.try_consume(db, user.id, limit=LIMIT) == expected
        await db.commit()

    assert await quota.try_consume(db, user.id, limit=LIMIT) is None


async def test_counter_resets_lazily_in_a_new_week(db):
    last_week = quota.current_period_start() - timedelta(days=7)
    user = await _add(db, _user(quota_period_start=last_week, edits_used=LIMIT))

    # Exhausted last week, yet the first charge of this week succeeds and the
    # counter restarts at 1 — no scheduled reset job involved.
    assert await quota.try_consume(db, user.id, limit=LIMIT) == 1


async def test_status_reports_a_stale_counter_as_unused(db):
    last_week = quota.current_period_start() - timedelta(days=7)
    user = _user(quota_period_start=last_week, edits_used=LIMIT)

    status = quota.get_status(user)
    assert status.used == 0
    assert status.remaining == status.limit


async def test_premium_is_unlimited():
    user = _user(plan=Plan.PREMIUM, premium_until=None)
    status = quota.get_status(user)

    assert status.is_premium
    assert status.is_unlimited


async def test_lapsed_premium_falls_back_to_the_free_quota():
    yesterday = datetime.now(UTC) - timedelta(days=1)
    user = _user(plan=Plan.PREMIUM, premium_until=yesterday)

    assert quota.get_status(user).is_premium is False


async def test_refund_returns_the_edit(db):
    user = await _add(db, _user())
    await quota.try_consume(db, user.id, limit=LIMIT)
    await db.commit()

    await quota.refund(db, user.id)
    await db.commit()

    await db.refresh(user)
    assert user.edits_used == 0


async def test_refund_is_ignored_after_the_week_rolls_over(db):
    """A charge from last week must not create a free edit in this one."""
    user = await _add(db, _user(edits_used=0))
    charged_at = datetime.now(UTC) - timedelta(days=7)

    await quota.refund(db, user.id, now=charged_at)
    await db.commit()

    await db.refresh(user)
    assert user.edits_used == 0


async def test_two_sessions_cannot_share_the_last_edit(db, session_factory):
    """The check-and-charge is one statement, so a second session sees it.

    This asserts the mechanism, not true parallelism: because the decision and
    the write happen in the same UPDATE, a session that starts after the first
    commits can never observe the pre-charge count.
    """
    user = await _add(db, _user(edits_used=LIMIT - 1))

    async def attempt() -> int | None:
        async with session_factory() as session:
            result = await quota.try_consume(session, user.id, limit=LIMIT)
            await session.commit()
            return result

    results = [await attempt(), await attempt()]

    assert results == [LIMIT, None]


async def test_inactive_users_cannot_consume(db):
    user = await _add(db, _user(is_active=False))
    assert await quota.try_consume(db, user.id, limit=LIMIT) is None
