import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'models/absence_record.dart';

class ScanResult {
  final String scannedDate;
  final int totalAbsentCount;
  final List<StudentAbsence> students;
  final String rawText;

  ScanResult({
    required this.scannedDate,
    required this.totalAbsentCount,
    required this.students,
    required this.rawText,
  });
}

class OCRService {
  static const _models = ['gemini-2.5-flash', 'gemini-2.0-flash'];
  static const _retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  // TODO: SECURITY WARNING — Before production release, this Gemini API call
  //       must be moved to a backend proxy / cloud function. The API key
  //       stored here or in SharedPreferences can be extracted via APK
  //       decompilation, leading to unauthorized usage and billing abuse.
  //       See: https://cloud.google.com/docs/authentication/api-keys#securing
  final String _apiKey;

  OCRService({required String apiKey}) : _apiKey = apiKey;

  GenerativeModel _createModel(String model) {
    return GenerativeModel(
      model: model,
      apiKey: _apiKey,
      systemInstruction: Content.text(
        'Tu es un assistant spécialisé dans l\'extraction de données de '
        'feuilles d\'absences scolaires. Tu dois analyser l\'image fournie '
        'et retourner UNIQUEMENT un objet JSON valide, sans aucun texte '
        'avant ou après. Ne mets pas de blocs markdown (```json).',
      ),
      generationConfig: GenerationConfig(
        temperature: 0.0,
        responseMimeType: 'application/json',
        responseSchema: Schema(SchemaType.object, properties: {
          'scanned_date': Schema(SchemaType.string,
              description:
                  'La date inscrite sur la feuille si visible, sinon "unknown"'),
          'total_absent_count': Schema(SchemaType.integer,
              description:
                  'Nombre total d\'élèves absents détectés (pas le nombre de cases)'),
          'absents': Schema(SchemaType.array,
              description: 'Liste des élèves absents',
              items: Schema(SchemaType.object, properties: {
                'student_name': Schema(SchemaType.string,
                    description:
                        'Prénom et Nom en majuscules, format "Firstname LASTNAME"'),
                'absence_count': Schema(SchemaType.integer,
                    description:
                        'Nombre total de marques d\'absence pour cet élève'),
                'total_hours_absent': Schema(SchemaType.number,
                    description:
                        'Calculé comme absence_count × 2.5 (chaque case = 2.5h)'),
              })),
        }),
      ),
    );
  }

  bool _isOverloadedError(Object error) {
    if (error is GenerativeAIException) {
      return error.message.contains('503') ||
          error.message.contains('UNAVAILABLE') ||
          error.message.contains('high demand') ||
          error.message.contains('Resource has been exhausted');
    }
    return false;
  }

  Future<ScanResult> analyzeSheet(File imageFile) async {
    final imageBytes = await imageFile.readAsBytes();
    final mimeType = _getMimeType(imageFile.path);

    for (final modelName in _models) {
      for (int attempt = 0; attempt <= _retryDelays.length; attempt++) {
        try {
          final model = _createModel(modelName);
          final response = await model.generateContent([
            Content.multi([
              TextPart(_buildPrompt()),
              DataPart(mimeType, imageBytes),
            ]),
          ]);

          final text = response.text;
          if (text == null || text.isEmpty) {
            throw Exception("Gemini n'a retourné aucun résultat");
          }

          return _parseResponse(text);
        } catch (e) {
          if (_isOverloadedError(e) && attempt < _retryDelays.length) {
            await Future.delayed(_retryDelays[attempt]);
            continue;
          }
          if (_isOverloadedError(e) && modelName != _models.last) {
            break;
          }
          rethrow;
        }
      }
    }

    throw Exception(
      'Le service Gemini est temporairement saturé. Réessayez dans quelques minutes.',
    );
  }

  String _buildPrompt() {
    return 'Analyse cette feuille d\'absences hebdomadaire et extraits les informations suivantes.\n'
        '\n'
        'La feuille contient une liste d\'élèves avec des cases à cocher pour chaque jour '
        '(LUN, MAR, MER, JEU, VEN, SAM). Chaque jour a 4 créneaux.\n'
        '\n'
        'Marques d\'absence à rechercher : "X", "/", "A", "Abs", "☑" ou toute case cochée.\n'
        'Ignore les cases vides ou les marques "P", "V" qui signifient présent.\n'
        '\n'
        'Pour chaque élève absent :\n'
        '1. Compte TOUTES les marques d\'absence sur la semaine entière.\n'
        '2. Calcule total_hours_absent = absence_count × 2.5.\n'
        '3. N\'inclus que les élèves qui ont au moins une marque d\'absence.\n'
        '\n'
        'Retourne UNIQUEMENT un objet JSON valide. Pas de blocs markdown.';
  }

  String _getMimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }

  ScanResult _parseResponse(String jsonString) {
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Erreur de parsing JSON: ${e.toString()}');
    }

    final scannedDate = data['scanned_date'] as String? ?? 'unknown';
    final totalAbsentCount = data['total_absent_count'] as int? ?? 0;
    final rawText = jsonString;

    final List<dynamic> absentsJson =
        data['absents'] as List<dynamic>? ?? [];
    final students = <StudentAbsence>[];

    for (int i = 0; i < absentsJson.length; i++) {
      try {
        final entry = absentsJson[i] as Map<String, dynamic>;
        final name = entry['student_name'] as String? ?? 'Inconnu ${i + 1}';
        final absenceCount = entry['absence_count'] as int? ?? 0;
        final totalHours = entry['total_hours_absent'] as num? ?? 0.0;

        students.add(_buildStudent(i + 1, name, absenceCount, totalHours));
      } catch (e) {
        continue;
      }
    }

    return ScanResult(
      scannedDate: scannedDate,
      totalAbsentCount: totalAbsentCount,
      students: students,
      rawText: rawText,
    );
  }

  StudentAbsence _buildStudent(
      int number, String name, int absenceCount, num totalHours) {
    final week = _orderedDays.map((dayName) {
      return DailyAbsence(dayName: dayName);
    }).toList();

    int slotsToMark = absenceCount;
    int maxSlots = 24;
    if (slotsToMark > maxSlots) slotsToMark = maxSlots;

    int marked = 0;
    for (int d = 0; d < week.length && marked < slotsToMark; d++) {
      for (int s = 0; s < 4 && marked < slotsToMark; s++) {
        week[d].slots[s] = AbsenceSlot(isMarked: true, markType: 'X');
        marked++;
      }
    }

    return StudentAbsence(number: number, name: name, week: week);
  }

  static const _orderedDays = ['LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM'];
}
