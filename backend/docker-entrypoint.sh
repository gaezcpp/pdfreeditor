#!/bin/sh
# Runs migrations, then starts the API. Failing fast on a bad SECRET_KEY in
# production is handled by the app itself (get_settings raises).
set -e

echo "Applying database migrations..."
python -m alembic upgrade head

echo "Starting PDFree backend..."
exec python -m uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8000}"
