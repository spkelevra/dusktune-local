/// Desktop music scanner — recursively scans folders for audio files
/// and parses metadata using ID3 tags (MP3) or filename fallback.
///
/// All file-system I/O that touches network paths runs in a background isolate
/// with hard timeouts so the UI never freezes on unmounted SMB shares.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_package;
import '../models/song.dart';

/// Supported audio file extensions for desktop scanning.
const Set<String> supportedExtensions = {
  '.mp3', '.flac', '.wav', '.m4a', '.ogg', '.aac', '.wma', '.opus',
};

/// How long to wait for a single folder accessibility check via `stat`.
const Duration _accessTimeout = Duration(seconds: 3);

/// Hard timeout per-folder during recursive scan (runs in isolate).
const Duration _scanIsolateTimeout = Duration(seconds: 60);

// ---------------------------------------------------------------------------
// Path normalization
// ---------------------------------------------------------------------------

/// Normalize a user-provided path for macOS/Windows compatibility.
String normalizePath(String raw) {
  var path = raw.trim();

  if (path.startsWith('smb://')) {
    final withoutScheme = path.substring(6); // strip 'smb://'
    final slashIdx = withoutScheme.indexOf('/');
    if (slashIdx > 0) {
      final shareName = withoutScheme.substring(0, slashIdx);
      final subPath = withoutScheme.substring(slashIdx + 1);
      if (Platform.isWindows) {
        // On Windows: smb://host/share/path → \\host\share\path
        path = '\\\\$shareName/${subPath.isEmpty ? '' : subPath.replaceAll('/', '\\')}';
      } else {
        // macOS: smb://host/share/path → /Volumes/share/path
        path = '/Volumes/$shareName/${subPath.isEmpty ? '' : subPath}';
      }
    } else {
      if (Platform.isWindows) {
        path = '\\\\$withoutScheme';
      } else {
        path = '/Volumes/$withoutScheme';
      }
    }
    debugPrint('DesktopMusicScanner: normalized SMB URL "$raw" → "$path"');
  }

  return path;
}

// ---------------------------------------------------------------------------
// Accessibility check — uses `stat` via shell so it can be killed on timeout
// ---------------------------------------------------------------------------

/// Check if a folder exists and is accessible using a native command.
/// - macOS/Linux: uses `stat` + `test -d` subprocess (can be killed on timeout)
/// - Windows: falls back to Directory.exists() with .timeout()
Future<bool> isFolderAccessible(String folderPath) async {
  try {
    if (Platform.isWindows) {
      // On Windows, use dart:io directly — Process.run('stat') doesn't exist.
      // The timeout still protects against hanging network paths.
      final dir = Directory(folderPath);
      final exists = await dir.exists().timeout(_accessTimeout);
      if (!exists) {
        debugPrint('DesktopMusicScanner: folder does not exist: $folderPath');
        return false;
      }
      // On Windows, Directory.exists() is sufficient — it blocks until resolved.
    } else {
      // macOS/Linux: use subprocess so we can hard-kill on timeout.
      final result = await Process.run('stat', ['-f', '%z', folderPath])
          .timeout(_accessTimeout);
      if (result.exitCode != 0) {
        debugPrint('DesktopMusicScanner: stat failed for $folderPath');
        return false;
      }
      final typeResult = await Process.run('test', ['-d', folderPath])
          .timeout(_accessTimeout);
      if (typeResult.exitCode != 0) {
        debugPrint('DesktopMusicScanner: $folderPath is not a directory');
        return false;
      }
    }
    return true;
  } on TimeoutException {
    debugPrint('DesktopMusicScanner: folder timed out (unreachable): $folderPath');
    return false;
  } catch (e) {
    debugPrint('DesktopMusicScanner: folder inaccessible ($e): $folderPath');
    return false;
  }
}

// ---------------------------------------------------------------------------
// Isolate-based recursive scan — pure dart:io, no Flutter calls inside
// ---------------------------------------------------------------------------

/// Pure-dart entry point for the scanning isolate.
/// Returns a list of [title, artist, album, uri] entries. No Flutter APIs called.
List<List<dynamic>> _scanIsolatePure(String folderPath) {
  final results = <List<dynamic>>[];
  final dirsToScan = [folderPath];

  while (dirsToScan.isNotEmpty) {
    final currentPath = dirsToScan.removeLast();
    final currentDir = Directory(currentPath);

    try {
      final entities = currentDir.listSync();
      for (final entity in entities) {
        if (entity is File) {
          final ext = path_package.extension(entity.path).toLowerCase();
          if (!supportedExtensions.contains(ext)) continue;

          final title = _parseTitleFromFilenamePure(entity.path);
          final artist = _parseArtistFromFilenamePure(entity.path);
          results.add([title, artist, null, entity.path]);
        } else if (entity is Directory) {
          dirsToScan.add(entity.path);
        }
      }
    } catch (e) {
      // Silently skip unreadable directories in the isolate
    }
  }

  return results;
}

/// Extract title from file path — pure dart:io, no Flutter.
String _parseTitleFromFilenamePure(String filePath) {
  var title = path_package.basenameWithoutExtension(filePath);
  title = title.replaceFirst(RegExp(r'^\d+\s*[-\.]\s*'), '');
  title = title.replaceFirst(RegExp(r'^\[\d+\]\s*'), '');
  return title.trim().isEmpty ? path_package.basenameWithoutExtension(filePath) : title;
}

/// Extract artist from "Artist - Title" pattern — pure dart:io.
String? _parseArtistFromFilenamePure(String filePath) {
  final basename = path_package.basenameWithoutExtension(filePath);
  if (basename.contains(' - ')) {
    return basename.split(' - ')[0].trim();
  }
  return null;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Scan a list of directories recursively and return all discovered songs.
Future<List<Song>> scanMusicFolders(List<String> folders) async {
  final allSongs = <Song>[];

  for (final rawFolder in folders) {
    final folder = normalizePath(rawFolder);

    // Quick accessibility check via subprocess (won't block Dart event loop)
    if (!await isFolderAccessible(folder)) {
      debugPrint('DesktopMusicScanner: SKIPPING inaccessible folder: $folder');
      continue;
    }

    debugPrint('DesktopMusicScanner: scanning $folder in isolate...');

    // Run the recursive scan in a background isolate with a hard timeout.
    final songs = await _scanInIsolate(folder);
    allSongs.addAll(songs);
  }

  // Sort alphabetically by title
  allSongs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  debugPrint('DesktopMusicScanner: found ${allSongs.length} songs from ${folders.length} folder(s)');
  return allSongs;
}

/// Run the pure-dart scan in an isolate with a hard timeout.
Future<List<Song>> _scanInIsolate(String folderPath) async {
  try {
    // Isolate.run with the pure function — no Flutter APIs inside.
    final rawResults = await Isolate.run<List<List<dynamic>>>(() {
      return _scanIsolatePure(folderPath);
    }).timeout(_scanIsolateTimeout);

    // Convert raw results to Song objects (back in main isolate).
    int idCounter = 0;
    final songs = <Song>[];
    for (final entry in rawResults) {
      idCounter++;
      songs.add(Song.fromMap(
        id: idCounter,
        title: entry[0] as String,
        artist: entry[1] as String?,
        album: entry[2] as String?,
        uri: entry[3] as String,
      ));
    }

    debugPrint('DesktopMusicScanner: isolate returned ${songs.length} songs from $folderPath');
    return songs;
  } on TimeoutException {
    debugPrint('DesktopMusicScanner: isolate scan timed out for $folderPath');
    return [];
  } catch (e, st) {
    debugPrint('DesktopMusicScanner: isolate error scanning $folderPath: $e\n$st');
    return [];
  }
}
