"""Grant, inspect, or revoke premium from the server.

Deliberately a CLI and not an HTTP endpoint: anything that can hand out premium
is a privilege escalation, and there is no reason to expose it to the internet
just to make it convenient. Run it where the database lives.

    python -m scripts.grant_premium grant user@example.com --days 30
    python -m scripts.grant_premium status user@example.com
    python -m scripts.grant_premium revoke user@example.com

Once billing is wired up this becomes the support tool rather than the only way
in — the store receipt flow will call the same `services.subscription` code.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import timedelta

from sqlalchemy import select

from app.core.timeutils import utcnow
from app.db.session import SessionFactory, engine
from app.models.enums import Plan, SubscriptionStatus
from app.models.subscription import Subscription
from app.models.user import User
from app.services import quota, subscription


async def _find(db, email: str) -> User:
    result = await db.execute(select(User).where(User.email == email.strip().lower()))
    user = result.scalar_one_or_none()
    if user is None:
        raise SystemExit(f"No account found for {email!r}.")
    return user


async def grant(email: str, days: int) -> None:
    async with SessionFactory() as db:
        user = await _find(db, email)
        until = utcnow() + timedelta(days=days)
        await subscription.grant_manual_premium(db, user.id, until=until)
        await db.commit()
        await db.refresh(user)
        print(f"{user.email} is premium until {until:%Y-%m-%d %H:%M} UTC.")
        print("The app picks this up on its next GET /users/me/status:")
        print("pull to refresh on the home screen, or sign out and back in.")


async def revoke(email: str) -> None:
    async with SessionFactory() as db:
        user = await _find(db, email)
        now = utcnow()

        result = await db.execute(
            select(Subscription).where(Subscription.user_id == user.id)
        )
        cancelled = 0
        for row in result.scalars():
            if row.status in {SubscriptionStatus.ACTIVE, SubscriptionStatus.IN_GRACE}:
                row.status = SubscriptionStatus.CANCELED
                row.canceled_at = now
                cancelled += 1

        # The cached flag on `users` is only ever written here, via the service.
        await subscription.sync_entitlement(db, user, now=now)
        await db.commit()
        print(f"Cancelled {cancelled} subscription(s); {user.email} is back to free.")


async def status(email: str) -> None:
    async with SessionFactory() as db:
        user = await _find(db, email)
        now = utcnow()
        await subscription.sync_entitlement(db, user, now=now)
        await db.commit()

        state = quota.get_status(user, now)
        print(f"email     : {user.email}")
        print(f"plan      : {user.plan}")
        until = user.premium_until
        suffix = f" (until {until:%Y-%m-%d %H:%M} UTC)" if until else ""
        print(f"premium   : {'yes' if state.is_premium else 'no'}{suffix}")
        if state.is_unlimited:
            print("quota     : unlimited")
        else:
            print(f"quota     : {state.used}/{state.limit} used this week")
            print(f"resets    : {state.period_end:%Y-%m-%d %H:%M} UTC")


async def listing(limit: int) -> None:
    async with SessionFactory() as db:
        result = await db.execute(
            select(User).order_by(User.created_at.desc()).limit(limit)
        )
        rows = list(result.scalars())
        if not rows:
            print("No accounts yet.")
            return
        width = max(len(row.email) for row in rows)
        for row in rows:
            marker = "premium" if row.plan == Plan.PREMIUM else "free"
            print(f"{row.email:<{width}}  {marker}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    granting = commands.add_parser("grant", help="Give an account premium.")
    granting.add_argument("email")
    granting.add_argument(
        "--days", type=int, default=30, help="How long it lasts (default: 30)."
    )

    for name, help_text in (
        ("revoke", "Cancel an account's premium."),
        ("status", "Show an account's plan and quota."),
    ):
        sub = commands.add_parser(name, help=help_text)
        sub.add_argument("email")

    listed = commands.add_parser("list", help="List the newest accounts.")
    listed.add_argument("--limit", type=int, default=20)

    args = parser.parse_args(argv)

    async def run() -> None:
        try:
            match args.command:
                case "grant":
                    await grant(args.email, args.days)
                case "revoke":
                    await revoke(args.email)
                case "status":
                    await status(args.email)
                case "list":
                    await listing(args.limit)
        finally:
            await engine.dispose()

    asyncio.run(run())


if __name__ == "__main__":
    sys.exit(main())
