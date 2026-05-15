# Scan d'Absences

A Flutter app that uses **Google Gemini AI** to scan absence sheets and detect absent students.

## Features

- 📸 **Camera & Gallery** — Take a photo or pick an image of your absence sheet
- 🤖 **Gemini AI Analysis** — Uses Google Gemini 2.5 Flash to extract student names and absence marks
- ✅ **Smart Detection** — Detects absence markers: `X`, `/`, `A`, `☑`, and more
- 📋 **French-friendly** — UI translated in French, supports French absence sheet formats (checkboxes, tables, lists)
- 📤 **Share results** — Export the absent list via any app
- 📜 **Scan history** — Last 20 scans saved locally
- ✏️ **Manual edit** — Toggle absence slots per student per day
- 🌙 **Dark theme** — Modern Material 3 design with dark background

## Tech Stack

- **Framework:** Flutter (Dart)
- **AI:** Google Gemini 2.5 Flash (`google_generative_ai`)
- **Storage:** `shared_preferences` for local history
- **Image:** `image_picker` for camera/gallery

## Setup

1. Create a `.env` file in the project root:
   ```
   GEMINI_API_KEY=your_gemini_api_key_here
   ```

2. Get your API key from [Google AI Studio](https://makersuite.google.com/app/apikey)

3. Install dependencies and run:
   ```bash
   flutter pub get
   flutter run
   ```

## Build APK

```bash
flutter build apk --release
```

> **Note:** Internet connection is required during scanning — Gemini processes images in the cloud.
