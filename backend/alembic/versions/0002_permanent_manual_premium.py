"""Allow manual subscriptions without an expiry.

Revision ID: 0002_permanent_manual_premium
Revises: 0002_edit_sessions
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0002_permanent_manual_premium"
down_revision: str | None = "0002_edit_sessions"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column(
        "subscriptions",
        "current_period_end",
        existing_type=sa.DateTime(timezone=True),
        nullable=True,
    )


def downgrade() -> None:
    op.alter_column(
        "subscriptions",
        "current_period_end",
        existing_type=sa.DateTime(timezone=True),
        nullable=False,
    )
