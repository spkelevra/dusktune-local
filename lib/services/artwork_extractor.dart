library;

/// Album artwork extractor — platform-specific implementation.
/// 
/// On Android, uses on_audio_query to fetch artwork from MediaStore.
/// On desktop, extracts embedded APIC frames from MP3 files via the id3 package.
/// Results are cached to disk for fast subsequent loads.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';
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

  /// Extract artwork into memory only — no disk caching.
  /// Used for shuffle/mix grids where we want instant display without persistent storage.
  static Future<List<Song>> extractForSongsInMemory(List<Song> songs) async {
    if (songs.isEmpty) return songs;

    debugPrint('ArtworkExtractor: extracting in-memory for ${songs.length} songs');

    // Use mpv native extraction for all platforms when cacheToDisk is false
    // This is significantly faster than Dart-side ID3 parsing or MediaStore queries
    final extracted = await _extractViaMpv(songs);
    
    if (extracted != null) {
      return extracted;
    }

    // Fallback to platform-specific extraction if mpv fails
    if (Platform.isAndroid) {
      return _extractAndroid(songs, cacheToDisk: false);
    } else {
      return _extractDesktop(songs, cacheToDisk: false);
    }
  }

  /// Extract artwork using mpv_audio_kit's native C-level tag reader.
  /// Much faster than Dart-side parsing — works for all formats mpv supports.
  static Future<List<Song>?> _extractViaMpv(List<Song> songs) async {
    try {
      final player = Player(); // bare constructor — no autoPlay
      
      final updatedSongs = <Song>[];
      
      for (final song in songs) {
        try {
          // Open file without playing to extract metadata
          await player.open(Media(song.uri), play: false);
          
          // Wait for coverArt stream emission with timeout
          final completer = Completer<CoverArt?>();
          final subscription = player.stream.coverArt.listen((coverArt) {
            if (!completer.isCompleted) {
              completer.complete(coverArt);
            }
          });
          
          final coverArt = await completer.future.timeout(
            const Duration(seconds: 3),
            onTimeout: () => null,
          );
          
          // Cancel subscription to free resources
          await subscription.cancel();
          
          if (coverArt != null && coverArt.bytes.isNotEmpty) {
            updatedSongs.add(song.copyWith(artworkBytes: Uint8List.fromList(coverArt.bytes)));
          } else {
            updatedSongs.add(song);
          }
        } catch (e) {
          debugPrint('ArtworkExtractor mpv: failed for song ${song.id}: $e');
          updatedSongs.add(song);
        }
      }
      
      // Close player to release resources
      await player.dispose();
      
      final populated = updatedSongs.where((s) => s.artworkBytes != null).length;
      debugPrint('ArtworkExtractor (mpv): populated artwork for $populated/${updatedSongs.length} songs');
      
      return updatedSongs;
    } catch (e) {
      debugPrint('ArtworkExtractor mpv: extraction failed, falling back to platform-specific: $e');
      return null; // Return null to trigger fallback
    }
  }

  // -----------------------------------------------------------------------
  // Android path — use on_audio_query MediaStore API
  // -----------------------------------------------------------------------

  static Future<List<Song>> _extractAndroid(List<Song> songs, {bool cacheToDisk = true}) async {
    final audioQuery = OnAudioQuery();
    final updatedSongs = <Song>[];

    for (final song in songs) {
      // Check cache first if caching is enabled
      if (cacheToDisk && await AppSettings.hasArtwork(song.id)) {
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
          // Cache to disk only if requested
          if (cacheToDisk) {
            await AppSettings.saveArtwork(song.id, artwork);
          }
          updatedSongs.add(song.copyWith(artworkBytes: Uint8List.fromList(artwork)));
        } else {
          updatedSongs.add(song);
        }
      } catch (e) {
        debugPrint('ArtworkExtractor: failed for song ${song.id}: $e');
        updatedSongs.add(song);
      }
    }

    final populated = updatedSongs.where((s) => s.artworkBytes != null).length;
    final cacheMode = cacheToDisk ? 'cached' : 'in-memory';
    debugPrint('ArtworkExtractor ($cacheMode): populated artwork for $populated/${updatedSongs.length} songs');
    return updatedSongs;
  }

  // -----------------------------------------------------------------------
  // Desktop path — extract APIC from MP3 files using id3 package
  // -----------------------------------------------------------------------

  static Future<List<Song>> _extractDesktop(List<Song> songs, {bool cacheToDisk = true}) async {
      final updatedSongs = <Song>[];

      for (int i = 0; i < songs.length; i++) {
        final song = songs[i];

        // Yield to event loop every 10 songs so UI stays responsive
        if (i % 10 == 0 && i > 0) {
          await Future<void>.delayed(Duration.zero);
        }

        // Check cache first if caching is enabled
        if (cacheToDisk && await AppSettings.hasArtwork(song.id)) {
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
            // Cache to disk only if requested
            if (cacheToDisk) {
              await AppSettings.saveArtwork(song.id, artworkBytes);
            }
            updatedSongs.add(song.copyWith(artworkBytes: Uint8List.fromList(artworkBytes)));
          } else {
            updatedSongs.add(song);
          }
        } catch (e) {
          debugPrint('ArtworkExtractor: failed for song ${song.id} (${song.uri}): $e');
          updatedSongs.add(song);
        }
      }

      final populated = updatedSongs.where((s) => s.artworkBytes != null).length;
      final cacheMode = cacheToDisk ? 'cached' : 'in-memory';
      debugPrint('ArtworkExtractor ($cacheMode): populated artwork for $populated/${updatedSongs.length} songs');
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
      } catch (e) { debugPrint("ArtworkExtractor ID3 parse error (ignored): $e"); }

      return null;
    }

  /// Read file bytes with a size limit to avoid loading entire large files.
  static Future<List<int>> _readFileWithLimit(File file, int maxBytes) async {
    final length = await file.length();
    final readLength = length < maxBytes ? length : maxBytes;
    return file.readAsBytesSync().take(readLength).toList();
  }

}
