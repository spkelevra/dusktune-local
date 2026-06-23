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

  // -- Show album art toggle --

  /// Load whether album art display is enabled. Defaults to false (opt-in).
  static Future<bool> loadShowAlbumArt() async {
    return PersistentStorage.loadShowAlbumArt();
  }

  /// Save album art display preference.
  static Future<void> saveShowAlbumArt(bool enabled) async {
    await PersistentStorage.saveShowAlbumArt(enabled);
  }

  /// Load light detection (ALS) preference. Defaults to true.
  static Future<bool> loadLightDetection() async {
    return PersistentStorage.loadLightDetection();
  }

  /// Save light detection (ALS) preference.
  static Future<void> saveLightDetection(bool enabled) async {
    await PersistentStorage.saveLightDetection(enabled);
  }


  // -- Visualizer settings --

  static Future<bool> loadVizEnabled() async {
    return PersistentStorage.loadVizEnabled();
  }

  static Future<void> saveVizEnabled(bool enabled) async {
    await PersistentStorage.saveVizEnabled(enabled);
  }

  /// Visualizer style: "bars" (default), "wave", or "dots".
  static Future<String> loadVizStyle() async {
    return PersistentStorage.loadVizStyle();
  }

  static Future<void> saveVizStyle(String style) async {
    await PersistentStorage.saveVizStyle(style);
  }
  /// Visualizer intensity: 0.0 (minimal) to 2.0 (amplified), default 1.0.

  static Future<double> loadVizIntensity() async {
    return PersistentStorage.loadVizIntensity();
  }

  static Future<void> saveVizIntensity(double intensity) async {
    await PersistentStorage.saveVizIntensity(intensity);
  }

  /// Visualizer smoothing: 0.0 (raw), 1.0 (heavy), default 0.5.
  static Future<double> loadVizSmoothing() async {
    return PersistentStorage.loadVizSmoothing();
  }

  static Future<void> saveVizSmoothing(double smoothing) async {
    await PersistentStorage.saveVizSmoothing(smoothing);
  }
  // -- Artwork cache --

  /// Get cached artwork for a song, or null if not available.
  static Future<List<int>?> loadArtwork(int songId) async {
    return PersistentStorage.loadArtwork(songId);
  }

  /// Save artwork bytes to cache.
  static Future<void> saveArtwork(int songId, List<int> bytes) async {
    await PersistentStorage.saveArtwork(songId, bytes);
  }

  /// Check if artwork is cached for a song.
  static Future<bool> hasArtwork(int songId) async {
    return PersistentStorage.hasArtwork(songId);
  }

  /// Clear all cached artwork thumbnails.
  static Future<void> clearArtworkCache() async {
    await PersistentStorage.clearArtworkCache();
  }

  // -- Artwork rescan flag --

  /// Set flag to trigger a full artwork rescan on next app launch.
  static Future<void> saveRescanFlag(bool value) async {
    await PersistentStorage.saveRescanFlag(value);
  }

  /// Check if a full artwork rescan was requested. Clears the flag after reading.
  static Future<bool> consumeRescanFlag() async {
    return PersistentStorage.consumeRescanFlag();
  }

  // -- Clear all data --

  /// Delete ALL persistent data (favorites, mixes, play counts, pinned grid, app name).
  /// Use this for the "Clear All Data" feature in settings.
  static Future<void> clearAllData() async {
    await PersistentStorage.clearAllData();
  }

  }
