/// Audio playback service wrapping [mpv_audio_kit].
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';
import '../models/song.dart';

/// Singleton audio handler — uses mpv directly (no background isolate).
class MpvAudioHandler {
  final Player _player = Player();

  /// Callback invoked when a track finishes playing.
  void Function()? onTrackComplete;

  /// Current volume level (0.0–1.0).
  double _currentVolume = 1.0;

  /// Track complete subscription.
  StreamSubscription<MpvFileEndedEvent>? _endFileSub;

  /// Flag set while playSong is in flight. endFile events that arrive during
  /// a transition are ignored — they're caused by the previous file being
  /// replaced, not by it actually finishing playback.
  bool _isTransitioning = false;

  MpvAudioHandler() {
    // Listen for track completion — only fire callback when the loaded file
    // actually plays through to its end (not when replaced mid-load).
    _endFileSub = _player.stream.endFile.listen((event) {
      debugPrint('MpvAudioHandler: endFile event, reason=${event.reason}');
      if (_isTransitioning) {
        debugPrint('  -> suppressed (transitioning)');
        return;
      }
      if (onTrackComplete != null) {
        onTrackComplete!();
      }
    });

    // Listen for errors
    _player.stream.error.listen((error) {
      debugPrint('MpvAudioHandler error: $error');
    });
  }

  /// Play a song using its file path. Sets _isTransitioning so that endFile
  /// events from the previous (replaced) track are suppressed until this call
  /// completes, then briefly afterwards to let mpv settle.
  Future<void> playSong(Song song) async {
    debugPrint('MpvAudioHandler.playSong: ${song.title} uri=${song.uri}');

    final media = Media(song.uri);

    _isTransitioning = true;
    try {
      await _player.open(media, play: true);
      // Give mpv a brief settle window after open so the old file's EOF
      // (if it arrives late) doesn't trigger auto-advance.
      await Future.delayed(const Duration(milliseconds: 200));
      debugPrint('MpvAudioHandler.playSong: success for ${song.title}');
    } catch (e) {
      debugPrint('MpvAudioHandler.playSong FAILED for ${song.title}: $e');
    } finally {
      _isTransitioning = false;
    }
  }

  Future<void> play() async {
    await _player.play();
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> stop() async {
    await _player.seek(Duration.zero);
    await _player.pause();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  bool get isPlaying => _player.state.playWhenReady;

  Stream<Duration> get positionStream => _player.stream.position;

  Stream<Duration?> get durationStream =>
      _player.stream.duration.map((d) => d.isNegative ? null : d);

  /// Set playback volume (0.0–1.0).
  Future<void> setVolume(double v) async {
    _currentVolume = v.clamp(0.0, 1.0);
    await _player.setVolume(_currentVolume * 100);
  }

  double get currentVolume => _currentVolume;

  /// Gradually ramp a low-pass filter from full (20 kHz) down to the target
  /// cutoff over [duration], using updateAudioEffects so each step is an
  /// af-command parameter tweak — no chain teardown, no skip.
  Future<void> rampLowPassFilter(double targetCutoffHz, Duration duration) async {
    const steps = 30;
    final stepMs = (duration.inMilliseconds / steps).ceil();

    // First enable the filter at 20 kHz (essentially no effect), then ramp.
    await _player.updateAudioEffects(
      (effects) => effects.copyWith(
        lowpass: const LowpassSettings(enabled: true, f: 20000.0),
      ),
    );

    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final cutoff = 20000.0 - (t * (20000.0 - targetCutoffHz));
      debugPrint('MpvAudioHandler: ramp LPF to ${cutoff.toStringAsFixed(0)} Hz');

      // Only change the f parameter — everything else stays identical,
      // so updateAudioEffects will use af-command (glitch-free).
      await _player.updateAudioEffects((effects) {
        final lp = effects.lowpass;
        if (lp != null) {
          return effects.copyWith(lowpass: lp.copyWith(f: cutoff));
        } else {
          return effects.copyWith(
            lowpass: LowpassSettings(enabled: true, f: cutoff),
          );
        }
      });

      if (i < steps) {
        await Future.delayed(Duration(milliseconds: stepMs));
      }
    }
  }

  /// Gradually ramp the low-pass filter from its current cutoff up to "no
  /// filter", then disable it. Uses af-command for glitch-free updates.
  Future<void> removeLowPassFilter(Duration duration) async {
    const steps = 20; // faster than engaging
    final stepMs = (duration.inMilliseconds / steps).ceil();

    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final cutoff = 400.0 + (t * 19600.0);

      if (cutoff >= 20000) {
        // Disable the filter entirely
        await _player.updateAudioEffects(
          (effects) => effects.copyWith(lowpass: null),
        );
        return;
      }

      debugPrint('MpvAudioHandler: remove LPF to ${cutoff.toStringAsFixed(0)} Hz');
      await _player.updateAudioEffects((effects) {
        final lp = effects.lowpass;
        if (lp != null) {
          return effects.copyWith(lowpass: lp.copyWith(f: cutoff));
        } else {
          return effects;
        }
      });

      if (i < steps) {
        await Future.delayed(Duration(milliseconds: stepMs));
      }
    }

    // Safety net — disable filter in case we didn't reach 20kHz.
    await _player.updateAudioEffects((effects) => effects.copyWith(lowpass: null));
  }

  /// Gradually ramp a high-pass filter from full (20 Hz) up to the target
  /// cutoff over [duration], using af-command for glitch-free updates.
  Future<void> rampHighPassFilter(double targetCutoffHz, Duration duration) async {
    const steps = 30;
    final stepMs = (duration.inMilliseconds / steps).ceil();

    // First enable the filter at ~20 Hz (essentially no effect), then ramp.
    await _player.updateAudioEffects(
      (effects) => effects.copyWith(
        highpass: const HighpassSettings(enabled: true, f: 20.0),
      ),
    );

    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final cutoff = 20.0 + (t * (targetCutoffHz - 20.0));
      debugPrint('MpvAudioHandler: ramp HPF to ${cutoff.toStringAsFixed(0)} Hz');

      await _player.updateAudioEffects((effects) {
        final hp = effects.highpass;
        if (hp != null) {
          return effects.copyWith(highpass: hp.copyWith(f: cutoff));
        } else {
          return effects.copyWith(
            highpass: HighpassSettings(enabled: true, f: cutoff),
          );
        }
      });

      if (i < steps) {
        await Future.delayed(Duration(milliseconds: stepMs));
      }
    }
  }

  /// Gradually ramp the high-pass filter from its current cutoff down to "no
  /// filter", then disable it. Uses af-command for glitch-free updates.
  Future<void> removeHighPassFilter(Duration duration) async {
    const steps = 20; // faster than engaging
    final stepMs = (duration.inMilliseconds / steps).ceil();

    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final cutoff = 800.0 - (t * 780.0); // 800 down to 20

      if (cutoff < 100) {
        await _player.updateAudioEffects(
          (effects) => effects.copyWith(highpass: null),
        );
        return;
      }

      debugPrint('MpvAudioHandler: remove HPF to ${cutoff.toStringAsFixed(0)} Hz');
      await _player.updateAudioEffects((effects) {
        final hp = effects.highpass;
        if (hp != null) {
          return effects.copyWith(highpass: hp.copyWith(f: cutoff));
        } else {
          return effects;
        }
      });

      if (i < steps) {
        await Future.delayed(Duration(milliseconds: stepMs));
      }
    }

    // Safety net — disable filter in case we didn't reach 20Hz.
    await _player.updateAudioEffects((effects) => effects.copyWith(highpass: null));
  }

  /// Remove all audio filters (reset DSP chain).
  Future<void> clearFilters() async {
    debugPrint('MpvAudioHandler: clearing audio effects');
    await _player.setAudioEffects(AudioEffects());
  }

  void dispose() {
    _endFileSub?.cancel();
    _player.dispose();
  }
}

/// Facade class that the UI interacts with.
class AudioPlayerService {
  static MpvAudioHandler? _handler;
  static final bool _isDesktop = !Platform.isAndroid && !Platform.isIOS;

  /// Initialize the audio service (call once in main()).
  static Future<void> init() async {
    _handler = MpvAudioHandler();
    debugPrint('AudioPlayerService: initialized with mpv_audio_kit');
  }

  static MpvAudioHandler? get handler => _handler;
  static bool get isDesktop => _isDesktop;

  /// Set a callback for when the current track finishes playing.
  static void setOnTrackComplete(void Function()? callback) {
    _handler?.onTrackComplete = callback;
  }

  /// Set callbacks for notification panel next/previous buttons.
  /// (No-op with mpv — media session handled differently.)
  static void setNotificationCallbacks({
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    // No-op — mpv handles OS integration internally via MediaSession
  }

  /// Play a song.
  static Future<void> playSong(Song song) async {
    await _handler?.playSong(song);
  }

  /// Toggle play/pause.
  static Future<void> togglePlayPause() async {
    if (_handler == null) return;
    if (_handler!.isPlaying) {
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

  /// Set playback volume (0.0–1.0).
  static Future<void> setVolume(double v) async {
    await _handler?.setVolume(v);
  }

  /// Skip to next song in queue.
  static Future<void> skipToNext() async {
    // No-op — queue management is handled by the UI layer via onTrackComplete callback
  }

  /// Skip to previous song in queue.
  static Future<void> skipToPrevious() async {
    // No-op — queue management is handled by the UI layer via onTrackComplete callback
  }

  /// Playing state stream that works on ALL platforms.
  /// Emits true when playing starts, false when paused/stopped/completed.
  static Stream<bool> get playingStateStream {
    final handler = _handler;
    if (handler != null) {
      return _playerPlayingStream(handler);
    }
    return const Stream.empty();
  }

  /// Whether currently playing.
  static bool get isPlaying => _handler?.isPlaying ?? false;

  /// Current position stream from mpv_audio_kit.
  static Stream<Duration> get positionStream {
    final handler = _handler;
    if (handler != null) return handler.positionStream;
    // Fallback: emit zero periodically so UI doesn't crash.
    return Stream.periodic(const Duration(milliseconds: 500), (_) => Duration.zero);
  }

  /// Current duration stream.
  static Stream<Duration?> get durationStream {
    final handler = _handler;
    if (handler != null) {
      return handler.durationStream;
    }
    return const Stream.empty();
  }

  /// Helper to derive playing state stream from mpv player.
  static Stream<bool> _playerPlayingStream(MpvAudioHandler handler) {
    // Combine position changes with play/pause events
    return handler.positionStream.map((_) => handler.isPlaying);
  }

  /// Remove low-pass filter gradually over [duration].
  static Future<void> removeLowPassFilter(Duration duration) async {
    await _handler?.removeLowPassFilter(duration);
  }

  /// Ramp up a low-pass filter gradually.
  static Future<void> rampLowPassFilter(double cutoffHz, Duration duration) async {
    await _handler?.rampLowPassFilter(cutoffHz, duration);
  }

  /// Remove high-pass filter gradually over [duration].
  static Future<void> removeHighPassFilter(Duration duration) async {
    await _handler?.removeHighPassFilter(duration);
  }

  /// Ramp up a high-pass filter gradually.
  static Future<void> rampHighPassFilter(double cutoffHz, Duration duration) async {
    await _handler?.rampHighPassFilter(cutoffHz, duration);
  }

  /// Clear all audio filters.
  static Future<void> clearFilters() async {
    await _handler?.clearFilters();
  }

  void dispose() {
    _handler?.dispose();
  }
}
