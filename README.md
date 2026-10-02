# Debloat

A Flutter Android app for removing pre‑installed system apps (bloatware) **directly from the phone** — no computer required. It drives **wireless ADB** (ADB over Wi‑Fi) through a native Kotlin bridge to list system packages and uninstall them for the current user.

> ⚠️ Removing system apps can affect device stability. Uninstall only packages you recognize and understand. Use at your own risk.

## Features

- **On‑device wireless ADB** — pair and connect over your local network using Android's *Wireless debugging*; no PC or USB cable needed.
- **One‑time pairing** — remembers that the device has been paired and shows a compact *Connect* flow on return; a connection port can be auto‑discovered via mDNS.
- **Floating pairing helper** — an overlay window that floats over the Settings screen so you can read the pairing port/code and connect in one go.
- **System app browser** — lists installed system apps with a live search/filter.
- **One‑tap uninstall** — removes a package for the current user, with animated list add/remove and clear success/failure feedback.
- **Material 3 UI** — adaptive light/dark theme.

## How it works

The Dart UI (`lib/main.dart`) talks to native Android code over platform channels:

- **MethodChannel** `com.example.debloat/adb` — `pair`, `connect`, `connectAuto`, `isPaired`, overlay permission + floating window controls, `getSystemApps`, `uninstallApp`, `disconnect`.
- **EventChannel** `com.example.debloat/adb_events` — pushes events (e.g. `connected`) from the floating window back to the UI.

Native Kotlin components (`android/app/src/main/kotlin/com/example/debloat/`) include the ADB connection manager, a self‑signed certificate helper for the ADB TLS handshake, and the floating window controller.

## Getting started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `^3.11.3`)
- An Android device with **Developer options** enabled

### Run

```bash
flutter pub get
flutter run
```

### Using the app

1. On your Android device, enable **Developer options → Wireless debugging**.
2. Open **Wireless debugging → Pair device with pairing code** to get a **pairing port** and **pairing code**.
3. In Debloat, enter the pairing port and code (or use **Float over Settings to pair** to read them from the overlay), then tap **Pair & Connect**. Leave the connection port blank to auto‑detect it.
4. Once connected, browse the system apps, filter with search, and tap **Uninstall** on anything you want to remove.

## Project structure

```
lib/main.dart      # Flutter UI + AdbService platform-channel bridge
android/           # Native Kotlin: ADB manager, TLS cert, floating window
test/              # Widget tests
```

## Disclaimer

This tool uninstalls packages for the current user via ADB. It does not root your device, but removing the wrong system package can cause instability or require a factory reset. Review each app before removing it.
