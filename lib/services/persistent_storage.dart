/// File-based persistent storage that survives app reinstalls on Android.
/// 
/// On Android, stores JSON files in a public directory under external storage
/// (/storage/emulated/0/Documents/dusktune/) which is NOT deleted when the app
/// is uninstalled. Data persists until the user explicitly clears it via the
/// app's settings or manually deletes the folder from Android file manager.
/// 
/// On desktop platforms (Windows/macOS/Linux), delegates to shared_preferences
/// which already survives reinstalls on those platforms.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PersistentStorage {
  /// Directory name for our persistent data in external storage.
  static const String _directoryName = 'dusktune';
  
  /// Lock to prevent concurrent permission requests.
  static Future<void>? _permissionLock;
  
  /// Cached permission-granted state.
  static bool? _permissionGranted;

  /// Ensure MANAGE_EXTERNAL_STORAGE permission is granted (with locking).
  static Future<void> _ensurePermission() async {
    if (_permissionGranted == true) return; // Already granted, no need to request again.

    _permissionLock ??= _doEnsurePermission();
    await _permissionLock!;
    _permissionLock = null;
  }

  static Future<void> _doEnsurePermission() async {
      final status = Permission.manageExternalStorage.status;
      if (!await status.isGranted) {
        await Permission.manageExternalStorage.request();
      }
      _permissionGranted = await Permission.manageExternalStorage.status.isGranted;
    }
  
  /// File names for each data category.
  static const String _kAppName = 'app_name.json';
  static const String _kPlayCounts = 'play_counts.json';
  static const String _kPinnedGrid = 'pinned_grid.json';
  static const String _kMixes = 'mixes.json';
  static const String _kFavorites = 'favorites.json';
  static const String _kShowAlbumArt = 'show_album_art.json';
  static const String _kLightDetection = 'light_detection.json';
  static const String _kVizEnabled = 'viz_enabled.json';
  static const String _kVizStyle = 'viz_style.json';
  static const String _kVizIntensity = 'viz_intensity.json';
  static const String _kVizSmoothing = 'viz_smoothing.json';
  static const String _kRecentSongsCollapsed = 'recent_songs_collapsed.json';

  /// Subdirectory for cached album artwork thumbnails.
  static const String _artworkSubDir = 'artwork';

  /// The directory where persistent data is stored.
  /// On Android: /storage/emulated/0/Documents/dusktune/
  /// Lazily initialized on first access.
  static Directory? _dataDir;

  /// Get the persistent storage directory, creating it if needed.
  static Future<Directory> _ensureDataDir() async {
    if (_dataDir != null && _dataDir!.existsSync()) return _dataDir!;

    Directory targetDir;
    if (Platform.isAndroid) {
      // Request MANAGE_EXTERNAL_STORAGE permission for public directory access.
      await _ensurePermission();

      // Use a hardcoded public path that survives app uninstall.
      // /storage/emulated/0/Documents/dusktune/ is outside the app sandbox,
      // so it persists across reinstalls and is only cleared when the user
      // explicitly deletes it via "Clear All Data" or Android file manager.
      targetDir = Directory('/storage/emulated/0/Documents/$_directoryName');

      if (!targetDir.existsSync()) {
        try {
          targetDir.createSync(recursive: true);
        } catch (e) {
          debugPrint('PersistentStorage: failed to create dir, falling back to app docs: $e');
          final appDocDir = await getApplicationDocumentsDirectory();
          targetDir = Directory('${appDocDir.path}/$_directoryName');
          targetDir.createSync(recursive: true);
        }
      }
    } else {
      // Desktop: use application documents directory (already survives reinstalls)
      final appDocDir = await getApplicationDocumentsDirectory();
      targetDir = Directory('${appDocDir.path}/$_directoryName');

      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }
    }
    
    _dataDir = targetDir;
    return targetDir;
  }

  /// Get the full path for a data file.
  static Future<String> _filePath(String fileName) async {
    final dir = await _ensureDataDir();
    return '${dir.path}/$fileName';
  }

  // -- Read operations --

  /// Read JSON from a file, returning null if not found or parse error.
  static Future<dynamic> _readJsonAsync(String fileName) async {
    try {
      final path = await _filePath(fileName);
      final file = File(path);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.isEmpty) return null;
      return jsonDecode(content);
    } catch (e) {
      debugPrint('PersistentStorage read error ($fileName): $e');
      return null;
    }
  }

  // -- Write operations --

  /// Write JSON to a file.
  static Future<void> _writeJson(String fileName, dynamic data) async {
    try {
      final path = await _filePath(fileName);
      final file = File(path);
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('PersistentStorage write error ($fileName): $e');
      rethrow;
    }
  }

  // -- App name --

  static Future<String> loadAppName() async {
    if (!Platform.isAndroid) {
      // Desktop: use shared_preferences (already survives reinstalls)
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('app_name') ?? 'dusktune';
    }
    
    final data = await _readJsonAsync(_kAppName);
    if (data is String) return data;
    return 'dusktune';
  }

  static Future<void> saveAppName(String name) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_name', name);
      return;
    }
    
    await _writeJson(_kAppName, name);
  }

  // -- Play counts (Map<int, int>) --

  static Future<Map<int, int>> loadPlayCounts() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('play_counts_v1');
      if (raw == null || raw.isEmpty) return {};
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        return map.map((k, v) => MapEntry(int.parse(k), v as int));
      } catch (_) {
        return {};
      }
    }
    
    final data = await _readJsonAsync(_kPlayCounts);
    if (data is! Map<String, dynamic>) return {};
    try {
      return data.map((k, v) => MapEntry(int.parse(k), v as int));
    } catch (_) {
      return {};
    }
  }

  static Future<void> savePlayCounts(Map<int, int> counts) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(counts.map((k, v) => MapEntry(k.toString(), v)));
      await prefs.setString('play_counts_v1', raw);
      return;
    }
    
    // Convert int keys to string for JSON serialization
    final serializable = counts.map((k, v) => MapEntry(k.toString(), v));
    await _writeJson(_kPlayCounts, serializable);
  }

  // -- Pinned grid (Map<int, Map<String, dynamic>>) --

  static Future<Map<int, Map<String, dynamic>>> loadPinnedGrid() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('pinned_grid_v1');
      if (raw == null || raw.isEmpty) return {};
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        return map.map((k, v) => MapEntry(int.parse(k), v as Map<String, dynamic>));
      } catch (_) {
        return {};
      }
    }
    
    final data = await _readJsonAsync(_kPinnedGrid);
    if (data is! Map<String, dynamic>) return {};
    try {
      return data.map((k, v) => MapEntry(int.parse(k), v as Map<String, dynamic>));
    } catch (_) {
      return {};
    }
  }

  static Future<void> savePinnedGrid(Map<int, Map<String, dynamic>> grid) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(grid.map((k, v) => MapEntry(k.toString(), v)));
      await prefs.setString('pinned_grid_v1', raw);
      return;
    }
    
    // Convert int keys to string for JSON serialization
    final serializable = grid.map((k, v) => MapEntry(k.toString(), v));
    await _writeJson(_kPinnedGrid, serializable);
  }

  // -- Mixes (List<Map<String, dynamic>>) --

  static Future<List<Map<String, dynamic>>> loadMixes() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('mixes_v1');
      if (raw == null || raw.isEmpty) return [];
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        return list.map((e) => e as Map<String, dynamic>).toList();
      } catch (_) {
        return [];
      }
    }
    
    final data = await _readJsonAsync(_kMixes);
    if (data is! List<dynamic>) return [];
    try {
      return data.map((e) => e as Map<String, dynamic>).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveMixes(List<Map<String, dynamic>> mixes) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(mixes);
      await prefs.setString('mixes_v1', raw);
      return;
    }
    
    await _writeJson(_kMixes, mixes);
  }

  // -- Favorites (List<String> of song IDs) --

  static Future<List<dynamic>> loadFavorites() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('favorites_v2');
      if (raw == null || raw.isEmpty) return [];
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        return list.map((e) => e as Map<String, dynamic>).toList();
      } catch (_) {
        // Fallback to old format for migration
        final oldList = prefs.getStringList('favorites') ?? [];
        if (oldList.isNotEmpty) {
          return oldList; // Return old string IDs — main.dart handles both formats
        }
        return [];
      }
    }

    final data = await _readJsonAsync(_kFavorites);
    if (data is! List<dynamic>) return [];
    try {
      return data.map((e) => e as Map<String, dynamic>).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveFavorites(List<Map<String, dynamic>> songDataList) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('favorites_v2', jsonEncode(songDataList));
      return;
    }
    
    await _writeJson(_kFavorites, songDataList);
  }

  // -- Show album art toggle (bool) --

  /// Load whether album art display is enabled. Defaults to false.
  static Future<bool> loadShowAlbumArt() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('show_album_art') ?? false;
    }

    final data = await _readJsonAsync(_kShowAlbumArt);
    if (data is bool) return data;
    return false; // Default: off
  }

  /// Save album art display preference.
  static Future<void> saveShowAlbumArt(bool enabled) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('show_album_art', enabled);
      return;
    }

    await _writeJson(_kShowAlbumArt, enabled);
  }

  /// Load light detection (ALS) preference. Defaults to true (enabled).
  static Future<bool> loadLightDetection() async {
    if (!Platform.isAndroid) return false;
    final data = await _readJsonAsync(_kLightDetection);
    if (data is bool) return data;
    return false; // Default: off
  }

  /// Save light detection (ALS) preference.
  static Future<void> saveLightDetection(bool enabled) async {
    if (!Platform.isAndroid) return;
    await _writeJson(_kLightDetection, enabled);
  }

  // -- Artwork cache helpers --

  /// Get the path to a cached artwork thumbnail for a given song ID.
  static Future<String> getArtworkPath(int songId) async {
    final dir = await _ensureDataDir();
    final artDir = Directory('${dir.path}/$_artworkSubDir');
    if (!artDir.existsSync()) {
      artDir.createSync(recursive: true);
    }
    return '${artDir.path}/${songId}.jpg';
  }

  /// Save artwork bytes (Uint8List) to cache.
  static Future<void> saveArtwork(int songId, List<int> bytes) async {
    final path = await getArtworkPath(songId);
    await File(path).writeAsBytes(bytes);
  }

  /// Load cached artwork for a song ID, or null if not found.
  static Future<List<int>?> loadArtwork(int songId) async {
    try {
      final path = await getArtworkPath(songId);
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Check if artwork is cached for a song ID.
  static Future<bool> hasArtwork(int songId) async {
    try {
      final path = await getArtworkPath(songId);
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Clear all cached artwork thumbnails.
  static Future<void> clearArtworkCache() async {
    try {
      final dir = await _ensureDataDir();
      final artDir = Directory('${dir.path}/$_artworkSubDir');
      if (artDir.existsSync()) {
        await artDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('PersistentStorage clearArtworkCache error: $e');
    }
  }

  // -- Artwork rescan flag --

  static const String _kRescanFlag = 'rescan_artwork.json';

  /// Set a flag to trigger a full artwork rescan on next app launch.
  static Future<void> saveRescanFlag(bool value) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('rescan_artwork', value);
      return;
    }
    await _writeJson(_kRescanFlag, value);
  }

  /// Check and consume the rescan flag. Returns true if a rescan was requested,
  /// and clears the flag so it only fires once.
  static Future<bool> consumeRescanFlag() async {
    bool flagged = false;
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      flagged = prefs.getBool('rescan_artwork') ?? false;
      if (flagged) await prefs.setBool('rescan_artwork', false);
    } else {
      final data = await _readJsonAsync(_kRescanFlag);
      if (data is bool && data) {
        flagged = true;
        // Clear the flag by deleting the file
        try {
          final path = await _filePath(_kRescanFlag);
          await File(path).delete();
        } catch (e) { debugPrint("PersistentStorage rescan flag delete error (ignored): $e"); }
      }
    }
    return flagged;
  }

  // -- Music folders (desktop only, List<String>) --

  static Future<List<String>> loadMusicFolders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('music_folders_v1') ?? [];
  }

  static Future<void> saveMusicFolders(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('music_folders_v1', folders);
  }


  // -- Visualizer settings (bool + style string) --

  static Future<bool> loadVizEnabled() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('viz_enabled') ?? false;
    }
    final data = await _readJsonAsync(_kVizEnabled);
    if (data is bool) return data;
    return false;
  }

  static Future<void> saveVizEnabled(bool enabled) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('viz_enabled', enabled);
      return;
    }
    await _writeJson(_kVizEnabled, enabled);
  }

  /// Visualizer style: "bars" (default), "wave", "dots", "circles", or "peakhold".
  static Future<String> loadVizStyle() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('viz_style') ?? 'bars';
    }
    final data = await _readJsonAsync(_kVizStyle);
    if (data is String && ['bars', 'wave', 'dots', 'circles', 'peakhold'].contains(data)) return data;
    return 'bars';
  }

  static Future<void> saveVizStyle(String style) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('viz_style', style);
      return;
    }
    await _writeJson(_kVizStyle, style);
  }
  /// Visualizer intensity: 0.0 (off/minimal) to 2.0 (amplified), default 1.0.

  static Future<double> loadVizIntensity() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble('viz_intensity') ?? 1.0;
    }
    final data = await _readJsonAsync(_kVizIntensity);
    if (data is double || data is int) return (data as num).toDouble().clamp(0.0, 2.0);
    return 1.0;
  }

  static Future<void> saveVizIntensity(double intensity) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('viz_intensity', intensity.clamp(0.0, 2.0));
      return;
    }
    await _writeJson(_kVizIntensity, intensity.clamp(0.0, 2.0));
  }
  /// Visualizer smoothing/decay: 0.0 (raw), 1.0 (heavy), default 0.5.
  static Future<double> loadVizSmoothing() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble('viz_smoothing') ?? 0.5;
    }
    final data = await _readJsonAsync(_kVizSmoothing);
    if (data is double || data is int) return (data as num).toDouble().clamp(0.0, 1.0);
    return 0.5;
  }

  static Future<void> saveVizSmoothing(double smoothing) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('viz_smoothing', smoothing.clamp(0.0, 1.0));
      return;
    }
    await _writeJson(_kVizSmoothing, smoothing.clamp(0.0, 1.0));
  }

  // -- Recent songs collapsed state (bool) --

  static Future<bool> loadRecentSongsCollapsed() async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('recent_songs_collapsed') ?? false;
    }
    final data = await _readJsonAsync(_kRecentSongsCollapsed);
    if (data is bool) return data;
    return false; // Default: expanded
  }

  static Future<void> saveRecentSongsCollapsed(bool collapsed) async {
    if (!Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('recent_songs_collapsed', collapsed);
      return;
    }
    await _writeJson(_kRecentSongsCollapsed, collapsed);
  }

  // -- Clear all persistent data --

  /// Delete ALL persistent data files. Use this for the "Clear All Data" feature.
  static Future<void> clearAllData() async {
    // Clear file-based storage (Android)
    try {
      final dir = await _ensureDataDir();
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
        // Recreate empty directory
        dir.createSync(recursive: true);
      }
    } catch (e) {
      debugPrint('PersistentStorage clearAllData error: $e');
    }

    // Clear shared_preferences (desktop + fallback)
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (e) {
      debugPrint('PersistentStorage clear prefs error: $e');
    }

    _dataDir = null; // Reset cached directory
  }

  }
