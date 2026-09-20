# Fufut POS (Flutter)

Native point-of-sale client for Fufut Coffee — the same till the web POS runs,
rebuilt for Android tablets and desktops, talking to the same **fufut-api**
Worker (same menu, same floor plan, same tickets, same session model).

## What it does

| Screen | Flow |
|---|---|
| **Login** | Staff ID *or* email + password → 30-day session (the API's own cookie contract, carried natively). Server URL editable on-device. |
| **Register** | Category chips + search + product grid (sold-out items dimmed). Tap to add; modifier options get a picker. |
| **Cart** | Lines with qty steppers, dine-in / takeaway / delivery, table picker (claims the table exactly like the web till), guest + phone + delivery fee, kitchen notes. |
| **Send to Kitchen** | Creates the order `status=new, payment=unpaid` — kitchen sees it before any money moves. Dine-in claims the table first, same order of operations as the web POS. |
| **Charge** | Payment sheet: cash (tender + quick amounts + change due), card, mobile, Telebirr, CBE Birr, bank → one POST with a `paymentBreakdown`. |
| **Orders** | Open checks (`?open=1`) and the recent list. Advance status (new → preparing → ready → served), settle unpaid tabs with a PUT, see line-level detail. |
| **Settings** | Who is signed in, API server URL, sign out. |

Everything is delivered by the same `session` cookie the web POS uses, a
browser-shaped `User-Agent` (Cloudflare Bot Fight Mode answers non-browser
clients with error 1010 before the request reaches the Worker), and the same
refusal-not-retry rules: reads retry on transient errors, writes fail fast.

## Builds (GitHub Actions)

`.github/workflows/build.yml` builds on every push to `main`:

1. **Analyze** — `flutter analyze --fatal-infos` gates everything else.
2. **Android** — `app-release.apk` (debug-signed until a keystore is added —
   installs fine for floor testing) plus split-ABI APKs.
3. **Linux** — x64 bundle tarball.
4. **Windows** — x64 zip.
5. **macOS** — optional, behind the `build_macos` workflow_dispatch input
   (macOS runners bill 10x minutes on private repos).
6. **Releases** — publishing a `v*` release attaches every artifact to the
   release page automatically.

Grab the artifacts from the run page → *Artifacts*, or from the release page.

## Local development

```bash
flutter pub get
flutter analyze
flutter run                      # picks a connected device/emulator
flutter build apk --release      # needs the Android SDK
```

## Server

The app ships pointing at `https://fufut-api.fufutcoffee.workers.dev`.
Change it from the login screen (Server) or Settings if the deployment moves.

## Roadmap (not in v1)

* Offline mutation queue (the web POS queues writes in IndexedDB; the app
  currently fails fast when unreachable and keeps the cart on disk)
* Split bills, tips and discounts on the payment sheet
* Cash drawer / shift screens
* Release keystore + Play Store signing
