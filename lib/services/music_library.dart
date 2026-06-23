/// Music library service — queries device music (Android) or scans folders (desktop).
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../models/song.dart';
import 'music_scanner.dart' as desktop_scanner;
import 'app_settings.dart';
import 'artwork_extractor.dart';


class MusicLibrary {
  late final OnAudioQuery _audioQuery;

  MusicLibrary() : _audioQuery = OnAudioQuery();


  // ---- Android (on_audio_query) ---

  /// Check if storage/audio permission is granted (Android only).
  Future<bool> hasPermission() async {
    return await _audioQuery.permissionsStatus();
  }

  /// Request storage/audio permission from the user (Android only).
  /// On desktop this always returns true (no permissions needed).
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) {
      // Desktop: no runtime permissions required for file access.
      return true;
    }
    final result = await _audioQuery.permissionsRequest();
    debugPrint('MusicLibrary: permission result = $result');
    return result;
  }

  // ---- Unified init (Android + Desktop) ----

 /// Initialize and load all songs.
   /// - Android: queries MediaStore via on_audio_query.
   /// - Desktop: scans user-configured music folders via dart:io + ID3 parsing.
   ///
   /// If a rescan flag was set (from settings toggle or manual rescan), does a
   /// full artwork extraction. Otherwise loads cached thumbnails only (fast).
   Future<List<Song>> init() async {
     List<Song> songs;
     if (Platform.isAndroid) {
       songs = await _initAndroid();
     } else {
       songs = await _initDesktop();
     }

     // Check if a full artwork rescan was requested
     final needsRescan = await AppSettings.consumeRescanFlag();
     final showArt = await AppSettings.loadShowAlbumArt();

     if (showArt) {
       if (needsRescan) {
         // Full extraction — skips songs that already have cached thumbnails
         return ArtworkExtractor.extractForSongs(songs);
       } else {
         // Fast path: load cached thumbnails only
         return ArtworkExtractor.loadCachedForSongs(songs);
       }
     }

     return songs;
   }

  /// Android path — query MediaStore.
  Future<List<Song>> _initAndroid() async {
    final List<SongModel> songModels = await _audioQuery.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
    );

    final songs = songModels.map((sm) => Song.fromSongModel(sm)).toList();
    debugPrint('MusicLibrary (Android): loaded ${songs.length} songs');
    return songs;
  }

  /// Desktop path — scan configured music folders.
  Future<List<Song>> _initDesktop() async {
    final folders = await AppSettings.loadMusicFolders();
    
    if (folders.isEmpty) {
      debugPrint('MusicLibrary (Desktop): no music folders configured');
      return [];
    }

    // Wrap the entire scan in a timeout so even if something goes wrong,
    // the app doesn't hang at startup. Total budget: 60s + 5s per folder.
    final totalTimeout = Duration(seconds: 60 + (folders.length * 30));
    try {
      final songs = await desktop_scanner.scanMusicFolders(folders).timeout(totalTimeout);
      debugPrint('MusicLibrary (Desktop): loaded ${songs.length} songs');
      return songs;
    } on TimeoutException {
      debugPrint('MusicLibrary (Desktop): scan exceeded total timeout (${totalTimeout.inSeconds}s) for ${folders.length} folder(s)');
      return [];
    }
  }

  // ---- Search ---

   /// Search songs by query string.
   Future<List<Song>> search(String query) async {
     if (query.isEmpty) {
       return [];
     }
     final allSongs = await init();
     final lower = query.toLowerCase();
     return allSongs.where((song) {
       return song.title.toLowerCase().contains(lower) ||
           (song.artist != null && song.artist!.toLowerCase().contains(lower)) ||
           (song.album != null && song.album!.toLowerCase().contains(lower));
     }).toList();
   }

  /// Check if music folders are configured (desktop only).
  /// Returns true on Android regardless.
  Future<bool> hasMusicFolders() async {
    if (Platform.isAndroid) return true;
    final folders = await AppSettings.loadMusicFolders();
    return folders.isNotEmpty;
  }

  /// Re-scan music folders and return updated song list (desktop only).
  /// On Android this is equivalent to [init].
  Future<List<Song>> rescan() async {
    return init();
  }
}
