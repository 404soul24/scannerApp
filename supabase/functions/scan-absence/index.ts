// Supabase Edge Function: scan-absence
// Acts as a secure proxy to Google Gemini 2.5 Flash API.
// The Gemini API key is stored as a server-side secret, not exposed to clients.

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");
if (!GEMINI_API_KEY) {
  throw new Error("GEMINI_API_KEY environment variable is not set");
}

const GEMINI_URL =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent";

// --- Rate limiter ---
// In-memory: at most RATE_LIMIT requests per minute per IP
const RATE_LIMIT = 10;
const RATE_WINDOW_MS = 60_000;
const requestLog = new Map<string, number[]>();

function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const timestamps = requestLog.get(ip) ?? [];
  const recent = timestamps.filter((t) => now - t < RATE_WINDOW_MS);
  if (recent.length >= RATE_LIMIT) return true;
  recent.push(now);
  requestLog.set(ip, recent);
  return false;
}

// --- Generic user-facing errors (never leak internals) ---
const USER_ERRORS: Record<number, string> = {
  400: "Requête invalide. Vérifiez l'image envoyée.",
  429: "Trop de requêtes. Veuillez réessayer dans une minute.",
  500: "Service temporairement indisponible. Veuillez réessayer.",
  503: "Service saturé. Veuillez réessayer plus tard.",
};

function userFacingError(status: number, fallback?: string): string {
  return USER_ERRORS[status] ?? fallback ?? "Erreur interne. Veuillez réessayer.";
}

const SYSTEM_INSTRUCTION =
  "Tu es un assistant spécialisé dans l'extraction de données de " +
  "feuilles d'absences scolaires. Tu dois analyser l'image fournie " +
  "et retourner UNIQUEMENT un objet JSON valide, sans aucun texte " +
  "avant ou après. Ne mets pas de blocs markdown (```json). " +
  "La précision géométrique est critique : chaque case d'absence " +
  "doit être alignée à la bonne colonne de jour et à la bonne ligne d'élève. " +
  "Avant toute lecture, identifie la grille complète du tableau " +
  "(en-têtes de colonnes en haut, liste verticale des élèves). " +
  "Ancre-toi aux en-têtes de jour (LUN, MAR, MER, JEU, VEN, SAM) " +
  "et ne dévie JAMAIS de cette grille. Chaque ligne d'élève est " +
  "strictement indépendante — ne propage jamais une marque vers " +
  "le haut ou le bas.";

const USER_PROMPT =
  "Analyse cette feuille d'absences hebdomadaire et extraits les informations suivantes.\n" +
  "\n" +
  "--- RÈGLES GÉOMÉTRIQUES STRICTES ---\n" +
  "\n" +
  "1. ANCRAGE AUX EN-TÊTES : Repère d'abord la ligne des en-têtes de colonnes " +
  "(LUN, MAR, MER, JEU, VEN, SAM) en haut du tableau. Utilise ces en-têtes " +
  "comme ancrage horizontal fixe pour TOUTE l'extraction.\n" +
  "\n" +
  "2. LECTURE LIGNE PAR LIGNE : Parcours les élèves un par un, de haut en bas. " +
  "Pour CHAQUE élève, lis horizontalement de gauche à droite sur SA ligne " +
  "uniquement. Ne dérive PAS verticalement vers la ligne du dessus ou du dessous " +
  "— chaque ligne est indépendante.\n" +
  "\n" +
  "3. ALIGNEMENT COLONNE-JOUR : Chaque case cochée appartient STRICTEMENT au jour " +
  "de la colonne où elle se trouve, sur la ligne de l'élève courant. " +
  "Si une marque est visuellement à cheval entre deux colonnes, attribue-la " +
  "à la colonne dont le centre est le plus proche (ne jamais la dupliquer).\n" +
  "\n" +
   "4. SIGNATURES = PRÉSENT : Les cases vides, les traits de signature " +
   "continu (une ligne qui traverse plusieurs cases), les paraphes, " +
   "les mentions 'P' ou 'V', les cases avec un simple point, " +
   "et tout marquage qui n'est PAS un marqueur d'absence explicite " +
   "sont considérés comme Présent (is_absent = false).\n" +
   "\n" +
   '5. MARQUEURS D\'ABSENCE SEULEMENT : Seules les marques suivantes ' +
   'comptent comme une absence de 2h30 : "X", "/", "A", "Abs", "☑", ' +
   '"■" (case remplie entièrement), ou toute case clairement cochée ' +
   'remplie d\'encre (pas un simple trait de signature, pas un point, ' +
   'pas un "P" ou "V").\n' +
   "\n" +
   "6. VÉRIFICATION GRILLE : Pour chaque élève, confirme visuellement " +
   "que les cases se trouvent bien dans la même ligne horizontale " +
   "que son nom/prénom. Si le nom est à cheval entre deux lignes de " +
   "cases, choisis la ligne supérieure.\n" +
   "\n" +
   "7. COLONNES VIDES = PRÉSENT : Si aucune case n'est cochée sur " +
   "une ligne entière pour un jour donné, l'élève est présent ce " +
   "jour-là (is_absent = false, absence_count = 0).\n" +
   "\n" +
   "8. INTERDICTION DE DÉCALAGE : Ne décale JAMAIS horizontalement " +
   "les marques. Une marque dans la colonne MAR appartient au MAR, " +
   "même si la colonne semble décalée visuellement. Utilise les " +
   "en-têtes comme guide absolu.\n" +
   "\n" +
   "--- FIN DES RÈGLES ---\n" +
  "\n" +
  "La feuille contient une liste d'élèves avec des cases à cocher pour chaque jour " +
  "(LUN, MAR, MER, JEU, VEN, SAM). Chaque jour a 4 créneaux.\n" +
  "\n" +
  "Extrais TOUS les élèves de la feuille, même ceux qui n'ont aucune absence.\n" +
  "Pour chaque élève :\n" +
  "1. is_absent = true si au moins un marqueur d'absence est trouvé.\n" +
  "2. is_absent = false si aucun marqueur (cases vides, signatures, P, V).\n" +
  "3. absence_count = nombre total de marqueurs d'absence (0 si présent).\n" +
  "4. total_hours_absent = absence_count × 2.5 (0.0 si présent).\n" +
  "\n" +
  "Retourne UNIQUEMENT un objet JSON valide. Pas de blocs markdown.";

const RESPONSE_SCHEMA = {
  type: "OBJECT",
  properties: {
    scanned_date: {
      type: "STRING",
      description: "La date inscrite sur la feuille si visible, sinon 'unknown'",
    },
    total_students_count: {
      type: "INTEGER",
      description: "Nombre total d'élèves sur la feuille",
    },
    students: {
      type: "ARRAY",
      description: "Liste complète de tous les élèves",
      items: {
        type: "OBJECT",
        properties: {
          student_name: {
            type: "STRING",
            description: 'Prénom et Nom, format "Firstname LASTNAME"',
          },
          is_absent: {
            type: "BOOLEAN",
            description:
              "true si au moins une marque d'absence est trouvée, false si présent",
          },
          absence_count: {
            type: "INTEGER",
            description: "Nombre total de marques d'absence (0 si présent)",
          },
          total_hours_absent: {
            type: "NUMBER",
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
    signal: AbortSignal.timeout(60000),
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
  // Rate limiting
  const clientIp = req.headers.get("x-forwarded-for") ?? "unknown";
  if (isRateLimited(clientIp)) {
    console.warn(`Rate limit hit for ${clientIp}`);
    return new Response(
      JSON.stringify({ error: userFacingError(429) }),
      { status: 429, headers: { "Content-Type": "application/json" } }
    );
  }

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
    const err = error as Error; 
    // Log full details server-side only — never leak to client
    console.error("Error:", err.message, err.stack);

    const status = err.message.includes("503") ||
        err.message.includes("high demand")
      ? 503
      : err.message.includes("Too Many Requests")
      ? 429
      : 500;

    return new Response(
      JSON.stringify({
        error: userFacingError(status),
      }),
      {
        status,
        headers: { "Content-Type": "application/json" },
      }
    );
  }
});
