library;

/// Song data model for dusktune.

import 'dart:typed_data';
import 'package:on_audio_query/on_audio_query.dart';

/// Source of the song — local file or streaming service.
enum StreamSource {
  local,      // Local file (content:// or file://)
  soundcloud, // SoundCloud stream
  youtube,    // YouTube stream
}

class Song {
  final int id;
  final String title;
  final String? artist;
  final String? album;
  final int duration;       // Duration in milliseconds
  final String uri;         // Content URI, file path, or streaming URL
  final Uint8List? artworkBytes; // Cached album art thumbnail (JPEG)
  final String? thumbnailUrl;     // Remote thumbnail URL for streaming sources
  final StreamSource streamSource; // Source type (local vs streaming)

  const Song({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    required this.duration,
    required this.uri,
    this.artworkBytes,
    this.thumbnailUrl,
    this.streamSource = StreamSource.local,
  });

  /// Alias for [duration] in milliseconds — used by UI widgets.
  int get durationMs => duration;

  /// Display-friendly duration string (e.g. "3:45").
  String get formattedDuration {
    final seconds = (duration ~/ 1000);
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  /// Display name: "Title — Artist".
  String get displayName => artist != null && artist!.isNotEmpty
      ? '$title — $artist'
      : title;

  /// Create a [Song] from an [on_audio_query] SongModel entry (Android).
   factory Song.fromSongModel(SongModel songModel) {
     return Song(
       id: songModel.id,
       title: songModel.title,
       artist: songModel.artist,
       album: songModel.album,
       duration: songModel.duration ?? 0,
       uri: songModel.data,
       streamSource: StreamSource.local,
     );
   }

   /// Create a [Song] from a map of metadata (desktop scanner).
   factory Song.fromMap({
     required int id,
     required String title,
     String? artist,
     String? album,
     int duration = 0,
     required String uri,
     Uint8List? artworkBytes,
     String? thumbnailUrl,
   }) {
     return Song(
       id: id,
       title: title,
       artist: artist,
       album: album,
       duration: duration,
       uri: uri,
       artworkBytes: artworkBytes,
       thumbnailUrl: thumbnailUrl,
       streamSource: StreamSource.local,
     );
   }

   /// Create a copy of this song with updated fields.
   /// Uses sentinel defaults to distinguish 'not passed' from 'explicitly null'.
   Song copyWith({
     dynamic id,
     dynamic title,
     dynamic artist,
     dynamic album,
     dynamic duration,
     dynamic uri,
     dynamic artworkBytes,
     dynamic thumbnailUrl,
     dynamic streamSource,
     bool clearArtwork = false,
   }) {
     // Determine which fields were actually passed by checking against
     // the original values. If a field matches the original AND wasn't
     // explicitly requested to be cleared, keep the original.
     //
     // For nullable fields (artworkBytes, thumbnailUrl, artist, album, streamSource),
     // we use the [clearArtwork] flag and explicit non-null checks.
     return Song(
       id: id != null ? id as int : this.id,
       title: title != null ? title as String : this.title,
       artist: artist != null ? artist as String? : this.artist,
       album: album != null ? album as String? : this.album,
       duration: duration != null ? duration as int : this.duration,
       uri: uri != null ? uri as String : this.uri,
       artworkBytes: clearArtwork ? null : (artworkBytes != null ? artworkBytes as Uint8List? : this.artworkBytes),
       thumbnailUrl: thumbnailUrl != null ? thumbnailUrl as String? : this.thumbnailUrl,
       streamSource: streamSource != null ? streamSource as StreamSource : this.streamSource,
     );
   }

   Map<String, dynamic> toJson() => {
         'id': id,
         'title': title,
         'artist': artist,
         'album': album,
         'duration': duration,
         'uri': uri,
         'thumbnailUrl': thumbnailUrl,
         'streamSource': streamSource.name,
       };

   factory Song.fromJson(Map<String, dynamic> json) => Song(
         id: json['id'] as int,
         title: json['title'] as String,
         artist: json['artist'] as String?,
         album: json['album'] as String?,
         duration: json['duration'] as int,
         uri: json['uri'] as String,
         streamSource: json['streamSource'] != null 
             ? StreamSource.values.firstWhere((e) => e.name == json['streamSource'])
             : StreamSource.local,
       );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Song && id == other.id;

  /// Returns a thumbnail URL for streaming sources computed from the URI.
  /// YouTube: deterministic CDN URL from videoId — no network call needed to discover it.
  /// SoundCloud: null (would need API call, not worth caching).
  String? get effectiveThumbnailUrl {
    if (thumbnailUrl != null) return thumbnailUrl;
    // Compute YouTube thumbnail from URI — no caching needed
    if (streamSource == StreamSource.youtube && uri.contains('youtube.com') || uri.contains('youtu.be')) {
      final match = RegExp(r'v=([a-zA-Z0-9_-]+)').firstMatch(uri);
      final videoId = match?.group(1) ?? uri.split('youtu.be/')[1].split('?')[0];
      if (videoId.isNotEmpty) return 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
    }
    return null;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Song(id: $id, title: "$title", artist: "$artist")';
}
