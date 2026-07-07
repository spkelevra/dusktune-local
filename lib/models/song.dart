library;

/// Song data model for dusktune.

import 'dart:typed_data';
import 'package:on_audio_query/on_audio_query.dart';

class Song {
  final int id;
  final String title;
  final String? artist;
  final String? album;
  final int duration;       // Duration in milliseconds
  final String uri;         // Content URI or file path
  final Uint8List? artworkBytes; // Cached album art thumbnail (JPEG)

  const Song({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    required this.duration,
    required this.uri,
    this.artworkBytes,
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
   }) {
     return Song(
       id: id,
       title: title,
       artist: artist,
       album: album,
       duration: duration,
       uri: uri,
       artworkBytes: artworkBytes,
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
     bool clearArtwork = false,
   }) {
     return Song(
       id: id != null ? id as int : this.id,
       title: title != null ? title as String : this.title,
       artist: artist != null ? artist as String? : this.artist,
       album: album != null ? album as String? : this.album,
       duration: duration != null ? duration as int : this.duration,
       uri: uri != null ? uri as String : this.uri,
       artworkBytes: clearArtwork ? null : (artworkBytes != null ? artworkBytes as Uint8List? : this.artworkBytes),
     );
   }

   Map<String, dynamic> toJson() => {
         'id': id,
         'title': title,
         'artist': artist,
         'album': album,
         'duration': duration,
         'uri': uri,
       };

   factory Song.fromJson(Map<String, dynamic> json) => Song(
         id: json['id'] as int,
         title: json['title'] as String,
         artist: json['artist'] as String?,
         album: json['album'] as String?,
         duration: json['duration'] as int,
         uri: json['uri'] as String,
       );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Song && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Song(id: $id, title: "$title", artist: "$artist")';
}
