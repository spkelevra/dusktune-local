#!/usr/bin/env python3
"""Add 4 new visualizer painters: Frequency Arcs, Energy Rings, Spectrum Line, Peak Bars"""

with open('lib/main.dart', 'r') as f:
    content = f.read()

# Define the 4 new painter classes
new_painters = '''

/// Frequency Arcs - Semi-circular arcs like classic car audio EQ displays
class _FrequencyArcsVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _arcPaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 4.0;

  const _FrequencyArcsVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = math.min(24, bands.length);
    final step = (bands.length / bandCount).ceil();
    
    final centerX = size.width / 2;
    final centerY = size.height; // Bottom of canvas
    final maxRadius = math.min(size.width * 0.45, size.height * 0.6);

    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final arcHeight = value * maxRadius * intensity;
      final startAngle = math.pi + (i / bandCount) * math.pi;
      final sweepAngle = -math.pi / bandCount * 0.8; // Slight gap between arcs
      
      _arcPaint.color = HSLColor.fromAHSL(1.0, i * (360.0 / bandCount), 0.8, value * 0.7 + 0.2).toColor();

      canvas.drawArc(
        Rect.fromCircle(center: Offset(centerX, centerY), radius: maxRadius - arcHeight),
        startAngle,
        sweepAngle,
        false,
        _arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Energy Rings - Circular rings where thickness/opacity = energy level
class _EnergyRingsVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _ringPaint = Paint();

  const _EnergyRingsVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = math.min(16, bands.length);
    final step = (bands.length / bandCount).ceil();
    
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final maxRadius = math.min(size.width, size.height) * 0.35;
    final baseThickness = 8.0;

    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final radius = baseThickness / 2 + i * (maxRadius - baseThickness) / bandCount;
      final thickness = baseThickness + value * baseThickness * 3 * intensity;
      _ringPaint.color = HSLColor.fromAHSL(1.0, i * (360.0 / bandCount), 0.75, 0.8).toColor();

      canvas.drawCircle(
        Offset(centerX, centerY),
        radius,
        _ringPaint..strokeWidth = thickness.clamp(baseThickness, baseThickness * 4)..style = PaintingStyle.stroke
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Spectrum Line Fill - Classic spectrum analyzer with filled area under line
class _SpectrumLineVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _linePaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.0;
  static final Paint _fillPaint = Paint();

  const _SpectrumLineVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = bands.length.clamp(32, 64);
    final step = (bands.length / bandCount).ceil();
    
    final path = Path();
    final maxY = size.height * 0.85;

    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final x = (i / (bandCount - 1)) * size.width;
      final y = size.height - value * maxY * intensity;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        // Smooth curve using linear interpolation for simplicity
        path.lineTo(x, y);
      }
    }

    // Fill area under line with gradient-like color
    _fillPaint.color = Colors.purple.withOpacity(0.4 * intensity);
    canvas.drawPath(path..lineTo(size.width, size.height)..lineTo(0, size.height)..close(), _fillPaint);

    // Draw the top line
    _linePaint.color = Colors.purple.withOpacity(intensity);
    canvas.drawPath(path, _linePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Peak Bars - Instantaneous bars without memory decay (raw response)
class _PeakBarsVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _paint = Paint();

  const _PeakBarsVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final barCount = bands.length.clamp(24, 64);
    final step = (bands.length / barCount).ceil();
    final barWidth = size.width / barCount;

    for (int i = 0; i < barCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final barHeight = value * size.height * intensity;
      
      // Gradient from cyan to blue based on height
      _paint.color = Color.lerp(
        Colors.cyan.withOpacity(intensity),
        Colors.blue.withOpacity(intensity * 1.5),
        value,
      )!;

      canvas.drawRect(
        Rect.fromLTWH(i * barWidth, size.height - barHeight, barWidth - 2, barHeight),
        _paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

'''

# Find insertion point before _VizTileState class
viz_state_start = content.find('class _VizTileState extends State<_VizTile>')
if viz_state_start == -1:
    print('? Could not find insertion point')
else:
    content = content[:viz_state_start] + new_painters + content[viz_state_start:]
    print('✓ Added 4 new painter classes (Frequency Arcs, Energy Rings, Spectrum Line, Peak Bars)')

with open('lib/main.dart', 'w') as f:
    f.write(content)

print('Done!')
