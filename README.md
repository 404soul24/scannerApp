# Scan d'Absences

A Flutter app that uses **Google Gemini AI** to scan absence sheets and detect absent students.

## Features

- 📸 **Camera & Gallery** — Take a photo or pick an image of your absence sheet
- 🤖 **Gemini AI Analysis** — Uses Google Gemini 2.5 Flash / 2.0 Flash to extract student names and absence marks
- ✅ **Smart Detection** — Detects absence markers: `X`, `/`, `A`, `☑`, and more
- 📋 **French-friendly** — UI translated in French, supports French absence sheet formats (checkboxes, tables, lists)
- 📤 **Share results** — Export the absent list via any app
- 📜 **Scan history** — Last 20 scans saved locally
- ✏️ **Manual edit** — Toggle absence slots per student per day
- 🔑 **In-app API key** — Configure your Gemini API key directly in the app settings
- 🔄 **Auto-retry** — Automatically retries on server overload with fallback to a different model
- 🌙 **Dark theme** — Modern Material 3 design with dark background

## Tech Stack

- **Framework:** Flutter (Dart)
- **AI:** Google Gemini 2.5 Flash / 2.0 Flash (`google_generative_ai`)
- **Storage:** `shared_preferences` for local history and API key
- **Image:** `image_picker` for camera/gallery

## Setup

1. Install dependencies:
   ```bash
   flutter pub get
   ```

2. Get a Gemini API key from [Google AI Studio](https://makersuite.google.com/app/apikey)

3. Run the app:
   ```bash
   flutter run
   ```

4. On first launch, tap the **settings gear** (or the orange key icon) and enter your API key.

## Build APK

```bash
flutter build apk --release
```

> **Note 1:** Internet connection is required during scanning — Gemini processes images in the cloud.
>
> **Note 2:** Windows Developer Mode must be enabled for Flutter plugin symlink support (`start ms-settings:developers`).

## Permissions

The app requires these Android permissions:
- `CAMERA` — taking photos of absence sheets
- `INTERNET` — making API calls to Gemini
