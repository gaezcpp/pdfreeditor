from __future__ import annotations

import time
from collections import defaultdict, deque

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

from app.core.config import settings


class InMemoryRateLimitMiddleware(BaseHTTPMiddleware):
    """Small single-process guard; use a shared gateway for multi-worker deploys."""

    def __init__(self, app):
        super().__init__(app)
        self._requests: dict[str, deque[float]] = defaultdict(deque)

    async def dispatch(self, request: Request, call_next):
        key = request.client.host if request.client else "unknown"
        now = time.monotonic()
        bucket = self._requests[key]
        cutoff = now - settings.rate_limit_window_seconds
        while bucket and bucket[0] <= cutoff:
            bucket.popleft()
        if len(bucket) >= settings.rate_limit_requests:
            return JSONResponse(
                {"error": {"code": "rate_limited", "message": "Too many requests."}},
                status_code=429,
                headers={"Retry-After": str(settings.rate_limit_window_seconds)},
            )
        bucket.append(now)
        return await call_next(request)
