/// Persistent storage for user preferences using shared_preferences.
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const String _kAppName = 'app_name';
  static const String _kPlayCounts = 'play_counts_v1'; // bump suffix on schema change
  static const String _kMusicFolders = 'music_folders_v1';
  static const String _kPinnedGrid = 'pinned_grid_v1';
  static const String _kMixes = 'mixes_v1';

  /// Load saved app name, or return default.
  static Future<String> loadAppName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kAppName) ?? 'dusktune';
  }

  /// Save app name persistently.
  static Future<void> saveAppName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAppName, name);
  }

  /// Load play counts map: song ID → count.
  static Future<Map<int, int>> loadPlayCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPlayCounts);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(int.parse(k), v as int));
    } catch (_) {
      return {};
    }
  }

  /// Save play counts map persistently.
  static Future<void> savePlayCounts(Map<int, int> counts) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(counts.map((k, v) => MapEntry(k.toString(), v)));
    await prefs.setString(_kPlayCounts, raw);
  }

  /// Load music folder paths (desktop).
  static Future<List<String>> loadMusicFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kMusicFolders) ?? [];
    return raw.where((p) => p.isNotEmpty).toList();
  }

  /// Save music folder paths (desktop).
  static Future<void> saveMusicFolders(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kMusicFolders, folders);
  }

  /// Load pinned grid: tile index (0-8) → song JSON map.
  static Future<Map<int, Map<String, dynamic>>> loadPinnedGrid() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPinnedGrid);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(int.parse(k), v as Map<String, dynamic>));
    } catch (_) {
      return {};
    }
  }

  /// Save pinned grid persistently.
  static Future<void> savePinnedGrid(Map<int, Map<String, dynamic>> grid) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(grid.map((k, v) => MapEntry(k.toString(), v)));
    await prefs.setString(_kPinnedGrid, raw);
  }

  /// Load mixes: list of mixes, each with id, name, and songIds.
  static Future<List<Map<String, dynamic>>> loadMixes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kMixes);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => e as Map<String, dynamic>).toList();
    } catch (_) {
      return [];
    }
  }

  /// Save mixes persistently.
  static Future<void> saveMixes(List<Map<String, dynamic>> mixes) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(mixes);
    await prefs.setString(_kMixes, raw);
  }
}