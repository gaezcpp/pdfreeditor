"""Timezone helpers.

PostgreSQL returns aware datetimes for ``timestamptz``; SQLite (used by the test
suite) returns naive ones. Everything stored is UTC, so normalize on read rather
than sprinkling ``tzinfo`` checks through the business logic.
"""

from __future__ import annotations

from datetime import UTC, datetime


def utcnow() -> datetime:
    return datetime.now(UTC)


def as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)
