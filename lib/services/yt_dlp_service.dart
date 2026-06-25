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

  /// Always available — no external binary needed.
  bool get isAvailable => true;

  /// No-op init (no binary to detect).
  Future<bool> init() async => true;

  /// Resolve a stream URL from a webpage URL using the appropriate package.
  Future<String?> resolveStreamUrl(String uri) async {
    try {
      if (uri.contains('youtube.com') || uri.contains('youtu.be')) {
        return _resolveYouTube(uri);
      } else if (uri.contains('soundcloud.com')) {
        return _resolveSoundCloud(uri);
      }
      debugPrint('YtDlpService.resolveStreamUrl: unsupported URL $uri');
      return null;
    } catch (e) {
      debugPrint('YtDlpService.resolveStreamUrl error: $e');
      return null;
    }
  }

  /// Resolve a YouTube video to its best audio stream URL.
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

      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final audioStream = manifest.audioOnly.withHighestBitrate();
      return audioStream.url.toString();
    } catch (e) {
      debugPrint('YtDlpService._resolveYouTube error: $e');
      return null;
    } finally {
      yt.close();
    }
  }

  /// Resolve a SoundCloud track to its direct stream URL.
  Future<String?> _resolveSoundCloud(String uri) async {
    final client = SoundcloudClient();
    try {
      final track = await client.tracks.getByUrl(uri);
      final streams = await client.tracks.getStreams(track.id);
      for (final stream in streams) {
        if (!stream.isSnipped) {
          return stream.url;
        }
      }
      if (streams.isNotEmpty) return streams.first.url;
      return null;
    } catch (e) {
      debugPrint('YtDlpService._resolveSoundCloud error: $e');
      return null;
    } finally {
    }
  }

  /// Search YouTube for tracks matching a query.
  Future<List<Song>> searchYouTube(String query, {int limit = 9}) async {
    final yt = YoutubeExplode();
    final songs = <Song>[];
    try {
      final results = await yt.search.search(query);
      var count = 0;
      for (final video in results) {
        if (count >= limit) break;
        final uri = 'https://www.youtube.com/watch?v=${video.id.value}';
        songs.add(Song(
          id: _hash(uri),
          title: video.title,
          artist: video.author.isNotEmpty ? video.author : null,
          duration: video.duration != null ? (video.duration!.inMilliseconds) : 0,
          uri: uri,
          streamSource: StreamSource.youtube,
        ));
        count++;
      }
    } catch (e) {
      debugPrint('YtDlpService.searchYouTube error: $e');
    } finally {
      yt.close();
    }
    return songs;
  }

  /// Search SoundCloud for tracks matching a query.
  Future<List<Song>> searchSoundCloud(String query, {int limit = 9}) async {
    final client = SoundcloudClient();
    final songs = <Song>[];
    try {
      var count = 0;
      await for (final batch in client.search.getTracks(query, limit: limit)) {
        for (final result in batch) {
          if (count >= limit) break;
          final uri = result.permalinkUrl.toString();
            songs.add(Song(
              id: _hash(uri),
              title: result.title,
              artist: result.user.username.isNotEmpty ? result.user.username : null,
              duration: result.duration > 0 ? (result.duration * 1000).toInt() : 0,
              uri: uri,
              streamSource: StreamSource.soundcloud,
            ));
            count++;
        }
        if (count >= limit) break;
      }
    } catch (e) {
      debugPrint('YtDlpService.searchSoundCloud error: $e');
    } finally {
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
      final artists = [
        'Flume', 'ODESZA', 'Tame Impala', 'Bonobo', 'Tycho',
        'Khruangbin', 'FKJ', 'Jamie xx', 'Caribou', 'Four Tet',
        'Disclosure', 'Rüfüs Du Sol', 'Peggy Gou', 'Nujabes', 'Umi',
        'Emancipator', 'Kiasmos', 'Amon Tobin', 'Floating Points', 'Hudson Mohawke',
      ];
      final suffixes = ['mix', 'remix', 'cover', 'live session', 'original', 'beat', 'vibes'];

      final query;
      if (genre != null && genre.isNotEmpty) {
        final suffix = suffixes[rng.nextInt(suffixes.length)];
        query = '$genre $suffix';
      } else {
        // 60% genre-based, 40% artist-based for variety
        if (rng.nextDouble() < 0.6) {
          final pickedGenre = genres[rng.nextInt(genres.length)];
          final suffix = suffixes[rng.nextInt(suffixes.length)];
          query = '$pickedGenre $suffix';
        } else {
          final pickedArtist = artists[rng.nextInt(artists.length)];
          query = '$pickedArtist';
        }
      }

      debugPrint('SoundCloud shuffle query: $query');

      // Fetch 3x results, then shuffle client-side for true randomness
      final allTracks = await searchSoundCloud(query, limit: count * 3);
      if (allTracks.isEmpty) return [];

      final shuffled = List<Song>.from(allTracks)..shuffle(rng);
      return shuffled.take(count).toList();
    } catch (e) {
      debugPrint('SoundCloud trending error: $e');
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
      final query;
      if (genre != null && genre.isNotEmpty) {
        query = '$genre music';
      } else {
        final pickedGenre = genres[rng.nextInt(genres.length)];
        final suffixes = ['mix', 'remix', 'cover', 'live session', 'original', 'beat', 'vibes'];
        final suffix = suffixes[rng.nextInt(suffixes.length)];
        query = '$pickedGenre $suffix';
      }

      // Fetch more results than needed, then shuffle client-side for true randomness
      final allTracks = await searchYouTube(query, limit: count * 3);
      if (allTracks.isEmpty) return [];

      final shuffled = List<Song>.from(allTracks)..shuffle(rng);
      return shuffled.take(count).toList();
    } catch (e) {
      debugPrint('YouTube trending error: $e');
      return [];
    }
  }

  int _hash(String s) => s.hashCode.abs() + DateTime.now().millisecondsSinceEpoch;
}
