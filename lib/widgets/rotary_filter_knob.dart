/// Compact rotary knob for filter control.
/// Drag horizontally to rotate; -135° = LPF max, 0° = neutral (top), +135° = HPF max.
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';

class RotaryFilterKnob extends StatefulWidget {
  final double value;           // [-1, +1]
  final ValueChanged<double>? onChanged;

  const RotaryFilterKnob({super.key, this.value = 0.0, this.onChanged});

  @override
  State<RotaryFilterKnob> createState() => _RotaryFilterKnobState();
}

class _RotaryFilterKnobState extends State<RotaryFilterKnob> {
  double _angle = 0;           // radians from -135°..+135° (top = neutral)
  Offset? _dragOrigin;

  static const double _maxAngle = math.pi * 3 / 4; // ±135°
  static const double _size = 40.0;               // compact: fits beside text, larger on Android

  @override
  void initState() {
    super.initState();
    _angleFromValue(widget.value);
  }

  @override
  void didUpdateWidget(RotaryFilterKnob old) {
    super.didUpdateWidget(old);
    // Sync from parent whenever the value changes externally (e.g. reset button).
    if (widget.value != old.value) {
      _angleFromValue(widget.value);
    }
  }

  void _angleFromValue(double v) =>
      _angle = math.max(-_maxAngle, math.min(_maxAngle, v * _maxAngle));

  double _valueFromAngle(double a) => (a / _maxAngle).clamp(-1.0, 1.0);

  void _onPanStart(DragStartDetails d) {
    _dragOrigin = d.globalPosition;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (widget.onChanged == null || _dragOrigin == null) return;
    // Horizontal drag → angle. Sensitivity: ~150 px ≈ full ±135° sweep.
    const double sensitivity = (_maxAngle * 2) / 150.0;
    setState(() => _angle += d.delta.dx * sensitivity);
    widget.onChanged!(_valueFromAngle(_angle));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      child: SizedBox.square(
        dimension: _size,
        child: CustomPaint(painter: _KnobPainter(angle: _angle)),
      ),
    );
  }
}

/// Draws a dark circular knob with an indicator line that rotates.
class _KnobPainter extends CustomPainter {
  final double angle; // radians from vertical (top)

  const _KnobPainter({required this.angle});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 3;
    final activeLevel = (angle.abs() / (math.pi * 3 / 4)).clamp(0.0, 1.0);

    // Outer ring — subtle track arc showing full range ±135° from top
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      -math.pi / 2 - math.pi * 3 / 4,   // start at bottom-left (-135°)
      math.pi * 3 / 2,                  // sweep through top to bottom-right (+135°)
      false,
      Paint()
        ..color = Colors.white.withAlpha(20)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round,
    );

    // Active arc — portion of the track that lights up proportional to |angle|
    if (activeLevel > 0.01) {
      final sweep = activeLevel * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        -math.pi / 2 + (angle < 0 ? -sweep : 0), // start from top, going left or right
        sweep * (angle >= 0 ? 1 : -1),
        false,
        Paint()
          ..color = Colors.white.withAlpha((40 + activeLevel * 215).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0
          ..strokeCap = StrokeCap.round,
      );
    }

    // Indicator line (rotary handle) — points outward from center at current angle
    final tipAngle = -math.pi / 2 + angle;   // -90° is top (neutral); positive goes right/clockwise
    final innerR = r * 0.5;
    final outerX = center.dx + math.cos(tipAngle) * r;
    final outerY = center.dy + math.sin(tipAngle) * r;
    final innerX = center.dx + math.cos(tipAngle) * innerR;
    final innerY = center.dy + math.sin(tipAngle) * innerR;

    canvas.drawLine(
      Offset(innerX, innerY),
      Offset(outerX, outerY),
      Paint()
        ..color = Colors.white.withAlpha((140 + activeLevel * 115).round())
        ..strokeWidth = 2.5,
    );

    // Center dot
    canvas.drawCircle(center, 3, Paint()..color = Colors.white60);
  }

  @override
  bool shouldRepaint(_KnobPainter old) => angle != old.angle;
}
