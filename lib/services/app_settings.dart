/// Persistent storage for user preferences.
/// 
/// Delegates to [PersistentStorage] which handles platform-specific storage:
/// - Android: file-based JSON in external storage (survives reinstalls)
/// - Desktop: shared_preferences (already survives reinstalls on Windows/macOS/Linux)
library;

import 'persistent_storage.dart';

class AppSettings {
  // -- App name --

  /// Load saved app name, or return default.
  static Future<String> loadAppName() async {
    return PersistentStorage.loadAppName();
  }

  /// Save app name persistently.
  static Future<void> saveAppName(String name) async {
    await PersistentStorage.saveAppName(name);
  }

  // -- Play counts (Map<int, int>) --

  /// Load play counts map: song ID → count.
  static Future<Map<int, int>> loadPlayCounts() async {
    return PersistentStorage.loadPlayCounts();
  }

  /// Save play counts map persistently.
  static Future<void> savePlayCounts(Map<int, int> counts) async {
    await PersistentStorage.savePlayCounts(counts);
  }

  // -- Music folders (desktop only) --

  /// Load music folder paths (desktop).
  static Future<List<String>> loadMusicFolders() async {
    return PersistentStorage.loadMusicFolders();
  }

  /// Save music folder paths (desktop).
  static Future<void> saveMusicFolders(List<String> folders) async {
    await PersistentStorage.saveMusicFolders(folders);
  }

  // -- Pinned grid (Map<int, Map<String, dynamic>>) --

  /// Load pinned grid: tile index (0-8) → song JSON map.
  static Future<Map<int, Map<String, dynamic>>> loadPinnedGrid() async {
    return PersistentStorage.loadPinnedGrid();
  }

  /// Save pinned grid persistently.
  static Future<void> savePinnedGrid(Map<int, Map<String, dynamic>> grid) async {
    await PersistentStorage.savePinnedGrid(grid);
  }

  // -- Mixes (List<Map<String, dynamic>>) --

  /// Load mixes: list of mixes, each with id, name, and songIds.
  static Future<List<Map<String, dynamic>>> loadMixes() async {
    return PersistentStorage.loadMixes();
  }

  /// Save mixes persistently.
  static Future<void> saveMixes(List<Map<String, dynamic>> mixes) async {
    await PersistentStorage.saveMixes(mixes);
  }

  // -- Favorites (List<String> of song IDs) --

  /// Load favorites list (list of song IDs as strings).
  static Future<List<String>> loadFavorites() async {
    return PersistentStorage.loadFavorites();
  }

  /// Save favorites list.
  static Future<void> saveFavorites(List<String> ids) async {
    await PersistentStorage.saveFavorites(ids);
  }

  // -- Clear all data --

  /// Delete ALL persistent data (favorites, mixes, play counts, pinned grid, app name).
  /// Use this for the "Clear All Data" feature in settings.
  static Future<void> clearAllData() async {
    await PersistentStorage.clearAllData();
  }

  /// Get the path to the persistent storage directory (for debugging).
  static Future<String?> getDataPath() async {
    return PersistentStorage.getDataPath();
  }
}
