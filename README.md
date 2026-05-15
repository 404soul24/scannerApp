# Scan d'Absences

A Flutter app that uses **Google Gemini 2.5 Flash** via a **Supabase Edge Function** to scan absence sheets and detect absent students.

## Features

- 📸 **Camera & Gallery** — Take a photo or pick an image of your absence sheet
- 🤖 **Gemini AI via Edge Function** — Images sent to Supabase Edge Function which proxies to Gemini 2.5 Flash
- ✅ **Structured Data** — Extracts student names, absence counts, and calculates hours (count × 2.5h)
- 📋 **French-friendly** — UI translated in French, detects markers: `X`, `/`, `A`, `Abs`, `☑`
- 🔢 **Full Roster** — Extracts ALL students with `is_absent` status for better accuracy
- 📤 **Share results** — Export the absent list via any app
- 📜 **Scan history** — Last 20 scans saved locally
- ✏️ **Manual edit** — Toggle absence slots per student per day
- 🔄 **Auto-retry** — Retry button on any error
- 🔒 **Secure** — Gemini API key lives server-side only
- 🌙 **Dark theme** — Modern Material 3 design with dark background

## Tech Stack

- **Frontend:** Flutter (Dart)
- **Backend:** Supabase Edge Function (Deno/TypeScript) proxying to Gemini
- **AI:** Google Gemini 2.5 Flash (`temperature: 0.0`, strict JSON schema)
- **Communication:** HTTP POST with base64-encoded image
- **Storage:** `shared_preferences` for local history

## Setup

### Prerequisites

- Flutter SDK
- Supabase CLI (or use Supabase Dashboard)
- Gemini API key from [Google AI Studio](https://makersuite.google.com/app/apikey)

### 1. Deploy the Supabase Edge Function

**Option A — Supabase Dashboard (easier):**
1. Go to [Supabase Dashboard](https://supabase.com/dashboard/project/xpsuryegelcfwjwpmxud)
2. Navigate to **Edge Functions** → **Create a new function**
3. Name it `scan-absence`
4. Paste the content from `supabase/functions/scan-absence/index.ts`
5. Click **Save**
6. Go to **Project Settings** → **Environment Variables**
7. Add `GEMINI_API_KEY` with your Gemini API key value

**Option B — Supabase CLI:**
```bash
# Set the Gemini API key
supabase secrets set GEMINI_API_KEY=your_gemini_api_key_here

# Deploy the function
supabase functions deploy scan-absence
```

### 2. Build & Run the App

```bash
flutter pub get
flutter run
```

## Build APK

```bash
flutter build apk --release
```

> **Note:** Internet connection is required. Images are sent to the Edge Function for processing.
> Windows Developer Mode may be needed for Flutter plugin symlink support (`start ms-settings:developers`).

## Architecture

```
┌─────────────┐     base64 image      ┌──────────────────┐     Gemini API key     ┌─────────────┐
│ Flutter App │ ──── HTTP POST ──────→ │ Supabase Edge    │ ──── (server-side) ──→ │ Gemini 2.5  │
│ (no API key)│ ←─── JSON roster ──── │ Function (Deno)  │ ←──── JSON response ── │ Flash       │
└─────────────┘                       └──────────────────┘                       └─────────────┘
```

## Security

> ✅ **The Gemini API key is stored as a Supabase environment variable — never in the APK.**
> The client sends only the image. The Edge Function holds the key and calls Gemini server-side.

## Permissions

The app requires these Android permissions:
- `CAMERA` — taking photos of absence sheets
- `INTERNET` — making API calls to the Edge Function
