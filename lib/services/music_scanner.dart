/// Desktop music scanner — recursively scans folders for audio files
/// and parses metadata using ID3 tags (MP3) or filename fallback.
library;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:id3/id3.dart';
import 'package:path/path.dart' as path_package;
import '../models/song.dart';

/// Supported audio file extensions for desktop scanning.
const Set<String> supportedExtensions = {
  '.mp3', '.flac', '.wav', '.m4a', '.ogg', '.aac', '.wma', '.opus',
};

/// Scan a list of directories recursively and return all discovered songs.
Future<List<Song>> scanMusicFolders(List<String> folders) async {
  final songs = <Song>[];
  int idCounter = 0;

  for (final folder in folders) {
    final dir = Directory(folder);
    if (!await dir.exists()) {
      debugPrint('DesktopMusicScanner: folder does not exist: $folder');
      continue;
    }

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final ext = path_package.extension(entity.path).toLowerCase();
        if (!supportedExtensions.contains(ext)) continue;

        try {
          idCounter++;
          final song = _parseFile(entity, idCounter);
          songs.add(song);
        } catch (e) {
          debugPrint('DesktopMusicScanner: failed to parse ${entity.path}: $e');
        }
      }
    }
  }

  // Sort alphabetically by title
  songs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  debugPrint('DesktopMusicScanner: found ${songs.length} songs from ${folders.length} folder(s)');
  return songs;
}

/// Parse a single audio file and extract metadata.
Song _parseFile(File file, int id) {
  final basename = path_package.basenameWithoutExtension(file.path);
  String? title;
  String? artist;
  String? album;
  int duration = 0;

  // Try ID3 parsing for MP3 files
  final ext = path_package.extension(file.path).toLowerCase();
  if (ext == '.mp3') {
    try {
      final bytes = file.readAsBytesSync();
      final mp3 = MP3Instance(bytes);
      if (mp3.parseTagsSync()) {
        final tags = mp3.getMetaTags() ?? {};
        title = _cleanTag(tags['Title']?.toString());
        artist = _cleanTag(tags['Artist']?.toString());
        album = _cleanTag(tags['Album']?.toString());
      }
    } catch (e) {
      debugPrint('DesktopMusicScanner: ID3 parse failed for ${file.path}: $e');
    }
  }

  // Fallback to filename if no metadata found
  title ??= _parseTitleFromFilename(basename);
  
  // Try to parse "Artist - Title" pattern from filename
  if (basename.contains(' - ')) {
    final parts = basename.split(' - ');
    if (artist == null && parts.isNotEmpty) {
      artist = parts[0].trim();
    }
  }

  return Song.fromMap(
    id: id,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    uri: file.path,
  );
}

/// Clean up a tag value — trim whitespace and null strings.
String? _cleanTag(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value.trim();
}

/// Parse title from filename, removing common patterns like track numbers.
String _parseTitleFromFilename(String basename) {
  var title = basename;
  
  // Remove leading track number patterns: "01 - ", "01.", "[01] ", etc.
  title = title.replaceFirst(RegExp(r'^\d+\s*[-\.]\s*'), '');
  title = title.replaceFirst(RegExp(r'^\[\d+\]\s*'), '');
  
  return title.trim().isEmpty ? basename : title;
}
