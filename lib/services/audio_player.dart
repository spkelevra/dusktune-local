/// Audio playback service wrapping [just_audio] + [audio_service].
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import '../models/song.dart';

/// Singleton audio handler that runs in a background isolate.
class DuskAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  /// Track current song for reliable playback.
  // ignore: unused_field
  Song? _currentSong;

  DuskAudioHandler() {
    // Wire up state broadcasting immediately on construction.
    _broadcastState();
    _player.playbackEventStream.listen((_) => _broadcastState());
    _player.processingStateStream.listen((state) {
      debugPrint('DuskAudioHandler processingState: $state');
      _broadcastState();
    });
  }

  void _broadcastState() {
    final playing = _player.playing;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 3],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState] ?? AudioProcessingState.idle,
        playing: playing,
      ),
    );
  }

  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (queue.value.isEmpty) return;
    final mediaItem = queue.value[index];
    await _playMediaItem(mediaItem);
  }

  /// Load and play a [Song] using its file path.
  Future<void> playSong(Song song) async {
    debugPrint('DuskAudioHandler.playSong: ${song.title} uri=${song.uri}');

    final mediaItem = MediaItem(
      id: song.id.toString(),
      title: song.title,
      artist: song.artist ?? 'Unknown Artist',
      album: song.album ?? '',
      duration: Duration(milliseconds: song.durationMs),
      extras: {'uri': song.uri},
    );

    try {
      _currentSong = song;
      // Use AudioSource.file for local files — better codec support (WMA, etc.)
      await _player.setAudioSource(
        AudioSource.file(song.uri, tag: mediaItem),
      );
      this.mediaItem.add(mediaItem);
      queue.value = [mediaItem];
      await play();
      debugPrint('DuskAudioHandler.playSong: success for ${song.title}');
    } catch (e) {
      debugPrint('DuskAudioHandler.playSong FAILED for ${song.title}: $e');
      rethrow;
    }
  }

  Future<void> _playMediaItem(MediaItem mediaItem) async {
    final uriStr = mediaItem.extras?['uri'] as String?;
    if (uriStr != null) {
      await _player.setAudioSource(
        AudioSource.file(uriStr, tag: mediaItem),
      );
    } else {
      debugPrint('_playMediaItem: no URI in extras for ${mediaItem.title}');
      return;
    }
    this.mediaItem.add(mediaItem);
    await play();
  }

  /// Expose the internal [AudioPlayer] for position/duration streams.
  AudioPlayer get player => _player;
}

/// Facade class that the UI interacts with.
class AudioPlayerService {
  static DuskAudioHandler? _handler;

  /// Initialize the audio service (call once in main()).
  static Future<void> init() async {
    _handler = await AudioService.init(
      builder: () => DuskAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.spkelevra.dusktune.channel.audio',
        androidNotificationChannelName: 'DuskTune playback',
        androidShowNotificationBadge: true,
        androidStopForegroundOnPause: false,
      ),
    );
  }

  static DuskAudioHandler? get handler => _handler;

  /// Play a song.
  static Future<void> playSong(Song song) async {
    await _handler?.playSong(song);
  }

  /// Toggle play/pause.
  static Future<void> togglePlayPause() async {
    if (_handler == null) return;
    final state = _handler!.playbackState.value;
    if (state.playing) {
      await pause();
    } else {
      await play();
    }
  }

  /// Play.
  static Future<void> play() async {
    await _handler?.play();
  }

  /// Pause.
  static Future<void> pause() async {
    await _handler?.pause();
  }

  /// Stop playback.
  static Future<void> stop() async {
    await _handler?.stop();
  }

  /// Seek to position.
  static Future<void> seek(Duration position) async {
    await _handler?.seek(position);
  }

  /// Skip to next song in queue.
  static Future<void> skipToNext() async {
    await _handler?.skipToQueueItem(1);
  }

  /// Skip to previous song in queue.
  static Future<void> skipToPrevious() async {
    await _handler?.skipToQueueItem(0);
  }

  /// Current playback state stream.
  static Stream<PlaybackState?> get playbackState {
    return _handler?.playbackState.stream ?? const Stream.empty();
  }

  /// Current position stream from just_audio (if available).
  static Stream<Duration> get positionStream {
    final handler = _handler;
    if (handler != null) {
      return handler.player.positionStream;
    }
    // Fallback: emit zero periodically so UI doesn't crash.
    return Stream.periodic(const Duration(milliseconds: 500), (_) => Duration.zero);
  }

  /// Current duration stream.
  static Stream<Duration?> get durationStream {
    final handler = _handler;
    if (handler != null) {
      return handler.player.durationStream;
    }
    return const Stream.empty();
  }
}
