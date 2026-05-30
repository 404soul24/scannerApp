import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/absence_record.dart';
import '../models/class_model.dart';
import '../ocr_service.dart';

class AbsenceLogRecord {
  final String id;
  final String schoolId;
  final String classId;
  final String teacherId;
  final String scanDate;
  final DateTime scannedAt;
  final String rawJsonOutput;
  final List<StudentAbsence> students;

  AbsenceLogRecord({
    required this.id,
    required this.schoolId,
    required this.classId,
    required this.teacherId,
    required this.scanDate,
    required this.scannedAt,
    required this.rawJsonOutput,
    required this.students,
  });

  int get studentsWithAbsences => students.where((s) => s.hasAnyAbsence).length;

  int get totalAbsenceMinutes =>
      students.fold(0, (sum, s) => sum + s.getTotalMinutes());

  factory AbsenceLogRecord.fromJson(Map<String, dynamic> json) {
    final rawOutput = json['raw_json_output'] as String? ?? '{}';
    final rawData = Map<String, dynamic>.from(
      jsonDecode(rawOutput) as Map<String, dynamic>? ?? {},
    );

    final studentsJson = rawData['students'] as List<dynamic>? ?? [];
    final students = <StudentAbsence>[];
    for (int i = 0; i < studentsJson.length; i++) {
      final entry = studentsJson[i] as Map<String, dynamic>;
      final name = entry['student_name'] as String? ?? 'Inconnu ${i + 1}';
      final isAbsent = entry['is_absent'] as bool? ?? false;
      final absenceCount = entry['absence_count'] as int? ?? 0;

      students.add(StudentAbsence.fromCounts(
        number: i + 1,
        name: name,
        absenceCount: isAbsent ? absenceCount : 0,
      ));
    }

    return AbsenceLogRecord(
      id: json['id'] as String,
      schoolId: json['school_id'] as String,
      classId: json['class_id'] as String,
      teacherId: json['teacher_id'] as String,
      scanDate: json['scan_date'] as String? ?? '',
      scannedAt: DateTime.parse(json['scanned_at'] as String),
      rawJsonOutput: rawOutput,
      students: students,
    );
  }
}

class AbsenceRepository extends ChangeNotifier {
  final SupabaseClient _client = Supabase.instance.client;

  List<AbsenceLogRecord> _history = [];
  bool _isLoading = false;
  String? _error;

  List<AbsenceLogRecord> get history => _history;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<List<ClassModel>> loadClasses(String schoolId) async {
    try {
      final response = await _client
          .from('classes')
          .select()
          .eq('school_id', schoolId)
          .order('name');

      return (response as List<dynamic>)
          .map((json) => ClassModel.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error loading classes: $e');
      return [];
    }
  }

  Future<void> loadHistory(String schoolId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _client
          .from('absences_log')
          .select()
          .eq('school_id', schoolId)
          .order('scanned_at', ascending: false)
          .limit(50);

      _history = (response as List<dynamic>)
          .map((json) => AbsenceLogRecord.fromJson(json as Map<String, dynamic>))
          .toList();

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load history: $e';
      _isLoading = false;
      debugPrint(_error);
      notifyListeners();
    }
  }

  Future<String?> saveScan({
    required String schoolId,
    required String classId,
    required String teacherId,
    required ScanResult scanResult,
  }) async {
    try {
      final rawData = {
        'scanned_date': scanResult.scannedDate,
        'total_students_count': scanResult.totalStudentsCount,
        'students': scanResult.students
            .map((s) => {
                  'student_name': s.name,
                  'is_absent': s.hasAnyAbsence,
                  'absence_count': s.totalMarkedSlots,
                  'total_hours_absent': s.getTotalMinutes() / 60.0,
                })
            .toList(),
      };

      final logResponse = await _client.from('absences_log').insert({
        'school_id': schoolId,
        'class_id': classId,
        'teacher_id': teacherId,
        'scan_date': scanResult.scannedDate,
        'raw_json_output': rawData,
      }).select('id').single();

      final logId = logResponse['id'] as String;

      final studentRows = scanResult.students
          .map((s) => {
                'absence_log_id': logId,
                'student_name': s.name,
                'is_absent': s.hasAnyAbsence,
                'absence_count': s.totalMarkedSlots,
                'hours_absent': s.getTotalMinutes() / 60.0,
              })
          .toList();

      await _client.from('student_absences').insert(studentRows);

      return logId;
    } catch (e) {
      _error = 'Failed to save scan: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    }
  }

  Future<bool> deleteScan(String logId) async {
    try {
      await _client.from('absences_log').delete().eq('id', logId);
      _history.removeWhere((r) => r.id == logId);
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to delete scan: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }
}
