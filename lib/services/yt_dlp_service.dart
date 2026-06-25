/// yt-dlp integration for streaming URL resolution.
///
/// Supports YouTube and SoundCloud by invoking yt-dlp CLI to extract
/// playable stream URLs from video/track pages.
library;

import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import '../models/song.dart';

/// Service for resolving streaming URLs via yt-dlp.
///
/// This uses the system's yt-dlp installation to extract audio stream URLs
/// from YouTube and SoundCloud. Requires yt-dlp to be installed on the system.
class YtDlpService {
  static final YtDlpService _instance = YtDlpService._internal();
  factory YtDlpService() => _instance;
  YtDlpService._internal();

  /// Path to yt-dlp executable (detected automatically or configurable).
  String? _ytDlpPath;

  /// Initialize and verify yt-dlp is available.
  Future<bool> init() async {
    try {
      // Try common paths for yt-dlp
      final candidates = [
        'yt-dlp',                    // In PATH
        'yt_dlp',                    // Alternative name on some systems
        '/usr/local/bin/yt-dlp',     // macOS/Linux default
        '/usr/bin/yt-dlp',           // Linux package install
        r'C:\ProgramData\chocolatey\bin\yt-dlp.exe', // Windows choco
        r'C:\yt-dlp.exe',            // Windows manual install
      ];

      for (final path in candidates) {
        try {
          final result = await Process.run(path, ['--version']);
          if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
            _ytDlpPath = path;
            return true;
          }
        } catch (_) {
          continue; // Try next candidate
        }
      }

      return false;
    } catch (e) {
      debugPrint('YtDlpService init error: $e');
      return false;
    }
  }

  /// Check if yt-dlp is available.
  bool get isAvailable => _ytDlpPath != null;

  /// Extract audio stream URL from a YouTube or SoundCloud page URL.
  ///
  /// Returns the direct HTTPS stream URL that can be played with mpv_audio_kit,
  /// or null if extraction fails.
  Future<String?> resolveStreamUrl(String url) async {
    if (!isAvailable) return null;

    try {
      // Extract best audio-only format using yt-dlp
      final result = await Process.run(
        _ytDlpPath!,
        [
          '--no-playlist',           // Single video only
          '-f', 'ba',                // Best audio format
          '--print', 'url',          // Print just the URL
          '--no-warnings',           // Suppress warnings in output
          '--no-check-certificate',  // Skip SSL verification (some CDNs)
          url,
        ],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        final urlString = result.stdout.toString().trim();
        if (urlString.isNotEmpty && urlString.startsWith('http')) {
          return urlString;
        }
      } else {
        debugPrint('yt-dlp error for $url: ${result.stderr}');
      }

      return null;
    } catch (e) {
      debugPrint('Exception resolving URL with yt-dlp: $e');
      return null;
    }
  }

  /// Extract metadata from a YouTube or SoundCloud page.
  ///
  /// Returns JSON with title, artist, duration, etc. as provided by yt-dlp.
  Future<Map<String, dynamic>?> extractMetadata(String url) async {
    if (!isAvailable) return null;

    try {
      final result = await Process.run(
        _ytDlpPath!,
        [
          '--no-playlist',
          '--dump-json',
          '--no-warnings',
          '--no-check-certificate',
          url,
        ],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        final jsonStr = result.stdout.toString().trim();
        if (jsonStr.isNotEmpty) {
          return jsonDecode(jsonStr) as Map<String, dynamic>;
        }
      }

      return null;
    } catch (e) {
      debugPrint('Exception extracting metadata: $e');
      return null;
    }
  }

  /// Convert yt-dlp metadata JSON to a Song object.
  Song _metadataToSong(Map<String, dynamic> meta, StreamSource source) {
    final rawId = meta['id'];
    final id = rawId is int ? rawId : int.tryParse(rawId.toString()) ?? DateTime.now().millisecondsSinceEpoch;
    final title = (meta['title'] as String?) ?? 'Unknown Title';
    final artist = meta['uploader'] ?? meta['artist'] ?? meta['channel'];
    final durationMs = ((meta['duration'] as num?)?.toInt() ?? 0) * 1000;

    return Song(
      id: id,
      title: title,
      artist: artist as String?,
      album: meta['album'] as String?,
      duration: durationMs > 0 ? durationMs : 180000, // Default 3 min if unknown
      uri: '', // Stream URL resolved separately via resolveStreamUrl()
      streamSource: source,
    );
  }

  /// Search YouTube for tracks matching a query.
  ///
  /// Returns list of Song objects with metadata but empty URIs.
  /// Call [resolveStreamUrl] on each result's original URL to get playable streams.
  Future<List<Song>> searchYouTube(String query, {int limit = 9}) async {
    if (!isAvailable) return [];

    try {
      // Use yt-dlp's built-in search (ytsearch:N: prefix)
      final searchUrl = 'ytsearch$limit:$query';

      final result = await Process.run(
        _ytDlpPath!,
        [
          '--dump-json',
          '--no-playlist',
          '--flat-playlist',     // Search results without downloading
          '--no-warnings',
          searchUrl,
        ],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        final lines = result.stdout.toString().trim().split('\n');
        final songs = <Song>[];

        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final meta = jsonDecode(line) as Map<String, dynamic>;
            final originalUrl = 'https://youtube.com/watch?v=${meta['id']}';
            final song = _metadataToSong(meta, StreamSource.youtube);

            // Store the original URL in uri for later resolution
            songs.add(song.copyWith(uri: originalUrl));
          } catch (_) {
            continue; // Skip malformed entries
          }
        }

        return songs;
      }

      return [];
    } catch (e) {
      debugPrint('YouTube search error: $e');
      return [];
    }
  }

  /// Search SoundCloud for tracks matching a query.
  ///
  /// Note: SoundCloud search via yt-dlp requires special handling due to API changes.
  Future<List<Song>> searchSoundCloud(String query, {int limit = 9}) async {
    if (!isAvailable) return [];

    try {
      // Use yt-dlp's SoundCloud search support
      final searchUrl = 'scsearch$limit:$query';

      final result = await Process.run(
        _ytDlpPath!,
        [
          '--dump-json',
          '--no-playlist',
          '--flat-playlist',
          '--no-warnings',
          '--no-check-certificate',
          searchUrl,
        ],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        final lines = result.stdout.toString().trim().split('\n');
        final songs = <Song>[];

        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final meta = jsonDecode(line) as Map<String, dynamic>;
            final song = _metadataToSong(meta, StreamSource.soundcloud);

            // Store original URL for later resolution
            final scUrl = meta['webpage_url'] ?? '';
            songs.add(song.copyWith(uri: scUrl));
          } catch (_) {
            continue;
          }
        }

        return songs;
      }

      return [];
    } catch (e) {
      debugPrint('SoundCloud search error: $e');
      return [];
    }
  }

  /// Get random/trending tracks from SoundCloud.
  ///
  /// Uses randomized search queries to get variety instead of the same results each time.
  Future<List<Song>> getRandomSoundcloudTracks(int count, {String? genre}) async {
    if (!isAvailable) return [];

    try {
      // Use randomized queries for variety — yt-dlp search is deterministic so we randomize the query
      final rng = math.Random();
      final genres = [
        'electronic', 'lofi hip hop', 'ambient', 'jazz', 'rock', 'indie',
        'chill beats', 'synthwave', 'house music', 'drum and bass',
        'classical crossover', 'funk', 'soul', 'rnb', 'pop instrumental',
        'dubstep', 'trance', 'techno', 'folk acoustic', 'jazz fusion',
      ];
      final query;
      if (genre != null && genre.isNotEmpty) {
        query = '$genre';
      } else {
        // Pick a random genre and add variety suffixes
        final pickedGenre = genres[rng.nextInt(genres.length)];
        final suffixes = ['mix', 'remix', 'cover', 'live session', 'original', 'beat', 'vibes'];
        final suffix = suffixes[rng.nextInt(suffixes.length)];
        query = '$pickedGenre $suffix';
      }

      final result = await Process.run(
        _ytDlpPath!,
        [
          '--dump-json',
          '--no-playlist',
          '--flat-playlist',
          '--no-warnings',
          'scsearch${count * 3}:$query',
        ],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        final lines = result.stdout.toString().trim().split('\n');
        final songs = <Song>[];

        for (final line in lines.take(count)) {
          if (line.trim().isEmpty) continue;
          try {
            final meta = jsonDecode(line) as Map<String, dynamic>;
            final song = _metadataToSong(meta, StreamSource.soundcloud);
            final scUrl = meta['webpage_url'] ?? '';
            songs.add(song.copyWith(uri: scUrl));
          } catch (_) {
            continue;
          }
        }

        // Shuffle client-side for true randomness
        final rng2 = math.Random();
        songs.shuffle(rng2);
        return songs.take(count).toList();
      }

      return [];
    } catch (e) {
      debugPrint('SoundCloud trending error: $e');
      return [];
    }
  }

  /// Get random/trending tracks from YouTube.
  Future<List<Song>> getRandomYouTubeTracks(int count, {String? genre}) async {
    if (!isAvailable) return [];

    try {
      // Use randomized queries for variety — yt-dlp search is deterministic so we randomize the query
      final rng = math.Random();
      final genres = [
        'electronic', 'lofi hip hop', 'ambient', 'jazz', 'rock', 'indie',
        'chill beats', 'synthwave', 'house music', 'drum and bass',
        'classical crossover', 'funk', 'soul', 'rnb', 'pop instrumental',
        'dubstep', 'trance', 'techno', 'folk acoustic', 'jazz fusion',
      ];
      final query;
      if (genre != null && genre.isNotEmpty) {
        query = '$genre music';
      } else {
        // Pick a random genre and add variety suffixes
        final pickedGenre = genres[rng.nextInt(genres.length)];
        final suffixes = ['mix', 'remix', 'cover', 'live session', 'original', 'beat', 'vibes'];
        final suffix = suffixes[rng.nextInt(suffixes.length)];
        query = '$pickedGenre $suffix';
      }

      // Fetch more results than needed, then shuffle client-side for true randomness
      final allTracks = await searchYouTube(query, limit: count * 3);
      if (allTracks.isEmpty) return [];
      
      // Shuffle and take the requested count
      final shuffled = List<Song>.from(allTracks)..shuffle(rng);
      return shuffled.take(count).toList();
    } catch (e) {
      debugPrint('YouTube trending error: $e');
      return [];
    }
  }
}
