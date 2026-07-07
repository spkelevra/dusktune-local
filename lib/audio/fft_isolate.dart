/// FFT processing isolate — runs heavy spectrum post-processing off the UI
/// thread so the visualiser stays at 60 fps even when GC spikes occur.
///
/// Pipeline:
///   mpv_audio_kit → FftFrame (raw bands) → Isolate (smoothing + aggregation)
///   → VisualizerData (32 pre-scaled bars) → UI painters (just draw).
///
/// Trade-off: adds ~10–15 ms of latency (acceptable for a music player).
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

/// One snapshot of pre‑processed visualiser data.
///
/// [displayBars] is always 32 values in [0, 1], ready to feed directly
/// into any CustomPainter without further aggregation.
/// [peakHold] tracks per-band peak history for the peak-hold visualiser.
class VisualizerData {
  final List<double> displayBars;
  final List<double>? peakHold;
  final double timestamp;

  const VisualizerData({
    required this.displayBars,
    this.peakHold,
    required this.timestamp,
  });

  factory VisualizerData.empty() {
    return VisualizerData(
      displayBars: List<double>.filled(32, 0.0),
      peakHold: List<double>.filled(32, 0.0),
      timestamp: 0.0,
    );
  }
}

/// Top-level isolate entry point.
///
/// [args] is `[SendPort]` — the dataReplyPort for sending results back.
void _fftIsolateMain(List<dynamic> args) {
  final SendPort dataReplyPort = args[0] as SendPort;

  // Create receive port for commands from main isolate
  final ReceivePort commandPort = ReceivePort();

  // First message: send our command SendPort back
  dataReplyPort.send(commandPort.sendPort);

  // Mutable state
  double smoothing = 0.5;
  List<double>? smoothed;
  final List<double> peaks = List<double>.filled(32, 0.0);
  const int kBandCount = 32;
  const double kPeakDecay = 0.95;

  commandPort.listen((dynamic msg) {
    if (msg is List<double>) {
      // ── Raw FFT bands ─────────────────────────────────────
      if (smoothed == null || smoothed!.length != msg.length) {
        smoothed = List<double>.filled(msg.length, 0.0);
      }

      final List<double> bands;
      if (smoothing <= 0.02) {
        bands = msg;
      } else {
        // Non-linear curve: slider 0→1 maps to alpha 0.02→0.98
        // so the user feels the difference across the full range.
        final alpha = math.pow(smoothing, 2.0).clamp(0.02, 0.98);
        final s = smoothed!;
        for (int i = 0; i < msg.length; i++) {
          s[i] = s[i] * alpha + msg[i] * (1.0 - alpha);
        }
        bands = s;
      }

      // Aggregate to 32 display bars
      final List<double> display = List<double>.filled(kBandCount, 0.0);
      final int step = (bands.length / kBandCount).ceil();
      for (int i = 0; i < kBandCount; i++) {
        double sum = 0;
        int count = 0;
        for (int j = 0; j < step && i * step + j < bands.length; j++) {
          sum += bands[i * step + j];
          count++;
        }
        display[i] = count > 0 ? math.min(1.0, sum / count) : 0.0;
      }

      // Peak hold
      for (int i = 0; i < kBandCount; i++) {
        peaks[i] = math.max(display[i], peaks[i] * kPeakDecay);
      }

      // Send back: [displayBars, peaks, timestamp]
      dataReplyPort.send([
        display,
        List<double>.from(peaks),
        DateTime.now().millisecondsSinceEpoch / 1000.0,
      ]);
      // ───────────────────────────────────────────────────────
    } else if (msg is Map<String, dynamic>) {
      final String? type = msg['type'];
      if (type == 'smoothing') {
        smoothing = (msg['value'] as num).toDouble();
      } else if (type == 'reset') {
        smoothed = null;
        peaks.fillRange(0, peaks.length, 0.0);
      }
    }
  });
}

/// Singleton FFT processor backed by an Isolate.
///
/// Typical usage:
/// ```dart
/// final fft = FftProcessor();
/// await fft.start();
///
/// // In your FFT stream callback:
/// fftStream.listen((frame) => fft.feed(frame.bands));
///
/// // On the UI side:
/// fft.stream.listen((data) {
///   // data.displayBars is ready for your painter
/// });
/// ```
class FftProcessor {
  Isolate? _isolate;
  SendPort? _commandPort;
  StreamSubscription<dynamic>? _dataSubscription;

  final StreamController<VisualizerData> _output =
      StreamController<VisualizerData>.broadcast();

  /// Broadcast stream of processed visualiser data.
  Stream<VisualizerData> get stream => _output.stream;

  /// Whether the isolate is alive.
  bool get isRunning => _isolate != null;

  /// Feed raw FFT bands (e.g., `frame.bands`) into the pipeline.
  void feed(List<double> bands) {
    _commandPort?.send(bands);
  }

  /// Update smoothing factor (0.0 = raw, 1.0 = heavy).
  void setSmoothing(double value) {
    _commandPort?.send({'type': 'smoothing', 'value': value});
  }

  /// Reset internal buffers (clears smoothed state and peak holds).
  void reset() {
    _commandPort?.send({'type': 'reset'});
  }

  /// Start the isolate. Call once during app init.
  Future<void> start() async {
    if (_isolate != null) return;

    // Create a receive port for data coming back from the isolate
    final ReceivePort dataPort = ReceivePort();

    // Spawn the isolate, passing the data reply port
    _isolate = await Isolate.spawn(
      _fftIsolateMain,
      [dataPort.sendPort],
      errorsAreFatal: false,
    );

    // Single subscription: first message is the handshake (SendPort),
    // subsequent messages are processed VisualizerData.
    _dataSubscription = dataPort.listen((dynamic msg) {
      if (msg is SendPort) {
        // Handshake — isolate sends its command port back
        _commandPort = msg;
      } else if (msg is List<dynamic> && msg.length >= 3) {
        final data = VisualizerData(
          displayBars: List<double>.from(msg[0]),
          peakHold: List<double>.from(msg[1]),
          timestamp: (msg[2] as num).toDouble(),
        );
        if (!_output.isClosed) {
          _output.add(data);
        }
      }
    });

    // Wait for handshake to complete before returning
    while (_commandPort == null) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Stop the isolate. Call when the app goes to background or on dispose.
  Future<void> stop() async {
    await _dataSubscription?.cancel();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
    if (!_output.isClosed) {
      await _output.close();
    }
  }
}
