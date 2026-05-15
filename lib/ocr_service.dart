import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'models/absence_record.dart';

class ScanResult {
  final List<StudentAbsence> students;
  final String rawText;

  ScanResult({required this.students, required this.rawText});
}

class OCRService {
  static const _models = ['gemini-2.5-flash', 'gemini-2.0-flash'];
  static const _retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  final String _apiKey;

  OCRService({required String apiKey}) : _apiKey = apiKey;

  GenerativeModel _createModel(String model) {
    return GenerativeModel(
      model: model,
      apiKey: _apiKey,
      generationConfig: GenerationConfig(
        responseMimeType: 'application/json',
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
    final prompt = _buildPrompt();

    for (final modelName in _models) {
      for (int attempt = 0; attempt <= _retryDelays.length; attempt++) {
        try {
          final model = _createModel(modelName);
          final response = await model.generateContent([
            Content.multi([
              TextPart(prompt),
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
    return '''Tu es un assistant spécialisé dans l'analyse de feuilles d'absences scolaires.

Examine cette image de feuille d'absences hebdomadaire et extrait toutes les informations.

La feuille contient :
- Une liste d'élèves avec leur numéro et nom (format: "1. Nom Prénom")
- Des cases à cocher pour chaque jour de la semaine : LUN, MAR, MER, JEU, VEN, SAM
- Chaque jour a 4 créneaux horaires
- Les marques d'absence possibles sont : X, /, A, ☑, ☒, ✓

Instructions :
1. Extrais le numéro et le nom de chaque élève
2. Pour chaque élève, examine chaque jour (LUN à SAM) et chaque créneau (1 à 4)
3. Si un créneau est marqué (X, /, A, coché), mets isMarked à true et inscris la marque dans markType
4. Si un créneau n'est pas marqué, mets isMarked à false et markType à ""
5. Extrais aussi le texte brut visible dans la feuille et mets-le dans rawText

Retourne UNIQUEMENT un objet JSON valide avec la structure exacte :
{
  "rawText": "...",
  "students": [
    {
      "number": 1,
      "name": "Nom Prénom",
      "week": [
        { "dayName": "LUN", "slots": [{"isMarked": false, "markType": ""}, ...] },
        { "dayName": "MAR", "slots": [{"isMarked": false, "markType": ""}, ...] },
        { "dayName": "MER", "slots": [...] },
        { "dayName": "JEU", "slots": [...] },
        { "dayName": "VEN", "slots": [...] },
        { "dayName": "SAM", "slots": [...] }
      ]
    }
  ]
}
Ne mets aucun texte avant ou après le JSON.''';
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
    final Map<String, dynamic> data = jsonDecode(jsonString);

    final rawText = data['rawText'] as String? ?? '';

    final List<dynamic> studentsJson =
        data['students'] as List<dynamic>? ?? [];
    final students = studentsJson
        .map((s) => _parseStudent(s as Map<String, dynamic>))
        .toList();

    return ScanResult(students: students, rawText: rawText);
  }

  static const _orderedDays = ['LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM'];

  StudentAbsence _parseStudent(Map<String, dynamic> json) {
    final number = json['number'] as int? ?? 0;
    final name = json['name'] as String? ?? '';

    final List<dynamic> weekJson = json['week'] as List<dynamic>? ?? [];
    final parsedDays =
        weekJson.map((d) => _parseDay(d as Map<String, dynamic>)).toList();

    final Map<String, DailyAbsence> dayMap = {};
    for (final day in parsedDays) {
      dayMap[day.dayName.toUpperCase()] = day;
    }

    final week = _orderedDays.map((dayName) {
      if (dayMap.containsKey(dayName)) return dayMap[dayName]!;
      return DailyAbsence(dayName: dayName);
    }).toList();

    return StudentAbsence(number: number, name: name, week: week);
  }

  DailyAbsence _parseDay(Map<String, dynamic> json) {
    final dayName = json['dayName'] as String? ?? '';

    final List<dynamic> slotsJson = json['slots'] as List<dynamic>? ?? [];
    final slots =
        slotsJson.map((s) => _parseSlot(s as Map<String, dynamic>)).toList();

    return DailyAbsence(dayName: dayName, slots: slots);
  }

  AbsenceSlot _parseSlot(Map<String, dynamic> json) {
    return AbsenceSlot(
      isMarked: json['isMarked'] as bool? ?? false,
      markType: json['markType'] as String? ?? '',
    );
  }
}
