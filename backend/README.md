# PDFree Editor — Backend

FastAPI + PostgreSQL service behind the Flutter app. Handles authentication,
the weekly edit quota, premium entitlement, and all PDF manipulation.

## Requirements

**Python 3.11 or 3.12.** Python 3.13+ has no prebuilt wheels for `asyncpg` and
`pydantic-core` at the pinned versions and will try (and fail) to compile them.

**No database server is needed for local development.** SQLite runs the whole
app — migrations, tests, and a live server. PostgreSQL 14+ is the production
target; the schema and migrations are identical either way.

## Setup

```bash
py -3.11 -m venv .venv
```

```bash
.venv/Scripts/python.exe -m pip install -r requirements-dev.txt
```

(The dev requirements include `aiosqlite`, which the SQLite path needs.)

Copy `.env.example` to `.env`, then generate a real `SECRET_KEY`:

```bash
.venv/Scripts/python.exe -c "import secrets; print(secrets.token_urlsafe(64))"
```

Paste the result into `.env`, never back into this file — `README.md` is
committed, `.env` is not.

Apply the schema:

```bash
.venv/Scripts/python.exe -m alembic upgrade head
```

Run it:

```bash
.venv/Scripts/python.exe -m uvicorn app.main:app --reload --port 8000
```

Interactive docs at `http://localhost:8000/docs` (disabled when
`ENVIRONMENT=production`).

## Tests

```bash
.venv/Scripts/python.exe -m pytest
```

The suite runs on SQLite — no database server needed.

```bash
.venv/Scripts/python.exe -m ruff check .
```

## API

All paths are prefixed with `/api/v1`. Every endpoint except the auth ones
requires `Authorization: Bearer <access_token>`.

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/auth/register` | Create an account, returns a token pair |
| POST | `/auth/login` | Sign in, returns a token pair |
| POST | `/auth/refresh` | Rotate the refresh token |
| POST | `/auth/logout` | Revoke one device's refresh token |
| GET | `/auth/me` | The current user |
| GET | `/users/me/status` | Plan, premium expiry, and quota — what the paywall reads |
| POST | `/pdf/compress` | `file`, optional `image_quality` (1-100) |
| POST | `/pdf/merge` | `files` (2 or more, in order) |
| POST | `/pdf/split` | `file`, `page_ranges` e.g. `"1-3,7"` |
| POST | `/pdf/add-text` | `file`, `text`, `page`, `x`, `y`, optional `font_size`, `color` |
| POST | `/editor/sessions` | Open a document for editing; returns its objects |
| GET | `/editor/sessions/{id}` | The document's current objects |
| GET | `/editor/sessions/{id}/pages/{n}` | The page as a PNG (`dpi`, 48-200) |
| POST | `/editor/sessions/{id}/text` | Change one text run (`page`, `span`, `text`) |
| POST | `/editor/sessions/{id}/text/move` | Drag a run (`dx`, `dy` in points) |
| POST | `/editor/sessions/{id}/text/style` | Change a run's `size` or `color` |
| POST | `/editor/sessions/{id}/text/add` | Place new text |
| POST | `/editor/sessions/{id}/images/delete` | Remove an image |
| POST | `/editor/sessions/{id}/images/move` | Drag an image |
| POST | `/editor/sessions/{id}/images/scale` | Resize about its top-left |
| POST | `/editor/sessions/{id}/images/add` | Place a new image (file, `x`, `y`) |
| POST | `/editor/sessions/{id}/images/replace` | Swap an image (`page`, `index`, file) |
| POST | `/editor/sessions/{id}/undo` \| `/reset` | Drop the last edit, or all of them |
| POST | `/editor/sessions/{id}/save` | Charge one edit, download, close the session |
| DELETE | `/editor/sessions/{id}` | Discard without saving |

PDF endpoints return the file itself (`application/pdf`, or `application/zip`
when a split produces several parts), with `Content-Disposition` carrying the
filename and `X-Quota-Remaining` the edits left this week (absent for premium).

### Errors

Every error shares one shape, so the app can branch on `code` rather than on
status text:

```json
{ "error": { "code": "quota_exceeded", "message": "...", "details": { "resets_at": "..." } } }
```

Codes the client must handle: `unauthenticated` (401, refresh or sign in),
`quota_exceeded` (403, show the paywall — `details.resets_at` says when the
window rolls over), `file_too_large` (413), `invalid_pdf` / `validation_error` /
`pdf_processing_failed` (422), `conflict` (409, email already registered).

## How the quota works

Free users get `FREE_WEEKLY_EDIT_QUOTA` edits per week. The window is **Monday
00:00 UTC**, derived from the clock rather than reset by a scheduled job: a
counter left over from an earlier week reads as zero and is rewritten on the
first charge of the new week. There is no cron to fall behind and no midnight
stampede.

Each edit is charged by a single conditional `UPDATE ... RETURNING`, so two
uploads racing for the last remaining edit cannot both win. The charge happens
**before** processing and is refunded if processing fails — a user is never
billed for a file the server could not produce. `usage_logs` records every
attempt, charged or not.

Premium users skip the charge entirely. Their entitlement is read from
`users.plan` / `users.premium_until`, a cache of the `subscriptions` table that
only `services/subscription.py` may write.

> This differs from SOP 1 in `claude_code_agents.md`, which decrements after
> processing. Charging first is what makes the check race-free; the refund path
> preserves the intent (no charge for a failed edit).

## How the editor works

The whole-file tools transform a document. The editor changes what is *on* a
page: it lists the individual text runs and images, and rewrites them one at a
time.

A session holds the upload server-side under `var/sessions/<id>/`, because a
WYSIWYG editor is inherently multi-request — read the page, render it, change a
word, render again. **This is a deliberate exception to the "delete the upload
when the request ends" rule.** The mitigations are a hard TTL
(`SESSION_TTL_MINUTES`), an ownership check on every call, deletion on save or
discard, and a sweep of expired sessions at startup.

Edits are stored as an operation log and replayed onto the pristine original on
every change, never applied on top of an already-edited file. That makes undo a
pop and stops redaction artifacts compounding.

The state the client sees is **projected** from the original plus that log —
never parsed back out of the rendered PDF. This matters more than it sounds:
objects are addressed by index, and re-reading them from an edited file
renumbers everything after a deletion, so the next edit silently lands on the
wrong object. Objects the user adds get a server-assigned id stored in their
operation, so they keep the same handle through every replay.

Moves are recorded as deltas rather than destinations, because a delta replays
correctly on top of earlier moves while an absolute position captured against a
stale layout would snap the object back.

Opening and previewing are free; **the quota is charged once, on save** — one
saved document is one edit, however many tweaks it took.

### Two things that constrain what editing can do

**Replacing text means erasing and redrawing it.** A PDF has no editable text
model; a "word" is a positioned run of glyph codes. Changing one means redacting
the old run and drawing a new one at the same baseline.

Redaction is *regional*, not object-aware: it deletes whatever sits inside a
rectangle. On a real label the boxes overlap, so erasing one run clips its
neighbours — and deleting an image erases the text printed across it. So every
run the erase touches is found first (to a fixed point, since erasing a
neighbour can reach a third run), all erasing happens in one pass, and only then
is the surviving text redrawn.

**The original font usually cannot be reused.** Real PDFs embed font *subsets*:
only the glyphs already used, addressed by glyph id with the unicode map
stripped. Typing a character the subset lacks would render nothing. Replacement
text is therefore drawn in a base-14 substitute matched to the original's weight
and slant, at the original size, colour, and baseline. Layout is preserved
exactly; the typeface is an approximation, and the API reports the substitute in
`substitute_font` so the client can say so before the user commits.

## Layout

```
app/
  api/v1/      HTTP layer — routing, form parsing, nothing else
  core/        config, security, errors, time helpers
  db/          engine, session, declarative base
  models/      SQLAlchemy tables
  schemas/     Pydantic request/response contracts
  services/    business logic — quota, auth, subscriptions, PDF ops
alembic/       migrations
tests/         pytest suite (SQLite-backed)
```

`services/edit_pipeline.py` owns the order of operations every PDF endpoint
follows (charge → process → log → stream → delete temp files), so an endpoint
cannot get it wrong. `services/pdf/document.py` does object-level editing and
`services/editor.py` manages the sessions around it.

## Serving the web app

When `build/web` exists (from `flutter build web` in the project root), it is
served at the site root. The API and `/health` are registered first and keep
their paths; only what is left falls through to static files.

That gives the page and the API one origin, which is what makes opening the app
on a phone work without CORS or a second static server. Set `SERVE_WEB_APP=false`
to run API-only, or point `WEB_APP_DIR` somewhere else.

## Reaching it from outside the network

`run-tunnel.ps1` opens a Cloudflare quick tunnel (`winget install --id
Cloudflare.cloudflared --exact`) and prints a public HTTPS address that forwards
to this server. See the root README for what that exposes — open registration
and unthrottled auth endpoints, on an address anyone holding it can reach.

## Granting premium

Billing is not wired up, so premium is granted from the server:

```bash
.venv/Scripts/python.exe -m scripts.grant_premium grant you@example.com --days 30
```

Also `status`, `revoke`, and `list`. This is a CLI rather than an endpoint on
purpose — an HTTP route that hands out premium is a privilege escalation, and
there is no reason to expose one just for convenience. When store receipts land,
that flow calls the same `services/subscription.py` code and this stays as the
support tool.

## Not built yet

* Store receipt verification (Google Play / App Store). `subscriptions` and
  `services/subscription.py` are ready for it; `grant_manual_premium` is the
  seam.
* Rate limiting per IP/user on the auth endpoints.
* Email verification and password reset.
