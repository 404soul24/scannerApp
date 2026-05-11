# Scan d'Absences

A Flutter app that uses **Google ML Kit** on-device OCR to scan absence sheets and detect absent students.

## Features

- 📸 **Camera & Gallery** — Take a photo or pick an image of your absence sheet
- 🔍 **On-device OCR** — Google ML Kit text recognition (no internet needed after first model download)
- ✅ **Smart Detection** — Detects absence markers: `ABSENT`, `ABSENTE`, `X`, `☑`, and more
- 📋 **French-friendly** — UI translated in French, supports French absence sheet formats (checkboxes, tables, lists)
- 📤 **Share results** — Export the absent list via any app
- 📜 **Scan history** — Last 20 scans saved locally
- ✏️ **Manual edit** — Add or remove names manually
- 🌙 **Dark theme** — Modern Material 3 design with dark background

## Tech Stack

- **Framework:** Flutter (Dart)
- **OCR:** Google ML Kit Text Recognition (`google_mlkit_text_recognition`)
- **Storage:** `shared_preferences` for local history
- **Image:** `image_picker` for camera/gallery

## Getting Started

```bash
flutter pub get
dart run flutter_launcher_icons
flutter run
```

## Build APK

```bash
flutter build apk --release
```
