# PDFree Editor

A freemium PDF editor: a Flutter app in this directory, a FastAPI backend in
[`backend/`](backend/README.md).

**Targets: web (Chrome and Safari) and Android.** The backend can serve the
built web app itself, so one address covers both the page and the API. The desktop platform folders
were removed; `flutter create --platforms=windows,linux,macos .` brings any of
them back if that changes. `ios/` is still there but untested.

Free accounts get a set number of edits per week; premium accounts are
unlimited. All PDF manipulation happens on the server — the app picks files,
uploads them, and saves what comes back.

## Running it

Start the backend first — one command, no scripts ([backend/README.md](backend/README.md)):

```bash
cd backend && docker compose up --build
```

then:

```bash
flutter run
```

The app defaults to `http://10.0.2.2:8000` on Android (the emulator's route to
your host machine) and `http://localhost:8000` everywhere else. Point it
somewhere else with:

```bash
flutter run --dart-define=API_BASE_URL=https://api.example.com
```

### "Could not reach the backend"

Almost always the backend is not running — start it first. In debug builds the
message names the exact address the app tried, so compare it against where
uvicorn is actually listening. On Android the emulator reaches your host at
`10.0.2.2`, never `localhost`.

## Tests

```bash
flutter test
```

Because web is a first-class target, the same suite also runs **in a real
browser**, which is where the platform differences actually bite:

```bash
flutter test --platform chrome --exclude-tags contract
```

Unit and widget tests run with no setup. `test/contract_test.dart` additionally
exercises a **live backend** — it registers real accounts, uploads a real PDF,
and spends a real quota, which is how the client's parsing is verified against
the server rather than against hand-written fixtures. With no backend running it
skips itself; to leave it out entirely:

```bash
flutter test --exclude-tags contract
```

## Layout

```
lib/
  main.dart              dependency wiring
  app.dart               MaterialApp + the signed-in/out gate
  core/
    config.dart          base URL and upload limits
    api/                 Dio client, typed errors, secure token storage
    ui/                  RequestState, theme
  features/
    auth/                sign in / sign up, session + quota state
    user/                status model, quota card
    editor/              the WYSIWYG editor: page canvas and object overlay
    pdf/                 tools, file picking, upload, saving
    paywall/             upgrade sheet
```

### How the pieces fit

`SessionController` owns "who is signed in and what is their quota" for the
whole app, so every screen shows the same number. `EditController` drives one
tool screen at a time and reports into one of four states —
`Idle`, `Loading`, `Success`, and either `Failure` or `QuotaExceeded`.

`QuotaExceeded` is a separate case from `Failure` on purpose: running out of
edits is the paywall trigger, not an error to retry past. Because the states are
a sealed hierarchy, a screen that forgets to handle it does not compile.

### The editor

Tap **Edit text and images** on the home screen, open a PDF, and every text run
and image on the page becomes a box over the rendered page. Editing is free
until you press Save, which costs one edit from the weekly quota no matter how
many changes it holds.

* **Tap** an object to change its words, its font size, or to delete it.
* **Drag** it to move it. The drag is tracked locally and sent once on release —
  an operation per frame would mean a server rebuild per frame, and an undo
  stack a hundred deep for one gesture.
* **Add text** / **Add image** arm a placement: the next tap on the page says
  where it goes. Placing needs a point, and the only honest way to get one is to
  let the user pick it.
* Images can be made bigger or smaller, replaced, or removed. A resize grows
  from the top-left, so it does not also shift the image.

Undo steps back one gesture at a time, and Revert clears the lot.

Changes are never applied locally: each edit goes to the server and the returned
document replaces the local model. One edit can move objects the app never
touched — an overlapping line gets redrawn, a deleted image takes its box away —
so guessing at the result would drift from the truth.

### Things worth knowing

* **Tokens** live in the platform keystore via `flutter_secure_storage`. The
  access token is refreshed *before* a request when it is close to expiring —
  a 401-then-retry cannot rescue a multipart upload, because the file stream has
  already been consumed by the time a retry would fire.
* **Connectivity** is checked before every upload. Without it the user waits out
  a full connect timeout to learn they are offline.
* **File size** is checked locally against the same cap the backend enforces, so
  an oversized file is rejected before it is uploaded rather than after.
* **Picked files** come back differently per platform: Android gives a real path
  that can be streamed from disk, a browser gives a blob with no path at all.
  `core/files/picked_file.dart` models that as two cases rather than treating a
  missing path as a failure — which is what previously made every upload fail in
  Chrome.
* **Results** default to the system save dialog on Android, so the file lands
  where the person chose and shows up in their file manager. The alternative —
  the app's own documents directory — is *private storage* on Android: nothing
  outside the app can list or open it, which reads as "the file is missing".
  Settings offers both. Cancelling the dialog still writes to the app folder
  rather than dropping a file the weekly quota has already been charged for.
  On web there is no filesystem at all, so the bytes go to the browser's
  downloads; the platforms sit behind `core/files/file_saver.dart` with a
  conditional import, which is what keeps `dart:io` out of the web build.

## Opening the web app from another device

For development on this machine, `flutter run -d chrome` is enough — no build
step. To reach it from a phone or another laptop, the app has to be built and
served from somewhere the network can see.

The simplest way is to let the backend serve it, so the page and the API share
one origin and one port:

```bash
flutter build web
```

Then start the backend as usual and open `http://<this-machine>:8000` on the
other device. The backend serves `build/web` at the site root when it exists,
and `/api/v1/...` and `/health` keep their own paths. Set `SERVE_WEB_APP=false`
in `.env` to turn that off.

Sharing an origin removes the two things that usually break this setup: there is
no cross-origin request to configure, and no second static server to remember to
start. The app also derives its backend address from the page it was served
from, so nothing has to be configured on the device either.

If you would rather keep them separate, any static server works — Python's knows
the `.wasm` MIME type Flutter needs:

```bash
cd build/web && python -m http.server 5000 --bind 0.0.0.0
```

The dev server can also be exposed directly, which keeps hot reload:

```bash
flutter run -d web-server --web-hostname any --web-port 5000
```

With either of those the page is on one port and the API on another, so the
in-app **Server** field has to point at the API.

## Testing a release APK on a real phone

Four things have to line up, and three of them fail silently.

**1. Serve on the network, not just localhost.** `localhost` on a phone means
the phone. Run the backend so the LAN can reach it:

```bash
cd backend && powershell -ExecutionPolicy Bypass -File run-server.ps1
```

It prints this machine's address and the exact build command to match.

**2. Let Windows Firewall through — only if it is on.** Check first:

```bash
netsh advfirewall show allprofiles state
```

If the profile your Wi-Fi uses says `OFF`, nothing is blocking the phone and
there is nothing to do. If it is `ON`, add a rule once, in an **administrator**
terminal, for the profile that network actually uses — a Private rule does
nothing on a network Windows has classified as Public:

```bash
powershell -Command "New-NetFirewallRule -DisplayName 'PDFree backend (dev, LAN only)' -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private,Public"
```

Remove it with
`Remove-NetFirewallRule -DisplayName 'PDFree backend (dev, LAN only)'`.

**3. Point the app at the LAN address.** The default (`10.0.2.2`) only means
anything to the emulator. Either bake it in at build time:

```bash
flutter build apk --release --dart-define=API_BASE_URL=http://192.168.1.23:8000
```

…or set it on the device: tap the PDF logo on the sign-in screen **5 times**
to open the hidden server field, or the same via **Settings** once signed
in. That override is remembered, wins over the compiled-in
default, and clearing the field goes back to it — so a laptop that changed IP
no longer means rebuilding the APK.

The APK lands in `build/app/outputs/flutter-apk/app-release.apk`. It is signed
with the debug key (see `android/app/build.gradle.kts`), which installs fine for
testing but is not publishable.

**4. Cleartext HTTP is already handled.** Android 9+ blocks plain HTTP, which
would make a release build fail to connect with no obvious cause.
`android/app/src/main/res/xml/network_security_config.xml` permits it for the
listed dev hosts only — everything else still requires HTTPS. **Add your
machine's address there when it changes.**

### When the address changes

A DHCP lease can move the laptop to a new IP. Change it in the app rather than
rebuilding: tap the PDF logo on the sign-in screen **5 times** to reveal the
hidden server field (reachable before sign-in on purpose — a wrong address is exactly what stops you signing in).

Two things follow from switching: you are signed out (tokens are issued by one
backend and mean nothing to another), and the new host still needs an entry in
`network_security_config.xml` for plain HTTP to be allowed.

Also note the server dies when the laptop sleeps.

## Letting someone off your network test it

A LAN address like `192.168.1.23` is private and not routable on the internet:
from another city it reaches nothing, and the app sits there until it times out.
Same network, or a tunnel.

A Cloudflare quick tunnel needs no account and no router configuration, and
gives an HTTPS address — which also fixes the plaintext problem, since without
it passwords would cross the internet in the clear.

```bash
winget install --id Cloudflare.cloudflared --exact
```

Start the backend, then in another window:

```bash
cd backend && powershell -ExecutionPolicy Bypass -File run-tunnel.ps1
```

It prints a `https://something.trycloudflare.com` address. The tester taps the
PDF logo on the sign-in screen **5 times** to reveal the hidden server field
and pastes it there — no rebuild, because the
address is a runtime setting. HTTPS also means the Android cleartext allowlist
does not come into it: `network_security_config.xml` only restricts plain HTTP.

**Before you share the address**, know what you are exposing:

* Anyone holding the URL can reach the backend. Registration is open and the
  auth endpoints still have no rate limiting, so treat it as a secret and stop
  the tunnel when you are done (`Ctrl+C`).
* A quick tunnel gets a **new random address every start**, which is the other
  reason the Server field exists.
* The tunnel only forwards; the backend has to be running already, and the
  laptop has to stay awake.

For anything beyond a short test with someone you know, deploy the backend
properly instead.

## Making an account premium

There is no HTTP endpoint for this, and that is deliberate: anything that can
hand out premium is a privilege escalation, so it is not exposed to the
internet. `/docs` will not show one. Use the CLI on the machine with the
database:

```bash
cd backend && .venv/Scripts/python.exe -m scripts.grant_premium grant you@example.com --days 30
```

`status`, `revoke`, and `list` are the other subcommands. The app picks the
change up on its next `GET /users/me/status` — pull to refresh on the home
screen, or sign out and back in.

## The app icon

Source art is `assets/icon/icon.svg` (and `icon_foreground.svg` for Android's
adaptive icon, scaled into the safe zone the launcher crops to). The PNGs beside
them are rendered from the SVGs; launcher assets are generated from the PNGs:

```bash
dart run flutter_launcher_icons
```

## Not built yet

* Opening or sharing a saved file — the result screen shows and copies its path.
* Moving or resizing objects in the editor: text and images can be changed,
  replaced, and removed, but not dragged.
* Matching the original typeface when text is replaced (see the backend README).
* In-app purchases. The paywall UI is real; the purchase button is honest about
  billing not being connected. Premium can only be granted server-side for now
  (`grant_manual_premium` in the backend).
* In-app PDF preview (`syncfusion_flutter_pdfviewer` was left out; it is a
  licensed dependency and nothing yet depends on it).
* Password reset and email verification.
