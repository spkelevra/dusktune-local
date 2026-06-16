/// Album artwork extractor — platform-specific implementation.
/// 
/// On Android, uses on_audio_query to fetch artwork from MediaStore.
/// On desktop, extracts embedded APIC frames from MP3 files via the id3 package.
/// Results are cached to disk for fast subsequent loads.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:id3/id3.dart' as id3_lib;
import '../models/song.dart';
import 'app_settings.dart';

class ArtworkExtractor {
  /// Load cached artwork for songs without extracting new thumbnails.
  /// Fast path for app startup — only reads files that already exist in cache.
  static Future<List<Song>> loadCachedForSongs(List<Song> songs) async {
    final showArt = await AppSettings.loadShowAlbumArt();
    if (!showArt || songs.isEmpty) return songs;

    debugPrint('ArtworkExtractor: loading cached for ${songs.length} songs');

    final updatedSongs = <Song>[];
    for (final song in songs) {
      if (await AppSettings.hasArtwork(song.id)) {
        final cached = await AppSettings.loadArtwork(song.id);
        if (cached != null && cached.isNotEmpty) {
          updatedSongs.add(song.copyWith(artworkBytes: Uint8List.fromList(cached)));
          continue;
        }
      }
      updatedSongs.add(song);
    }

    debugPrint('ArtworkExtractor: loaded ${updatedSongs.where((s) => s.artworkBytes != null).length} cached thumbnails');
    return updatedSongs;
  }

  /// Extract and cache album artwork for a list of songs.
    /// Returns the updated song list with artworkBytes populated where available.
    /// 
    /// Only runs extraction if [showAlbumArt] is enabled in settings.
    /// Skips songs that already have cached thumbnails.
    static Future<List<Song>> extractForSongs(List<Song> songs) async {
      final showArt = await AppSettings.loadShowAlbumArt();
      if (!showArt || songs.isEmpty) return songs;

      debugPrint('ArtworkExtractor: extracting for ${songs.length} songs');

      if (Platform.isAndroid) {
        return _extractAndroid(songs);
      } else {
        return _extractDesktop(songs);
      }
    }

  // -----------------------------------------------------------------------
  // Android path — use on_audio_query MediaStore API
  // -----------------------------------------------------------------------

  static Future<List<Song>> _extractAndroid(List<Song> songs) async {
    final audioQuery = OnAudioQuery();
    final updatedSongs = <Song>[];

    for (final song in songs) {
      // Check cache first
      if (await AppSettings.hasArtwork(song.id)) {
        final cached = await AppSettings.loadArtwork(song.id);
        if (cached != null && cached.isNotEmpty) {
          updatedSongs.add(song.copyWith(artworkBytes: Uint8List.fromList(cached)));
          continue;
        }
      }

      // Fetch from MediaStore — use song ID with AUDIO type
      try {
        final artwork = await audioQuery.queryArtwork(
          song.id,
          ArtworkType.AUDIO,
          format: ArtworkFormat.JPEG,
          size: 200,
          quality: 50,
        );

        if (artwork != null && artwork.isNotEmpty) {
          // Cache to disk
          await AppSettings.saveArtwork(song.id, artwork);
          updatedSongs.add(song.copyWith(artworkBytes: Uint8List.fromList(artwork)));
        } else {
          updatedSongs.add(song);
        }
      } catch (e) {
        debugPrint('ArtworkExtractor: failed for song ${song.id}: $e');
        updatedSongs.add(song);
      }
    }

    debugPrint('ArtworkExtractor (Android): populated artwork for '
        '${updatedSongs.where((s) => s.artworkBytes != null).length}/${updatedSongs.length} songs');
    return updatedSongs;
  }

  // -----------------------------------------------------------------------
  // Desktop path — extract APIC from MP3 files using id3 package
  // -----------------------------------------------------------------------

  static Future<List<Song>> _extractDesktop(List<Song> songs) async {
      final updatedSongs = <Song>[];

      for (int i = 0; i < songs.length; i++) {
        final song = songs[i];

        // Yield to event loop every 10 songs so UI stays responsive
        if (i % 10 == 0 && i > 0) {
          await Future<void>.delayed(Duration.zero);
        }

        // Check cache first
        if (await AppSettings.hasArtwork(song.id)) {
          final cached = await AppSettings.loadArtwork(song.id);
          if (cached != null && cached.isNotEmpty) {
            updatedSongs.add(song.copyWith(artworkBytes: Uint8List.fromList(cached)));
            continue;
          }
        }

        // Only MP3 files have ID3 tags we can parse with the id3 package
        final ext = song.uri.split('.').last.toLowerCase();
        if (ext != 'mp3') {
          updatedSongs.add(song);
          continue;
        }

        try {
          final file = File(song.uri);
          if (!await file.exists()) {
            updatedSongs.add(song);
            continue;
          }

          // Parse ID3 tags with a per-song timeout (5s max) to prevent hangs
          final artworkBytes = await _extractArtworkFromMP3(file).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              debugPrint('ArtworkExtractor: timeout for ${song.uri}');
              return null;
            },
          );

          if (artworkBytes != null) {
            await AppSettings.saveArtwork(song.id, artworkBytes);
            updatedSongs.add(song.copyWith(artworkBytes: Uint8List.fromList(artworkBytes)));
          } else {
            updatedSongs.add(song);
          }
        } catch (e) {
          debugPrint('ArtworkExtractor: failed for song ${song.id} (${song.uri}): $e');
          updatedSongs.add(song);
        }
      }

      debugPrint('ArtworkExtractor (Desktop): populated artwork for '
          '${updatedSongs.where((s) => s.artworkBytes != null).length}/${updatedSongs.length} songs');
      return updatedSongs;
    }

    /// Extract artwork from an MP3 file asynchronously using compute (isolate).
    static Future<List<int>?> _extractArtworkFromMP3(File file) async {
      try {
        final bytes = await _readFileWithLimit(file, 1 * 1024 * 1024);

        // Run ID3 parsing in an isolate to avoid blocking the main thread
        return compute(_parseId3Artwork, bytes);
      } catch (_) {
        return null;
      }
    }

    /// Isolate callback — parse ID3 tags and extract APIC artwork.
    static List<int>? _parseId3Artwork(List<int> bytes) {
      try {
        final mp3Instance = id3_lib.MP3Instance(bytes);
        final parsed = mp3Instance.parseTagsSync();

        if (!parsed) return null;

        final metaTags = mp3Instance.getMetaTags();
        final apicData = metaTags?['APIC'];

        if (apicData is Map<String, dynamic>) {
          final base64Str = apicData['base64'] as String?;
          if (base64Str != null && base64Str.isNotEmpty) {
            return base64Decode(base64Str);
          }
        }
      } catch (_) {}

      return null;
    }

  /// Read file bytes with a size limit to avoid loading entire large files.
  static Future<List<int>> _readFileWithLimit(File file, int maxBytes) async {
    final length = await file.length();
    final readLength = length < maxBytes ? length : maxBytes;
    return file.readAsBytesSync().take(readLength).toList();
  }

  /// Re-extract artwork for a single song (e.g. after enabling the feature).
  static Future<Song?> extractForSong(Song song) async {
    final showArt = await AppSettings.loadShowAlbumArt();
    if (!showArt) return null;

    if (Platform.isAndroid) {
      return _extractSingleAndroid(song);
    } else {
      return _extractSingleDesktop(song);
    }
  }

  static Future<Song> _extractSingleAndroid(Song song) async {
    // Check cache first
    if (await AppSettings.hasArtwork(song.id)) {
      final cached = await AppSettings.loadArtwork(song.id);
      if (cached != null && cached.isNotEmpty) {
        return song.copyWith(artworkBytes: Uint8List.fromList(cached));
      }
    }

    try {
      final audioQuery = OnAudioQuery();
      final artwork = await audioQuery.queryArtwork(
        song.id,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: 200,
        quality: 50,
      );

      if (artwork != null && artwork.isNotEmpty) {
        await AppSettings.saveArtwork(song.id, artwork);
        return song.copyWith(artworkBytes: Uint8List.fromList(artwork));
      }
    } catch (e) {
      debugPrint('ArtworkExtractor: single extract failed for ${song.id}: $e');
    }

    return song;
  }

  static Future<Song> _extractSingleDesktop(Song song) async {
      // Check cache first
      if (await AppSettings.hasArtwork(song.id)) {
        final cached = await AppSettings.loadArtwork(song.id);
        if (cached != null && cached.isNotEmpty) {
          return song.copyWith(artworkBytes: Uint8List.fromList(cached));
        }
      }

      final ext = song.uri.split('.').last.toLowerCase();
      if (ext != 'mp3') return song;

      try {
        final file = File(song.uri);
        if (!await file.exists()) return song;

        // Use async isolate-based extraction with timeout
        final artworkBytes = await _extractArtworkFromMP3(file).timeout(
          const Duration(seconds: 5),
          onTimeout: () => null,
        );

        if (artworkBytes != null) {
          await AppSettings.saveArtwork(song.id, artworkBytes);
          return song.copyWith(artworkBytes: Uint8List.fromList(artworkBytes));
        }
      } catch (e) {
        debugPrint('ArtworkExtractor: single desktop extract failed for ${song.id}: $e');
      }

      return song;
      }
      }
