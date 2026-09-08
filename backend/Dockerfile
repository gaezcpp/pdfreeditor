# Python 3.11 or 3.12 only. 3.13+ has no prebuilt wheels for asyncpg and
# pydantic-core at the pinned versions (see backend/README.md).
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install dependencies first for better layer caching.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY alembic.ini ./
COPY alembic ./alembic
COPY app ./app
COPY scripts ./scripts
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Writable at runtime: uploads, editor sessions, SQLite fallback file.
VOLUME ["/app/var"]

EXPOSE 8000

ENTRYPOINT ["./docker-entrypoint.sh"]
