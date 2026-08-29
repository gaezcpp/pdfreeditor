"""Domain enums.

Stored as short strings rather than native DB enums: adding a value later is a
plain insert instead of a migration that rewrites a type under a lock.
"""

from __future__ import annotations

from enum import StrEnum


class Plan(StrEnum):
    FREE = "free"
    PREMIUM = "premium"


class SubscriptionStatus(StrEnum):
    ACTIVE = "active"
    CANCELED = "canceled"
    EXPIRED = "expired"
    IN_GRACE = "in_grace"


class BillingProvider(StrEnum):
    GOOGLE_PLAY = "google_play"
    APP_STORE = "app_store"
    MANUAL = "manual"


class PdfAction(StrEnum):
    COMPRESS = "compress"
    MERGE = "merge"
    SPLIT = "split"
    ADD_TEXT = "add_text"
    EDIT = "edit"  # a saved WYSIWYG editing session, however many tweaks it held


class UsageStatus(StrEnum):
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    REJECTED = "rejected"
