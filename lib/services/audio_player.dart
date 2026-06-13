/// Audio playback service wrapping [just_audio] + [audio_service].
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import '../models/song.dart';

/// Singleton audio handler that runs in a background isolate (Android).
class DuskAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  /// Track current song for reliable playback.
  // ignore: unused_field
  Song? _currentSong;

  /// Callback invoked when a track finishes playing — the UI uses this to decide what plays next.
  void Function()? onTrackComplete;

  /// Callbacks for notification panel next/previous — delegated from UI state.
  void Function()? onNextFromNotification;
  void Function()? onPreviousFromNotification;

  DuskAudioHandler() {
    // Wire up state broadcasting immediately on construction.
    _broadcastState();
    _player.playbackEventStream.listen((_) => _broadcastState());
    _player.processingStateStream.listen((state) {
      debugPrint('DuskAudioHandler processingState: $state');
      _broadcastState();
      // Auto-advance when a track completes
      if (state == ProcessingState.completed && onTrackComplete != null) {
        onTrackComplete!();
      }
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
        systemActions: const {},
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

  /// Override: delegate next to UI so it respects play queue + shuffle.
  @override
  Future<void> skipToNext() async {
    if (onNextFromNotification != null) {
      onNextFromNotification!();
    } else {
      // Fallback: replay current track from start
      await _player.seek(Duration.zero);
      await _player.play();
    }
  }

  /// Override: delegate previous to UI so it respects play queue + shuffle.
  @override
  Future<void> skipToPrevious() async {
    if (onPreviousFromNotification != null) {
      onPreviousFromNotification!();
    } else {
      // Fallback: replay current track from start
      await _player.seek(Duration.zero);
      await _player.play();
    }
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

/// Desktop audio handler — uses audioplayers which has native Windows/macOS/Linux support.
class DesktopAudioHandler {
  final ap.AudioPlayer _player = ap.AudioPlayer();
  bool _playing = false;
  final StreamController<bool> _playingController = StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController = StreamController<Duration?>.broadcast();
  Timer? _positionTimer;

  void Function()? onTrackComplete;
  void Function()? onNextFromNotification;
  void Function()? onPreviousFromNotification;


  DesktopAudioHandler() {
    _player.onPlayerStateChanged.listen((state) {
      debugPrint('DesktopAudioHandler state: $state');
      final wasPlaying = _playing;
      _playing = state == ap.PlayerState.playing;
      if (state == ap.PlayerState.stopped || state == ap.PlayerState.completed) {
        _playing = false;
        _positionTimer?.cancel();
        // NOTE: onTrackComplete is handled by onPlayerComplete below —
        // do NOT fire it here to avoid double-firing.
      }
      if (state == ap.PlayerState.playing) {
        _startPositionTimer();
      }
      // Notify UI of playing state change
      if (_playing != wasPlaying) {
        _playingController.add(_playing);
      }
    });
    _player.onDurationChanged.listen((duration) {
      debugPrint('DesktopAudioHandler duration: $duration');
      _durationController.add(duration);
    });
    _player.onPositionChanged.listen((pos) {
      _positionController.add(pos);
    });
    _player.onPlayerComplete.listen((_) {
      debugPrint('DesktopAudioHandler: track completed');
      _playing = false;
      _positionTimer?.cancel();
      if (onTrackComplete != null) {
        onTrackComplete!();
      }
    });
  }


  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        final pos = await _player.getCurrentPosition();
        if (pos != null) {
          _positionController.add(pos);
        }
      } catch (_) {}
    });
  }

  Future<void> playSong(Song song) async {
    debugPrint('DesktopAudioHandler.playSong: ${song.title} path=${song.uri}');

    // Verify file exists
    final filePath = song.uri;
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('DesktopAudioHandler.playSong: FILE NOT FOUND at $filePath');
        throw Exception('File not found: $filePath');
      }
      debugPrint('DesktopAudioHandler.playSong: file exists, size=${await file.length()} bytes');
    } catch (e) {
      debugPrint('DesktopAudioHandler.playSong: file check failed: $e');
    }

    try {
      // Reset position to zero before loading new track — prevents stale progress bar
      _positionController.add(Duration.zero);
      await _player.stop();
      await _player.setSourceDeviceFile(filePath);
      await _player.resume();
      debugPrint('DesktopAudioHandler.playSong: success for ${song.title}');
    } catch (e) {
      debugPrint('DesktopAudioHandler.playSong FAILED for ${song.title}: $e');
      rethrow;
    }
  }

  Future<void> play() async {
    await _player.resume();
    _playing = true;
  }

  Future<void> pause() async {
    await _player.pause();
    _playing = false;
  }

  Future<void> stop() async {
    await _player.stop();
    _playing = false;
    _positionTimer?.cancel();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  bool get isPlaying => _playing;
  Stream<bool> get playingStateStream => _playingController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;

  void dispose() {
    _positionTimer?.cancel();
    _playingController.close();
    _positionController.close();
    _durationController.close();
    _player.dispose();
  }
}

/// Facade class that the UI interacts with.
class AudioPlayerService {
  static DuskAudioHandler? _handler;       // Android (audio_service)
  static DesktopAudioHandler? _desktopHandler; // Desktop (just_audio direct)
  static final bool _isDesktop = !Platform.isAndroid && !Platform.isIOS;

  /// Initialize the audio service (call once in main()).
  static Future<void> init() async {
    if (_isDesktop) {
      // Desktop: use just_audio directly — no background isolate needed.
      _desktopHandler = DesktopAudioHandler();
      debugPrint('AudioPlayerService: initialized for desktop');
    } else {
      // Android/iOS: use audio_service with background isolate + notifications.
      _handler = await AudioService.init(
        builder: () => DuskAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.spkelevra.dusktune.channel.audio',
          androidNotificationChannelName: 'DuskTune playback',
          androidShowNotificationBadge: true,
          androidStopForegroundOnPause: false,
        ),
      );
      debugPrint('AudioPlayerService: initialized with audio_service');
    }
  }

  static DuskAudioHandler? get handler => _handler;
  static DesktopAudioHandler? get desktopHandler => _desktopHandler;
  static bool get isDesktop => _isDesktop;

  /// Set a callback for when the current track finishes playing.
  static void setOnTrackComplete(void Function()? callback) {
    _handler?.onTrackComplete = callback;
    _desktopHandler?.onTrackComplete = callback;
  }

  /// Set callbacks for notification panel next/previous buttons.
  static void setNotificationCallbacks({
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    _handler?.onNextFromNotification = onNext;
    _handler?.onPreviousFromNotification = onPrevious;
    _desktopHandler?.onNextFromNotification = onNext;
    _desktopHandler?.onPreviousFromNotification = onPrevious;
  }

  /// Play a song.
  static Future<void> playSong(Song song) async {
    if (_isDesktop) {
      await _desktopHandler?.playSong(song);
    } else {
      await _handler?.playSong(song);
    }
  }

  /// Toggle play/pause.
  static Future<void> togglePlayPause() async {
    if (_isDesktop) {
      final dh = _desktopHandler;
      if (dh == null) return;
      if (dh.isPlaying) {
        await dh.pause();
      } else {
        await dh.play();
      }
    } else {
      if (_handler == null) return;
      final state = _handler!.playbackState.value;
      if (state.playing) {
        await pause();
      } else {
        await play();
      }
    }
  }

  /// Play.
  static Future<void> play() async {
    if (_isDesktop) {
      await _desktopHandler?.play();
    } else {
      await _handler?.play();
    }
  }

  /// Pause.
  static Future<void> pause() async {
    if (_isDesktop) {
      await _desktopHandler?.pause();
    } else {
      await _handler?.pause();
    }
  }

  /// Stop playback.
  static Future<void> stop() async {
    if (_isDesktop) {
      await _desktopHandler?.stop();
    } else {
      await _handler?.stop();
    }
  }

  /// Seek to position.
  static Future<void> seek(Duration position) async {
    if (_isDesktop) {
      await _desktopHandler?.seek(position);
    } else {
      await _handler?.seek(position);
    }
  }

  /// Skip to next song in queue.
  static Future<void> skipToNext() async {
    await _handler?.skipToQueueItem(1);
  }

  /// Skip to previous song in queue.
  static Future<void> skipToPrevious() async {
    await _handler?.skipToQueueItem(0);
  }

  /// Current playback state stream (Android only).
  static Stream<PlaybackState?> get playbackState {
    return _handler?.playbackState.stream ?? const Stream.empty();
  }

  /// Playing state stream that works on ALL platforms.
  /// Emits true when playing starts, false when paused/stopped/completed.
  static Stream<bool> get playingStateStream {
    if (_isDesktop) {
      final dh = _desktopHandler;
      if (dh != null) return dh.playingStateStream;
    } else {
      // On Android, derive from playbackState stream
      final handler = _handler;
      if (handler != null) {
        return handler.playbackState.stream.map((state) => state.playing);
      }
    }
    return const Stream.empty();
  }

  /// Whether currently playing.
  static bool get isPlaying {
    if (_isDesktop) return _desktopHandler?.isPlaying ?? false;
    return _handler?.playbackState.value.playing ?? false;
  }

  /// Current position stream from just_audio (if available).
  static Stream<Duration> get positionStream {
    if (_isDesktop) {
      final dh = _desktopHandler;
      if (dh != null) return dh.positionStream;
    } else {
      final handler = _handler;
      if (handler != null) return handler.player.positionStream;
    }
    // Fallback: emit zero periodically so UI doesn't crash.
    return Stream.periodic(const Duration(milliseconds: 500), (_) => Duration.zero);
  }

  /// Current duration stream.
  static Stream<Duration?> get durationStream {
    if (_isDesktop) {
      final dh = _desktopHandler;
      if (dh != null) return dh.durationStream;
    } else {
      final handler = _handler;
      if (handler != null) return handler.player.durationStream;
    }
    return const Stream.empty();
  }
}
