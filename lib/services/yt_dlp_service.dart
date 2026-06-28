/// Native Dart streaming service using youtube_explode_dart + soundcloud_explode_dart.
///
/// Replaces the yt-dlp CLI wrapper — no external binary required on any platform.
library;

import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:soundcloud_explode_dart/soundcloud_explode_dart.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/song.dart';

/// Service for resolving streaming URLs and searching via native Dart packages.
class YtDlpService {
  static final YtDlpService _instance = YtDlpService._internal();
  factory YtDlpService() => _instance;
  YtDlpService._internal();

  // In-memory stream URL cache — no persistent storage, cleared on app close.
  static final _urlCache = <String, String>{};
  static YoutubeExplode? _ytInstance;
  static SoundcloudClient? _scInstance;

  /// Always available — no external binary needed.
  bool get isAvailable => true;

  /// No-op init (no binary to detect).
  Future<bool> init() async => true;

  /// Resolve a stream URL from a webpage URL using the appropriate package.
  Future<String?> resolveStreamUrl(String uri) async {
    debugPrint('YtDlpService.resolveStreamUrl: $uri');
    try {
      if (uri.contains('youtube.com') || uri.contains('youtu.be')) {
        return _resolveYouTube(uri);
      } else if (uri.contains('soundcloud.com')) {
        return _resolveSoundCloud(uri);
      }
      debugPrint('YtDlpService.resolveStreamUrl: unsupported URL $uri');
      return null;
    } catch (e, st) {
      debugPrint('YtDlpService.resolveStreamUrl error: $e\n$st');
      return null;
    }
  }

  /// Resolve a YouTube video to its best playable stream URL.
  /// Tries muxed streams first (less throttled than adaptive audio-only), then falls back.
  Future<String?> _resolveYouTube(String uri) async {
    final yt = YoutubeExplode();
    try {
      String? videoId;
      if (uri.contains('v=')) {
        final match = RegExp(r'v=([a-zA-Z0-9_-]+)').firstMatch(uri);
        videoId = match?.group(1);
      } else if (uri.contains('youtu.be/')) {
        videoId = uri.split('youtu.be/')[1].split('?')[0].split('&')[0];
      }

      if (videoId == null) return null;

      debugPrint('YtDlpService._resolveYouTube: fetching manifest for $videoId');
      final manifest = await yt.videos.streamsClient.getManifest(videoId);

      // Try muxed streams first — they're less aggressively throttled than adaptive audio-only.
      if (manifest.muxed.isNotEmpty) {
        final muxed = manifest.muxed.withHighestBitrate();
        debugPrint('YtDlpService._resolveYouTube: using muxed stream ${muxed.url}');
        return muxed.url.toString();
      }

      // Fallback to audio-only adaptive streams.
      if (manifest.audioOnly.isNotEmpty) {
        final audioStream = manifest.audioOnly.withHighestBitrate();
        debugPrint('YtDlpService._resolveYouTube: using audio-only stream ${audioStream.url}');
        return audioStream.url.toString();
      }

      // Last resort: any available stream.
      if (manifest.streams.isNotEmpty) {
        final fallback = manifest.streams.first;
        debugPrint('YtDlpService._resolveYouTube: using fallback stream ${fallback.url}');
        return fallback.url.toString();
      }

      debugPrint('YtDlpService._resolveYouTube: no streams found for $videoId');
      return null;
    } catch (e, st) {
      debugPrint('YtDlpService._resolveYouTube error: $e\n$st');
      return null;
    } finally {
      yt.close();
    }
  }

  /// Resolve a SoundCloud track to its direct stream URL.
  Future<String?> _resolveSoundCloud(String uri) async {
    // Check cache first — avoids network call entirely on replay
    if (_urlCache.containsKey(uri)) {
      debugPrint('YtDlpService._resolveSoundCloud: using cached URL for $uri');
      return _urlCache[uri];
    }

    final client = _scInstance ??= SoundcloudClient();
    try {
      debugPrint('YtDlpService._resolveSoundCloud: fetching track from $uri');
      final track = await client.tracks.getByUrl(uri);
      debugPrint('YtDlpService._resolveSoundCloud: got track ${track.title} id=${track.id}');
      final streams = await client.tracks.getStreams(track.id);
      for (final stream in streams) {
        if (!stream.isSnipped) {
          debugPrint('YtDlpService._resolveSoundCloud: got non-snipped stream');
          _urlCache[uri] = stream.url!; // Cache for replay
          return stream.url;
        }
      }
      if (streams.isNotEmpty) {
        debugPrint('YtDlpService._resolveSoundCloud: using snipped stream as fallback');
        final url = streams.first.url!;
        _urlCache[uri] = url; // Cache for replay
        return url;
      }
      debugPrint('YtDlpService._resolveSoundCloud: no streams found');
      return null;
    } catch (e, st) {
      debugPrint('YtDlpService._resolveSoundCloud error: $e\n$st');
      return null;
    } finally {
      // Don't close — reused across calls via _scInstance singleton
    }
  }

  /// Search YouTube for tracks matching a query.
  Future<List<Song>> searchYouTube(String query, {int limit = 9}) async {
    debugPrint('YtDlpService.searchYouTube: "$query" (limit=$limit)');
    final yt = _ytInstance ??= YoutubeExplode();
    final songs = <Song>[];
    try {
      final results = await yt.search.search(query);
      debugPrint('YtDlpService.searchYouTube: got ${results.length} raw results');
      var count = 0;
      for (final video in results) {
        if (count >= limit) break;
        final uri = 'https://www.youtube.com/watch?v=${video.id.value}';
        final thumbnailUrl = 'https://img.youtube.com/vi/${video.id.value}/hqdefault.jpg';
        songs.add(Song(
          id: _hash(uri),
          title: video.title,
          artist: video.author.isNotEmpty ? video.author : null,
          duration: video.duration != null ? (video.duration!.inMilliseconds) : 0,
          uri: uri,
          thumbnailUrl: thumbnailUrl,
          streamSource: StreamSource.youtube,
        ));
        count++;
      }
      debugPrint('YtDlpService.searchYouTube: returning ${songs.length} songs');
    } catch (e, st) {
      debugPrint('YtDlpService.searchYouTube error: $e\n$st');
    } finally {
      // Don't close — reused via _ytInstance singleton
    }
    return songs;
  }

  /// Search SoundCloud for tracks matching a query.
  Future<List<Song>> searchSoundCloud(String query, {int limit = 9}) async {
    debugPrint('YtDlpService.searchSoundCloud: "$query" (limit=$limit)');
    final client = _scInstance ??= SoundcloudClient();
    final songs = <Song>[];
    try {
      var count = 0;
      await for (final batch in client.search.getTracks(query, limit: limit)) {
        debugPrint('YtDlpService.searchSoundCloud: got batch of ${batch.length}');
        for (final result in batch) {
          if (count >= limit) break;
          final uri = result.permalinkUrl.toString();
          songs.add(Song(
            id: _hash(uri),
            title: result.title,
            artist: result.user.username.isNotEmpty ? result.user.username : null,
            duration: result.duration > 0 ? (result.duration * 1000).toInt() : 0,
            uri: uri,
            thumbnailUrl: result.artworkUrl?.toString(),
            streamSource: StreamSource.soundcloud,
          ));
          count++;
        }
        if (count >= limit) break;
      }
      debugPrint('YtDlpService.searchSoundCloud: returning ${songs.length} songs');
    } catch (e, st) {
      debugPrint('YtDlpService.searchSoundCloud error: $e\n$st');
    }
    return songs;
  }

  /// Get random/trending tracks from SoundCloud.
  Future<List<Song>> getRandomSoundcloudTracks(int count, {String? genre}) async {
    if (!isAvailable) return [];

    try {
      final rng = math.Random();
      final genres = [
        'electronic', 'lofi hip hop', 'ambient', 'jazz', 'rock', 'indie',
        'chill beats', 'synthwave', 'house music', 'drum and bass',
        'classical crossover', 'funk', 'soul', 'rnb', 'pop instrumental',
        'dubstep', 'trance', 'techno', 'folk acoustic', 'jazz fusion',
      ];
      final moods = [
        'chill', 'upbeat', 'dark', 'dreamy', 'energetic', 'relaxing',
        'melancholic', 'groovy', 'atmospheric', 'minimal',
      ];
      final formats = ['mix', 'remix', 'cover', 'live session', 'original', 'beat', 'vibes'];

      final query;
      if (genre != null && genre.isNotEmpty) {
        final fmt = formats[rng.nextInt(formats.length)];
        query = '$genre $fmt';
      } else {
        // Weighted pool: 40% genre+format, 30% mood-based, 20% genre+mood, 10% trending keywords
        final roll = rng.nextDouble();
        if (roll < 0.4) {
          final pickedGenre = genres[rng.nextInt(genres.length)];
          final fmt = formats[rng.nextInt(formats.length)];
          query = '$pickedGenre $fmt';
        } else if (roll < 0.7) {
          final mood = moods[rng.nextInt(moods.length)];
          query = '$mood music';
        } else if (roll < 0.9) {
          final pickedGenre = genres[rng.nextInt(genres.length)];
          final mood = moods[rng.nextInt(moods.length)];
          query = '$pickedGenre $mood';
        } else {
          final trending = ['trending', 'viral', 'new music', 'discovery', 'underground'];
          query = trending[rng.nextInt(trending.length)];
        }
      }

      debugPrint('SoundCloud shuffle query: "$query"');

      // Fetch 3x results, then shuffle client-side for true randomness
      final allTracks = await searchSoundCloud(query, limit: count * 3);
      if (allTracks.isEmpty) {
        debugPrint('SoundCloud shuffle: no tracks found for "$query"');
        return [];
      }

      final shuffled = List<Song>.from(allTracks)..shuffle(rng);
      return shuffled.take(count).toList();
    } catch (e, st) {
      debugPrint('SoundCloud trending error: $e\n$st');
      return [];
    }
  }

  /// Get random/trending tracks from YouTube.
  Future<List<Song>> getRandomYouTubeTracks(int count, {String? genre}) async {
    if (!isAvailable) return [];

    try {
      final rng = math.Random();
      final genres = [
        'electronic', 'lofi hip hop', 'ambient', 'jazz', 'rock', 'indie',
        'chill beats', 'synthwave', 'house music', 'drum and bass',
        'classical crossover', 'funk', 'soul', 'rnb', 'pop instrumental',
        'dubstep', 'trance', 'techno', 'folk acoustic', 'jazz fusion',
      ];
      final moods = [
        'chill', 'upbeat', 'dark', 'dreamy', 'energetic', 'relaxing',
        'melancholic', 'groovy', 'atmospheric', 'minimal',
      ];
      final formats = ['mix', 'remix', 'cover', 'live session', 'original', 'beat', 'vibes'];

      final query;
      if (genre != null && genre.isNotEmpty) {
        query = '$genre music';
      } else {
        // Weighted pool: 35% genre+format, 25% mood-based, 20% genre+mood, 10% trending, 10% random keywords
        final roll = rng.nextDouble();
        if (roll < 0.35) {
          final pickedGenre = genres[rng.nextInt(genres.length)];
          final fmt = formats[rng.nextInt(formats.length)];
          query = '$pickedGenre $fmt';
        } else if (roll < 0.6) {
          final mood = moods[rng.nextInt(moods.length)];
          query = '$mood music';
        } else if (roll < 0.8) {
          final pickedGenre = genres[rng.nextInt(genres.length)];
          final mood = moods[rng.nextInt(moods.length)];
          query = '$pickedGenre $mood';
        } else if (roll < 0.9) {
          final trending = ['trending', 'viral', 'new music', 'discovery', 'underground'];
          query = trending[rng.nextInt(trending.length)];
        } else {
          // Random keyword combos for maximum variety
          final keywords = ['instrumental', 'acoustic', 'piano', 'guitar', 'synth', 'bass', 'vocal chops', 'experimental'];
          final pickedGenre = genres[rng.nextInt(genres.length)];
          query = '${keywords[rng.nextInt(keywords.length)]} $pickedGenre';
        }
      }

      debugPrint('YouTube shuffle query: "$query"');

      // Fetch more results than needed, then shuffle client-side for true randomness
      final allTracks = await searchYouTube(query, limit: count * 3);
      if (allTracks.isEmpty) {
        debugPrint('YouTube shuffle: no tracks found for "$query"');
        return [];
      }

      final shuffled = List<Song>.from(allTracks)..shuffle(rng);
      return shuffled.take(count).toList();
    } catch (e, st) {
      debugPrint('YouTube trending error: $e\n$st');
      return [];
    }
  }

  int _hash(String s) => s.hashCode.abs() + DateTime.now().millisecondsSinceEpoch;
}
