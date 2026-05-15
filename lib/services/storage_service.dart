import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/absence_record.dart';

class StorageService {
  static const String _historyKey = 'weekly_scan_history';

  Future<List<WeeklyScanSession>> loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw == null || raw.isEmpty) return [];

      final List<dynamic> decoded = jsonDecode(raw);
      return decoded
          .map((e) => WeeklyScanSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> saveToHistory(WeeklyScanSession session) async {
    final history = await loadHistory();
    history.insert(0, session);
    if (history.length > 20) history.removeRange(20, history.length);

    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(history.map((s) => s.toJson()).toList());
    await prefs.setString(_historyKey, encoded);
  }

  Future<void> deleteHistoryItem(int index) async {
    final history = await loadHistory();
    if (index >= 0 && index < history.length) {
      history.removeAt(index);
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(history.map((s) => s.toJson()).toList());
      await prefs.setString(_historyKey, encoded);
    }
  }

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  Future<String> exportHistoryToJson() async {
    final history = await loadHistory();
    final encoded = jsonEncode(history.map((s) => s.toJson()).toList());
    
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${directory.path}/absences_export_$timestamp.json');
    await file.writeAsString(encoded);
    
    return file.path;
  }

  Future<int> importHistoryFromJson(String filePath) async {
    try {
      final file = File(filePath);
      final content = await file.readAsString();
      final List<dynamic> decoded = jsonDecode(content);
      
      final imported = decoded
          .map((e) => WeeklyScanSession.fromJson(e as Map<String, dynamic>))
          .toList();
      
      final currentHistory = await loadHistory();
      currentHistory.insertAll(0, imported);
      
      if (currentHistory.length > 50) {
        currentHistory.removeRange(50, currentHistory.length);
      }
      
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(currentHistory.map((s) => s.toJson()).toList());
      await prefs.setString(_historyKey, encoded);
      
      return imported.length;
    } catch (e) {
      return -1;
    }
  }
}