from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

import sqlalchemy as sa
from sqlalchemy import Boolean, DateTime, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.timeutils import as_utc
from app.db.base import GUID, Base, TimestampMixin
from app.models.enums import BillingProvider, SubscriptionStatus

if TYPE_CHECKING:
    from app.models.user import User


class Subscription(TimestampMixin, Base):
    """Authoritative record of a purchase, one row per store subscription.

    History is kept (rows are never deleted on cancel) so support and revenue
    reporting can reconstruct what a user was entitled to at any past moment.
    """

    __tablename__ = "subscriptions"
    __table_args__ = (
        UniqueConstraint(
            "provider",
            "provider_subscription_id",
            name="uq_subscriptions_provider_provider_subscription_id",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(GUID(), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        GUID(), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    provider: Mapped[str] = mapped_column(String(30), nullable=False)
    provider_subscription_id: Mapped[str] = mapped_column(String(255), nullable=False)
    product_id: Mapped[str] = mapped_column(String(120), nullable=False)

    status: Mapped[str] = mapped_column(String(20), nullable=False)
    auto_renew: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=sa.false(), nullable=False
    )

    current_period_start: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    current_period_end: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    canceled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    user: Mapped[User] = relationship(back_populates="subscriptions")

    def grants_premium_at(self, now: datetime) -> bool:
        active = self.status in {SubscriptionStatus.ACTIVE, SubscriptionStatus.IN_GRACE}
        return active and as_utc(self.current_period_end) > as_utc(now)

    @property
    def is_store_purchase(self) -> bool:
        return self.provider != BillingProvider.MANUAL
