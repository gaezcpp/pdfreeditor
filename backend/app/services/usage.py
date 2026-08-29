"""Writing the audit trail for edit attempts."""

from __future__ import annotations

import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.usage_log import UsageLog


async def record(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    action: str,
    status: str,
    quota_charged: bool,
    input_bytes: int | None = None,
    output_bytes: int | None = None,
    page_count: int | None = None,
    duration_ms: int | None = None,
    error_code: str | None = None,
    error_message: str | None = None,
) -> UsageLog:
    log = UsageLog(
        user_id=user_id,
        action=action,
        status=status,
        quota_charged=quota_charged,
        input_bytes=input_bytes,
        output_bytes=output_bytes,
        page_count=page_count,
        duration_ms=duration_ms,
        error_code=error_code,
        # Truncated: messages can carry filenames and library internals.
        error_message=error_message[:500] if error_message else None,
    )
    db.add(log)
    await db.flush()
    return log
