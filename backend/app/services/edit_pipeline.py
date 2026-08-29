"""The shared pipeline every PDF endpoint runs through.

One place owns the ordering that the whole business model depends on:

1. Charge the quota **before** processing, in a single atomic statement, then
   commit so the row lock is not held across a multi-second CPU job.
2. Process. Premium users skip step 1 entirely but are still logged.
3. On failure, refund the charge and log the attempt. A user is never billed an
   edit for a file the server could not produce.
4. On success, log and stream the result, deleting every temp file once the
   bytes are on the wire.

Endpoints only supply the "produce a file" part; they cannot get the ordering
wrong because they never see it.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path

from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.background import BackgroundTask

from app.core.config import settings
from app.core.errors import AppError, QuotaExceededError
from app.core.timeutils import utcnow
from app.models.enums import UsageStatus
from app.models.user import User
from app.services import quota, usage
from app.services.pdf.storage import TempWorkspace

logger = logging.getLogger(__name__)


@dataclass
class EditResult:
    """What an endpoint's ``produce`` callback hands back."""

    path: Path
    filename: str
    media_type: str = "application/pdf"
    page_count: int | None = None
    input_bytes: int | None = None


Producer = Callable[[TempWorkspace], Awaitable[EditResult]]


async def run_edit(
    db: AsyncSession,
    user: User,
    *,
    action: str,
    produce: Producer,
) -> FileResponse:
    now = utcnow()
    is_premium = user.is_premium_at(now)
    charged = False
    remaining: int | None = None

    if not is_premium:
        used = await quota.try_consume(
            db,
            user.id,
            limit=settings.free_weekly_edit_quota,
            now=now,
        )
        if used is None:
            await usage.record(
                db,
                user_id=user.id,
                action=action,
                status=UsageStatus.REJECTED,
                quota_charged=False,
                error_code="quota_exceeded",
            )
            await db.commit()
            raise QuotaExceededError(
                "You have used all your free edits for this week.",
                details={
                    "limit": settings.free_weekly_edit_quota,
                    "resets_at": quota.next_period_start(now).isoformat(),
                },
            )
        charged = True
        remaining = max(settings.free_weekly_edit_quota - used, 0)
        # Release the row lock before the slow part.
        await db.commit()

    workspace = TempWorkspace()
    started = time.perf_counter()

    try:
        result = await produce(workspace)
    except BaseException as exc:  # includes client disconnects and cancellation
        workspace.cleanup()
        if charged:
            await quota.refund(db, user.id, now=now)
        await usage.record(
            db,
            user_id=user.id,
            action=action,
            status=UsageStatus.FAILED,
            quota_charged=False,
            duration_ms=_elapsed_ms(started),
            error_code=getattr(exc, "code", None) or type(exc).__name__,
            error_message=str(exc) if isinstance(exc, AppError) else None,
        )
        await db.commit()
        if not isinstance(exc, AppError):
            logger.exception("Unhandled failure during %s", action)
        raise

    output_bytes = result.path.stat().st_size
    await usage.record(
        db,
        user_id=user.id,
        action=action,
        status=UsageStatus.SUCCEEDED,
        quota_charged=charged,
        input_bytes=result.input_bytes,
        output_bytes=output_bytes,
        page_count=result.page_count,
        duration_ms=_elapsed_ms(started),
    )
    await db.commit()

    # Taken from the UPDATE's RETURNING value: the ORM copy of ``user`` was not
    # touched by the atomic charge and would report a stale count.
    headers = {"X-Quota-Remaining": str(remaining)} if remaining is not None else {}

    return FileResponse(
        path=result.path,
        media_type=result.media_type,
        filename=result.filename,
        headers=headers,
        # Runs once the response body has been sent — the only point at which
        # deleting the file is safe.
        background=BackgroundTask(workspace.cleanup),
    )


def _elapsed_ms(started: float) -> int:
    return int((time.perf_counter() - started) * 1000)
