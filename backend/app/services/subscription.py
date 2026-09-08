"""Entitlement: turning subscription rows into the cached flag on ``users``.

``users.plan`` / ``users.premium_until`` exist purely so the upload path can
decide "premium?" without a join. They must never be written anywhere but here,
or the cache and the source of truth will drift.

Store receipt verification (Google Play / App Store) is deliberately not
implemented yet — ``grant_manual_premium`` is the seam it will plug into once
billing is wired up.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFoundError
from app.core.timeutils import as_utc, utcnow
from app.models.enums import BillingProvider, Plan, SubscriptionStatus
from app.models.subscription import Subscription
from app.models.user import User


async def sync_entitlement(
    db: AsyncSession, user: User, *, now: datetime | None = None
) -> User:
    """Recompute the cached plan from the user's subscription rows."""
    now = now or utcnow()
    result = await db.execute(
        select(Subscription).where(Subscription.user_id == user.id)
    )
    subscriptions = list(result.scalars())

    granting = [sub for sub in subscriptions if sub.grants_premium_at(now)]
    if granting:
        user.plan = Plan.PREMIUM
        permanent = [sub for sub in granting if sub.current_period_end is None]
        user.premium_until = None if permanent else max(
            as_utc(sub.current_period_end) for sub in granting
        )
    else:
        user.plan = Plan.FREE
        user.premium_until = None
    await db.flush()
    return user


async def grant_manual_premium(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    until: datetime | None,
    product_id: str = "premium.manual",
) -> User:
    """Grant premium without a store purchase — support credits, testing, comps."""
    user = await db.get(User, user_id)
    if user is None:
        raise NotFoundError("User not found.")

    now = utcnow()
    db.add(
        Subscription(
            user_id=user.id,
            provider=BillingProvider.MANUAL,
            provider_subscription_id=f"manual:{uuid.uuid4()}",
            product_id=product_id,
            status=SubscriptionStatus.ACTIVE,
            auto_renew=False,
            current_period_start=now,
            # NULL means no expiry. The entitlement query treats this as
            # permanent while the row remains active.
            current_period_end=until,
        )
    )
    await db.flush()
    return await sync_entitlement(db, user, now=now)


async def expire_stale_subscriptions(db: AsyncSession) -> int:
    """Mark ended subscriptions expired and refresh the affected users' cache.

    Only housekeeping: ``grants_premium_at`` already ignores a lapsed period, so
    correctness does not depend on this running. Safe to schedule hourly, safe
    to skip.
    """
    now = utcnow()
    result = await db.execute(
        select(Subscription).where(
            Subscription.status.in_(
                [SubscriptionStatus.ACTIVE, SubscriptionStatus.IN_GRACE]
            ),
            Subscription.current_period_end <= now,
        )
    )
    stale = list(result.scalars())
    affected_user_ids = set()
    for subscription in stale:
        subscription.status = SubscriptionStatus.EXPIRED
        affected_user_ids.add(subscription.user_id)

    for user_id in affected_user_ids:
        user = await db.get(User, user_id)
        if user is not None:
            await sync_entitlement(db, user, now=now)

    return len(stale)
