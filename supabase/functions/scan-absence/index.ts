// Supabase Edge Function: scan-absence
// Acts as a secure proxy to Google Gemini 2.5 Flash API.
// The Gemini API key is stored as a server-side secret, not exposed to clients.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");
if (!GEMINI_API_KEY) {
  throw new Error("GEMINI_API_KEY environment variable is not set");
}

const GEMINI_URL =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent";

const SYSTEM_INSTRUCTION =
  "Tu es un assistant spécialisé dans l'extraction de données de " +
  "feuilles d'absences scolaires. Tu dois analyser l'image fournie " +
  "et retourner UNIQUEMENT un objet JSON valide, sans aucun texte " +
  "avant ou après. Ne mets pas de blocs markdown (```json).";

const USER_PROMPT =
  "Analyse cette feuille d'absences hebdomadaire et extraits les informations suivantes.\n" +
  "\n" +
  "La feuille contient une liste d'élèves avec des cases à cocher pour chaque jour " +
  "(LUN, MAR, MER, JEU, VEN, SAM). Chaque jour a 4 créneaux.\n" +
  "\n" +
  "Marques d'absence à rechercher : \"X\", \"/\", \"A\", \"Abs\", \"☑\" ou toute case cochée.\n" +
  "Ignore les cases vides ou les marques \"P\", \"V\" qui signifient présent.\n" +
  "\n" +
  "Extrais TOUS les élèves de la feuille, même ceux qui n'ont aucune absence.\n" +
  "Pour chaque élève :\n" +
  "1. is_absent = true si au moins une marque d'absence est trouvée.\n" +
  "2. is_absent = false si aucune marque (cases vides ou marques de présence).\n" +
  "3. absence_count = nombre total de marques d'absence (0 si présent).\n" +
  "4. total_hours_absent = absence_count × 2.5 (0.0 si présent).\n" +
  "\n" +
  "Retourne UNIQUEMENT un objet JSON valide. Pas de blocs markdown.";

const RESPONSE_SCHEMA = {
  type: "object",
  properties: {
    scanned_date: {
      type: "string",
      description: "La date inscrite sur la feuille si visible, sinon 'unknown'",
    },
    total_students_count: {
      type: "integer",
      description: "Nombre total d'élèves sur la feuille",
    },
    students: {
      type: "array",
      description: "Liste complète de tous les élèves",
      items: {
        type: "object",
        properties: {
          student_name: {
            type: "string",
            description: 'Prénom et Nom, format "Firstname LASTNAME"',
          },
          is_absent: {
            type: "boolean",
            description:
              "true si au moins une marque d'absence est trouvée, false si présent",
          },
          absence_count: {
            type: "integer",
            description: "Nombre total de marques d'absence (0 si présent)",
          },
          total_hours_absent: {
            type: "number",
            description: "Calculé comme absence_count × 2.5 (0.0 si présent)",
          },
        },
        required: ["student_name", "is_absent", "absence_count", "total_hours_absent"],
      },
    },
  },
  required: ["scanned_date", "total_students_count", "students"],
};

async function callGemini(base64Image: string): Promise<string> {
  const body = {
    system_instruction: {
      parts: [{ text: SYSTEM_INSTRUCTION }],
    },
    contents: [
      {
        parts: [
          { text: USER_PROMPT },
          {
            inline_data: {
              mime_type: "image/jpeg",
              data: base64Image,
            },
          },
        ],
      },
    ],
    generation_config: {
      temperature: 0.0,
      response_mime_type: "application/json",
      response_schema: RESPONSE_SCHEMA,
    },
  };

  const response = await fetch(`${GEMINI_URL}?key=${GEMINI_API_KEY}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Gemini API error (${response.status}): ${errorText}`);
  }

  const data = await response.json();

  // Extract the text from Gemini's response structure
  const text = data?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) {
    throw new Error("Gemini returned empty response");
  }

  // Validate it's parseable JSON
  JSON.parse(text);
  return text;
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const { base64Image } = await req.json();

    if (!base64Image || typeof base64Image !== "string") {
      return new Response(
        JSON.stringify({ error: "Missing or invalid base64Image field" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    const result = await callGemini(base64Image);

    return new Response(result, {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (error) {
    console.error("Error:", error.message);

    const status = error.message.includes("503") ||
        error.message.includes("high demand")
      ? 503
      : 500;

    return new Response(
      JSON.stringify({
        error: error.message || "Internal server error",
      }),
      {
        status,
        headers: { "Content-Type": "application/json" },
      }
    );
  }
});
