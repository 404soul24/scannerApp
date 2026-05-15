import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
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

  static const String _anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhwc3VyeWVnZWxjZndqd3BteHVkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg4NjI0NzIsImV4cCI6MjA5NDQzODQ3Mn0.Lc2YvNa72BylvMTvvgFFmsIohWCf9G75GqEZGoUJ8W0';

  Future<ScanResult> analyzeSheet(File imageFile) async {
    final imageBytes = await imageFile.readAsBytes();

    if (imageBytes.length > 4_500_000) {
      throw Exception(
        'Image trop volumineuse (${(imageBytes.length / 1048576).toStringAsFixed(1)}Mo). '
        'Veuillez réduire la résolution ou choisir une image plus légère.',
      );
    }

    final base64Image = base64Encode(imageBytes);

    final http.Response response;
    try {
      response = await http.post(
        Uri.parse(_functionUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_anonKey',
        },
        body: jsonEncode({'base64Image': base64Image}),
      );
    } on http.ClientException catch (e) {
      throw Exception(
        'Impossible de contacter le serveur: ${e.message}',
      );
    }

    if (response.statusCode != 200) {
      final snippet = response.body.length > 200
          ? response.body.substring(0, 200)
          : response.body;
      throw Exception(
        'Erreur serveur (${response.statusCode}): $snippet',
      );
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
    final week = _orderedDays
        .map((dayName) => DailyAbsence(dayName: dayName))
        .toList();

    if (isAbsent && absenceCount > 0) {
      int slotsToMark = absenceCount;
      if (slotsToMark > 24) slotsToMark = 24;

      int marked = 0;
      for (int d = 0; d < week.length && marked < slotsToMark; d++) {
        for (int s = 0; s < 4 && marked < slotsToMark; s++) {
          week[d].slots[s] = AbsenceSlot(isMarked: true, markType: 'X');
          marked++;
        }
      }
    }

    return StudentAbsence(number: number, name: name, week: week);
  }

  static const _orderedDays = ['LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM'];
}
