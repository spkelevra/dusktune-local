/// SoundCloud streaming service.
/// 
/// Provides search and random track fetching using yt-dlp backend.
library;

import 'yt_dlp_service.dart';
import '../models/song.dart';

/// Service for SoundCloud streaming integration.
class SoundCloudService {
  static final SoundCloudService _instance = SoundCloudService._internal();
  factory SoundCloudService() => _instance;
  SoundCloudService._internal();

  final YtDlpService _ytDlp = YtDlpService();

  /// Initialize the service (checks yt-dlp availability).
  Future<bool> init() async {
    return await _ytDlp.init();
  }

  /// Check if streaming is available.
  bool get isAvailable => _ytDlp.isAvailable;

  /// Search for tracks on SoundCloud.
  /// 
  /// Returns list of Song objects with metadata but unresolved stream URLs.
  Future<List<Song>> search(String query, {int limit = 9}) async {
    return await _ytDlp.searchSoundCloud(query, limit: limit);
  }

  /// Get random/trending tracks from SoundCloud.
  Future<List<Song>> getRandomTracks(int count, {String? genre}) async {
    return await _ytDlp.getRandomSoundcloudTracks(count, genre: genre);
  }

  /// Resolve a stream URL from the song's source URL.
  /// 
  /// The [song.uri] field contains the SoundCloud page URL. This method
  /// extracts the actual HTTPS audio stream URL that mpv can play.
  Future<String?> resolveStreamUrl(Song song) async {
    if (song.uri.isEmpty) return null;
    return await _ytDlp.resolveStreamUrl(song.uri);
  }

  /// Resolve stream URLs for multiple songs in parallel.
  Future<List<Song>> resolveStreamUrls(List<Song> songs) async {
    final results = <Song>[];
    
    for (final song in songs) {
      try {
        final streamUrl = await _ytDlp.resolveStreamUrl(song.uri);
        if (streamUrl != null && streamUrl.isNotEmpty) {
          results.add(song.copyWith(uri: streamUrl));
        }
      } catch (_) {
        // Skip songs with unresolved URLs
      }
    }

    return results;
  }
}
