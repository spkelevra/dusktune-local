/// Audio playback service wrapping [mpv_audio_kit].
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';
import '../models/song.dart';

/// Singleton audio handler — uses mpv directly (no background isolate).
class MpvAudioHandler {
  final Player _player = Player(
    configuration: const PlayerConfiguration(enableYtDlp: true),
  );

  /// Callback invoked when a track finishes playing.
  void Function()? onTrackComplete;

  /// Callback invoked when OS media session sends next-track command.
  void Function()? onNextTrack;

  /// Callback invoked when OS media session sends previous-track command.
  void Function()? onPreviousTrack;

  /// Current volume level (0.0–1.0).
  double _currentVolume = 1.0;

  /// FFT configuration optimized for Android (~7fps native limit)
  static final _fftConfig = SpectrumSettings(
    fftSize: 1024,
    bandCount: 32,
    emitInterval: Duration(milliseconds: 33), // Target ~30fps (gets ~7fps on Android)
    overlapFactor: 4,
  );

  /// Current filter control value (-1..+1), persisted so we can reapply it
  /// after a track change (mpv clears DSP chain on file load).
  double _filterControlValue = 0.0;

  /// Flag set while playSong is in flight. endFile events that arrive during
  /// a transition are ignored — they're caused by the previous file being
  /// replaced, not by it actually finishing playback.
  bool _isTransitioning = false;

  MpvAudioHandler() {
    // Pre-initialize DSP chain with pass-through filters so the pipeline is
    // always present — prevents first-track glitch when setFilterControl runs
    // on an empty chain after open().
    _player.setAudioEffects(AudioEffects(
      lowpass: const LowpassSettings(enabled: true, f: 20000.0),
      highpass: const HighpassSettings(enabled: true, f: 20.0),
    ));

    // Listen for track completion via the `completed` stream — this is the
    // authoritative signal provided by mpv_audio_kit that a track has finished
    // playing (equivalent to just_audio's ProcessingState.completed).
    _player.stream.completed.listen((done) {
      if (!done || _isTransitioning) return;
      debugPrint('MpvAudioHandler: completed=true, firing onTrackComplete');
      if (onTrackComplete != null) {
        onTrackComplete!();
      } else {
        debugPrint('  -> WARNING: onTrackComplete callback is NULL');
      }
    });

    // Also listen for endFile events — fire on natural EOF or error.
    _player.stream.endFile.listen((event) {
      if (_isTransitioning) return;
      // Only fire on eof (natural end) or error — not stop/quit (file replacement).
      debugPrint('MpvAudioHandler: endFile reason=${event.reason}');
      if ((event.reason == MpvEndFileReason.eof || event.reason == MpvEndFileReason.error)) {
        debugPrint('  -> firing onTrackComplete from endFile');
        onTrackComplete?.call();
      }
    });

    // Listen for errors
    _player.stream.error.listen((error) {
      debugPrint('MpvAudioHandler error: $error');
    });

    // Enable OS media session — shows playback controls on lockscreen,
    // Windows Action Center, macOS Control Center, notification shade.
    _enableMediaSession();

    // Listen for next/previous commands from the OS media session.
    _player.stream.mediaSessionCommands.listen((command) {
      debugPrint('MpvAudioHandler: MediaSessionCommand ${command.runtimeType}');
      if (command is MediaSessionCommandNext && onNextTrack != null) {
        debugPrint('  -> firing onNextTrack');
        onNextTrack!();
      } else if (command is MediaSessionCommandPrevious && onPreviousTrack != null) {
        debugPrint('  -> firing onPreviousTrack');
        onPreviousTrack!();
      }
    });
  }

  /// Enable OS media session with default settings. Metadata fields are
  /// derived from the playing file's ID3 tags via mpv unless overridden.
  Future<void> _enableMediaSession() async {
    try {
      await _player.setMediaSession(const MediaSession());
      debugPrint('MpvAudioHandler: OS media session enabled');
    } catch (e) {
      debugPrint('MpvAudioHandler: failed to enable media session: $e');
    }
  }

  /// Update media session metadata with current track info.
  Future<void> _updateMediaSessionMetadata(Song song) async {
    try {
      final ms = _player.state.mediaSession;
      if (ms != null) {
        await _player.setMediaSession(
          ms.copyWith(
            title: song.title,
            artist: song.artist,
            album: song.album,
          ),
        );
      }
    } catch (e) {
      debugPrint('MpvAudioHandler: failed to update media metadata: $e');
    }
  }

  /// Play a song using its file path. Sets _isTransitioning so that endFile
  /// events from the previous (replaced) track are suppressed until this call
  /// completes, then briefly afterwards to let mpv settle.
  Future<void> playSong(Song song) async {
    debugPrint('MpvAudioHandler.playSong: ${song.title} uri=${song.uri}');

    final media = Media(
      song.uri,
      audioEffects: _filterControlValue.abs() >= 0.02 ? _currentFilterEffects() : null,
    );

    if (_filterControlValue.abs() >= 0.02) {
      debugPrint('MpvAudioHandler: injecting pre-load filter for ${song.title} via Media.audioEffects');
    }

    _isTransitioning = true;
    try {
      await _player.open(media, play: true);
      // Give mpv a brief settle window after open so the old file's EOF
      // (if it arrives late) doesn't trigger auto-advance.
      await Future.delayed(const Duration(milliseconds: 200));

      // Update media session metadata with current track info
      await _updateMediaSessionMetadata(song);
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
    debugPrint('MpvAudioHandler: stop called');
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

  /// FFT spectrum stream from mpv — emits FftFrame at ~30 Hz.
  Stream<FftFrame> get fftStream => _player.stream.fft;

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
  /// cutoff over [duration], using updateAudioEffects for glitch-free updates.
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

  /// Apply a combined filter control value in the range -1.0 (strong LPF) through
  /// +1.0 (strong HPF), with 0.0 meaning no filter. Keeps both filters enabled at
  /// all times with neutral frequencies, so only the cutoff moves — never an abrupt
  /// enable/disable toggle. Uses updateAudioEffects for glitch-free af-command updates.
  Future<void> setFilterControl(double value) async {
    // Clamp to [-1, +1]
    final v = value.clamp(-1.0, 1.0);

    _filterControlValue = v; // persist for reapply on track change

    return await _player.updateAudioEffects((effects) => effects.copyWith(
      lowpass: LowpassSettings(
        enabled: true,
        f: v.abs() < 0.02 || v >= 0 ? 20000.0 : 20000.0 * pow(0.005, (-v).clamp(0.02, 1.0)),
      ),
      highpass: HighpassSettings(
        enabled: true,
        f: v.abs() < 0.02 || v <= 0 ? 20.0 : (20.0 * pow(400.0, v.clamp(0.02, 1.0))).clamp(10.0, 20000.0),
      ),
    ));
  }

  /// Build an [AudioEffects] bundle from the current filter control value,
  /// or a neutral pass-through if no filter is active. Used for initial-media
  /// injection and live updates.
  AudioEffects _currentFilterEffects() {
    if (_filterControlValue.abs() < 0.02) {
      return const AudioEffects(
        lowpass: LowpassSettings(enabled: true, f: 20000.0),
        highpass: HighpassSettings(enabled: true, f: 20.0),
      );
    } else if (_filterControlValue < 0) {
      final t = (-_filterControlValue).clamp(0.02, 1.0);
      final lpCutoff = 20000.0 * pow(0.005, t);
      return AudioEffects(
        lowpass: LowpassSettings(enabled: true, f: lpCutoff),
        highpass: const HighpassSettings(enabled: true, f: 20.0),
      );
    } else {
      final t = _filterControlValue.clamp(0.02, 1.0);
      final hpCutoff = 20.0 * pow(400.0, t).clamp(10.0, 20000.0);
      return AudioEffects(
        lowpass: const LowpassSettings(enabled: true, f: 20000.0),
        highpass: HighpassSettings(enabled: true, f: hpCutoff),
      );
    }
  }

  /// Remove all audio filters (reset DSP chain).
  Future<void> clearFilters() async {
    debugPrint('MpvAudioHandler: clearing audio effects');
    _filterControlValue = 0.0; // reset so next track doesn't reapply stale filter
    await _player.setAudioEffects(AudioEffects());
  }

  void dispose() {
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
    debugPrint('AudioPlayerService: setOnTrackComplete(${callback != null ? "callback" : "null"})');
    _handler?.onTrackComplete = callback;
  }

  /// Set callbacks for next/previous track commands from the OS media session.
  static void setNotificationCallbacks({
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    _handler?.onNextTrack = onNext;
    _handler?.onPreviousTrack = onPrevious;
  }

  /// Play a song.
  static Future<void> playSong(Song song) async {
    debugPrint('AudioPlayerService: playSong(${song.title})');
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
    debugPrint('AudioPlayerService: stop called');
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

  /// Skip to next song in queue (triggers OS media session next command).
  static Future<void> skipToNext() async {
    _handler?.onNextTrack?.call();
  }

  /// Skip to previous song in queue (triggers OS media session previous command).
  static Future<void> skipToPrevious() async {
    _handler?.onPreviousTrack?.call();
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

  /// FFT spectrum stream from mpv — emits FftFrame at ~30 Hz.
  static Stream<FftFrame> get fftStream => _handler?.fftStream ?? const Stream.empty();

  /// Visualizer style: "bars" (default), "wave", or "dots".
  static String _vizStyle = 'bars';
  static double _vizIntensity = 1.0;
  static double get vizIntensity => _vizIntensity;
  static set vizIntensity(double v) => _vizIntensity = v.clamp(0.0, 2.0);

  /// Smoothing/decay factor: 0.0 (no smoothing, raw FFT), 1.0 (heavy smoothing).
  static double _smoothingFactor = 0.5;
  static double get smoothingFactor => _smoothingFactor;
  static set smoothingFactor(double v) => _smoothingFactor = v.clamp(0.0, 1.0);
  static String get vizStyle => _vizStyle;
  static set vizStyle(String s) => _vizStyle = s;

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

  /// Apply a combined filter control (-1 = strong LPF, +1 = strong HPF, 0 = none).
  static Future<void> setFilterControl(double value) async {
    await _handler?.setFilterControl(value);
  }

  void dispose() {
    _handler?.dispose();
  }
}
