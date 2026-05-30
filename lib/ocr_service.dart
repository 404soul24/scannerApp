import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models/absence_record.dart';

class ScanResult {
  final String scannedDate;
  final int totalStudentsCount;
  final List<StudentAbsence> students;
  final String rawText;

  ScanResult({
    required this.scannedDate,
    required this.totalStudentsCount,
    required this.students,
    required this.rawText,
  });
}

class OCRService {
  static const String _functionUrl =
      'https://xpsuryegelcfwjwpmxud.supabase.co/functions/v1/scan-absence';

  String? get _accessToken =>
      Supabase.instance.client.auth.currentSession?.accessToken;

  Future<ScanResult> analyzeSheet(File imageFile) async {
    final imageBytes = await imageFile.readAsBytes();

    if (imageBytes.length > 4_500_000) {
      throw Exception(
        'Image trop volumineuse (${(imageBytes.length / 1048576).toStringAsFixed(1)}Mo). '
        'Veuillez réduire la résolution ou choisir une image plus légère.',
      );
    }

    final base64Image = base64Encode(imageBytes);

    final token = _accessToken;
    if (token == null) {
      throw Exception('Non authentifié. Veuillez vous reconnecter.');
    }

    final path = imageFile.path.toLowerCase();
    final mimeType = path.endsWith('.png') ? 'image/png' : 'image/jpeg';

    final http.Response response;
    try {
      response = await http.post(
        Uri.parse(_functionUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'base64Image': base64Image, 'mimeType': mimeType}),
      );
    } on http.ClientException {
      throw Exception(
        'Impossible de contacter le serveur. Vérifiez votre connexion internet.',
      );
    }

    if (response.statusCode != 200) {
      final msg = _errorMessageForStatus(response.statusCode);
      throw Exception(msg);
    }

    return _parseResponse(response.body);
  }

  ScanResult _parseResponse(String jsonString) {
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Erreur de parsing JSON: ${e.toString()}');
    }

    final scannedDate = data['scanned_date'] as String? ?? 'unknown';
    final totalStudentsCount = data['total_students_count'] as int? ?? 0;
    final rawText = jsonString;

    final List<dynamic> studentsJson =
        data['students'] as List<dynamic>? ?? [];
    final students = <StudentAbsence>[];

    for (int i = 0; i < studentsJson.length; i++) {
      try {
        final entry = studentsJson[i] as Map<String, dynamic>;
        final name = entry['student_name'] as String? ?? 'Inconnu ${i + 1}';
        final isAbsent = entry['is_absent'] as bool? ?? false;
        final absenceCount = entry['absence_count'] as int? ?? 0;
        final totalHours = entry['total_hours_absent'] as num? ?? 0.0;

        students.add(
            _buildStudent(i + 1, name, isAbsent, absenceCount, totalHours));
      } catch (e) {
        continue;
      }
    }

    return ScanResult(
      scannedDate: scannedDate,
      totalStudentsCount: totalStudentsCount,
      students: students,
      rawText: rawText,
    );
  }

  StudentAbsence _buildStudent(int number, String name, bool isAbsent,
      int absenceCount, num totalHours) {
    return StudentAbsence.fromCounts(
      number: number,
      name: name,
      absenceCount: isAbsent ? absenceCount : 0,
    );
  }

  String _errorMessageForStatus(int status) {
    switch (status) {
      case 400:
        return 'Image invalide. Veuillez réessayer avec une autre photo.';
      case 429:
        return 'Trop de requêtes. Veuillez attendre une minute avant de réessayer.';
      case 503:
        return 'Le service est temporairement saturé. Veuillez réessayer plus tard.';
      default:
        return 'Erreur serveur. Veuillez réessayer ou contacter le support.';
    }
  }
}
