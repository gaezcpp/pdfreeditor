from __future__ import annotations

from fastapi import APIRouter
from fastapi.concurrency import run_in_threadpool

from app.api.deps import CurrentUser, DbSession
from app.core.config import settings
from app.core.timeutils import utcnow
from app.schemas.user import QuotaOut, UserOut, UserStatusOut
from app.services import quota, subscription
from app.services.mail import send_premium_request_email

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me/status", response_model=UserStatusOut)
async def read_status(user: CurrentUser, db: DbSession) -> UserStatusOut:
    """Everything the paywall and the quota badge need, in one call.

    The entitlement cache is refreshed here (the app polls this on launch and
    after a purchase), so a subscription that lapsed since the last request is
    reflected without waiting for a background job.
    """
    now = utcnow()
    await subscription.sync_entitlement(db, user, now=now)
    await db.commit()

    status = quota.get_status(user, now)
    return UserStatusOut(
        user=UserOut.model_validate(user),
        is_premium=status.is_premium,
        premium_until=user.premium_until,
        quota=QuotaOut.from_status(status),
    )


@router.post("/me/premium-request")
async def request_premium(user: CurrentUser) -> dict[str, str]:
    try:
        await run_in_threadpool(send_premium_request_email, user.email)
    except RuntimeError:
        # Keep request usable in development; admin can inspect container logs.
        if not settings.is_production:
            import logging
            logging.getLogger(__name__).info("Premium request from %s", user.email)
    return {"message": "Premium request received."}
