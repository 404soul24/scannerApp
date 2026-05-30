# Scan d'Absences

Flutter app using **Google Gemini 2.5 Flash** via a **Supabase Edge Function** to scan absence sheets and detect absent students.

## Features

- Camera & Gallery — Take a photo or pick an image of your absence sheet
- Gemini AI via Edge Function — Images sent to Supabase Edge Function which proxies to Gemini 2.5 Flash
- Structured Data — Extracts student names, absence counts, and calculates hours (count x 2.5h)
- French-friendly — UI in French, detects markers: `X`, `/`, `A`, `Abs`
- Full Roster — Extracts ALL students with `is_absent` status
- Manual Edit — Toggle absence slots per student per day in verification screen
- Export CSV (simple/detailed) & PDF — Share absence reports
- Share results — Export the absent list via any app
- Scan History — Last 50 scans persisted in Supabase
- Multi-tenant — School-level data isolation via Row Level Security
- Secure — Gemini API key lives server-side only
- Dark theme — Material 3 design with dark background

## Tech Stack

- **Frontend:** Flutter (Dart) with Material 3
- **Backend:** Supabase (Auth, PostgreSQL with RLS, Edge Function)
- **AI:** Google Gemini 2.5 Flash (temperature: 0.0, strict JSON schema)
- **Communication:** HTTP POST with base64-encoded image + mime type
- **Storage:** Supabase PostgreSQL (`absences_log`, `student_absences`)

## Setup

### Prerequisites

- Flutter SDK
- Supabase CLI (or Supabase Dashboard)
- Gemini API key from [Google AI Studio](https://makersuite.google.com/app/apikey)

### 1. Apply the Database Migration

Run the migration in `supabase/migrations/20260530000000_create_multi_tenant_schema.sql` via the Supabase Dashboard SQL Editor or the CLI:

```bash
supabase migration up
```

### 2. Deploy the Supabase Edge Function

**Option A — Supabase Dashboard:**
1. Go to [Supabase Dashboard](https://supabase.com/dashboard/project/xpsuryegelcfwjwpmxud)
2. Navigate to **Edge Functions** -> Create a new function
3. Name it `scan-absence`
4. Paste the content from `supabase/functions/scan-absence/index.ts`
5. Click **Save**
6. Go to **Project Settings** -> **Environment Variables**
7. Add `GEMINI_API_KEY` with your Gemini API key value

**Option B — Supabase CLI:**
```bash
supabase secrets set GEMINI_API_KEY=your_gemini_api_key_here
supabase functions deploy scan-absence
```

### 3. Build & Run the App

```bash
flutter pub get
flutter run
```

## Build APK

```bash
flutter build apk --release
```

> Note: Internet connection is required. Images are sent to the Edge Function for processing.
> Windows Developer Mode may be needed for Flutter plugin symlink support (`start ms-settings:developers`).

## Architecture

```
Flutter App  -- HTTP POST (base64 image + mimeType) --> Supabase Edge Function (Deno)
  (no API key)                                          |-- JWT verification
                                                        |-- Rate limiting
                                                        |-- Proxy to Gemini
                                                        |-- Returns JSON roster
Flutter App <-- JSON roster ------------------------- Supabase Edge Function
                                                        |
                                                        v
                                                  Gemini 2.5 Flash API
                                                  (server-side only)
```

## Security

The Gemini API key is stored as a Supabase environment variable -- never in the APK.
The client sends only the image. The Edge Function holds the key and calls Gemini server-side.
All database access is protected by Row Level Security policies based on school_id.

## Permissions

The app requires these Android permissions:
- `CAMERA` — taking photos of absence sheets
- `INTERNET` — making API calls to the Edge Function
