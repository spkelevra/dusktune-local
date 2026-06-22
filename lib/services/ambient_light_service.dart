/// Ambient Light Sensor (ALS) service — polls device ALS on Android via the
/// `ambient_light` package and exposes a sunlight factor (0.0–1.0).
library;

import 'dart:async';
import 'package:ambient_light/ambient_light.dart';

class AmbientLightService {
  static final AmbientLightService _instance = AmbientLightService._internal();
  factory AmbientLightService() => _instance;
  AmbientLightService._internal();

  final StreamController<double> _controller = StreamController<double>.broadcast();
  double _currentFactor = 0.0;

  StreamSubscription<double>? _streamSub;
  bool _isActive = false;
  late final AmbientLight _sensor;
  Timer? _debounceTimer;

  /// Current sunlight factor (0.0–1.0). Starts at -1.0 to indicate "not yet read".
  double get currentFactor => _currentFactor;

  Stream<double> get stream => _controller.stream;

  Future<void> start() async {
    if (_isActive) return;
    _isActive = true;
    _sensor = AmbientLight();

    // Try an immediate one-shot read first.
    try {
      final lux = await _sensor.currentAmbientLight();
      print('ALS one-shot read: lux=$lux');
      if (lux != null && lux > 0) {
        _updateFactor(luxToFactor(lux));
      } else {
        print('ALS one-shot returned null or zero — sensor may not be ready yet');
      }
    } catch (e) {
      print('ALS one-shot failed: $e');
    }

    // Then subscribe to the live stream.
    _streamSub = _sensor.ambientLightStream.listen(
      _onSensorEvent,
      onError: (err) => print('ALS stream error: $err'),
    );
  }

  void _onSensorEvent(double lux) {
    final factor = luxToFactor(lux);
    // Debounce: only update if the change is significant (>0.03).
    if ((factor - _currentFactor).abs() > 0.03 || _currentFactor < 0) {
      print('ALS event: lux=$lux → factor=$factor');
      _updateFactor(factor);
    }
  }

  void _updateFactor(double factor) {
    final old = _currentFactor;
    _currentFactor = factor.clamp(0.0, 1.0);
    if (old != _currentFactor) {
      _controller.add(_currentFactor);
    }
  }

  void stop() {
    _isActive = false;
    _debounceTimer?.cancel();
    _streamSub?.cancel();
    _streamSub = null;
  }

  /// Convert lux value to a sunlight factor (0.0–1.0).
  static double luxToFactor(double lux) {
    if (lux < 50.0) return 0.0;
    if (lux < 1000.0) return ((lux - 50.0) / (1000.0 - 50.0)).clamp(0.0, 0.2);
    if (lux < 5000.0) return 0.2 + (((lux - 1000.0) / (5000.0 - 1000.0)) * 0.2).clamp(0.0, 0.2);
    if (lux < 20000.0) return 0.4 + (((lux - 5000.0) / (20000.0 - 5000.0)) * 0.3).clamp(0.0, 0.3);
    return 0.7 + (((lux - 20000.0) / (100000.0 - 20000.0))).clamp(0.0, 0.3);
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
