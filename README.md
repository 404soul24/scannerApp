# Scan d'Absences

A Flutter app that uses **Google Gemini AI** to scan absence sheets and detect absent students.

## Features

- 📸 **Camera & Gallery** — Take a photo or pick an image of your absence sheet
- 🤖 **Gemini AI Analysis** — Uses Google Gemini 2.5 Flash / 2.0 Flash with structured JSON extraction
- ✅ **Structured Data** — Extracts student names, absence counts, and calculates hours (count × 2.5h)
- 📋 **French-friendly** — UI translated in French, detects markers: `X`, `/`, `A`, `Abs`, `☑`
- 🔢 **Auto-calculated** — Gemini counts all absence marks and computes total hours server-side
- 📤 **Share results** — Export the absent list via any app
- 📜 **Scan history** — Last 20 scans saved locally
- ✏️ **Manual edit** — Toggle absence slots per student per day
- 🔑 **In-app API key** — Configure your Gemini API key directly in the app settings
- 🔄 **Auto-retry** — Retries on server overload (3× backoff) with fallback to `gemini-2.0-flash`
- 🌙 **Dark theme** — Modern Material 3 design with dark background

## Tech Stack

- **Framework:** Flutter (Dart)
- **AI:** Google Gemini 2.5 Flash / 2.0 Flash (`google_generative_ai`) with `temperature: 0.0`
- **Response Format:** Strict JSON schema (`responseSchema`) enforced via `GenerationConfig`
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

## Security

> **⚠️ The Gemini API key is stored locally on the device and can be extracted via APK decompilation.**
> Before production release, move the API call to a backend proxy/cloud function.
> See: [Securing API keys](https://cloud.google.com/docs/authentication/api-keys#securing)

## Permissions

The app requires these Android permissions:
- `CAMERA` — taking photos of absence sheets
- `INTERNET` — making API calls to Gemini
