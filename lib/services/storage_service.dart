import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/absence_record.dart';

class StorageService {
  static const String _historyKey = 'weekly_scan_history';
  static const String _settingsKey = 'app_settings';

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

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  Future<int> getMinutesPerSlot() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_settingsKey) ?? 30;
  }

  Future<void> setMinutesPerSlot(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_settingsKey, minutes);
  }
}