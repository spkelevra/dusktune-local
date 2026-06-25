#!/usr/bin/env python3
"""Add 4 final easy visualizer painters: Line Fill, Bar Stack, Ring Pulse, Dot Wave"""

with open('lib/main.dart', 'r') as f:
    content = f.read()

# Define the 4 new painter classes - simple, efficient, use same FFT data
new_painters = '''

/// Line Fill - Clean line with transparent fill underneath (minimalist)
class _LineFillVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _linePaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 3.0;
  static final Paint _fillPaint = Paint();

  const _LineFillVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = math.min(40, bands.length);
    final step = (bands.length / bandCount).ceil();
    
    final path = Path();
    final maxY = size.height * 0.8;
    final baseY = size.height * 0.15;

    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final x = (i / (bandCount - 1)) * size.width;
      final y = baseY + (1.0 - value) * maxY * intensity;

      if (i == 0) {
        path.moveTo(x, baseY);
        path.lineTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // Draw line with gradient color
    _linePaint.color = Colors.teal.withOpacity(intensity);
    canvas.drawPath(path, _linePaint);

    // Fill below with transparency
    path.lineTo(size.width, baseY);
    path.lineTo(0, baseY);
    path.close();
    
    _fillPaint.color = Colors.teal.withOpacity(intensity * 0.2);
    canvas.drawPath(path, _fillPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Bar Stack - Multiple stacked bars showing frequency bands in groups
class _BarStackVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _paint = Paint();

  const _BarStackVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    
    // Create 8 wide columns, each showing an average of its frequency range
    final colCount = 8;
    final step = (bands.length / colCount).ceil();
    final barWidth = size.width / colCount - 4;

    for (int col = 0; col < colCount && col * step < bands.length; col++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && col * step + j < bands.length; j++) {
        value += bands[col * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final barHeight = value * size.height * intensity;
      final x = col * (barWidth + 4);
      
      // Stack effect: draw multiple segments with different opacities
      final segCount = 3;
      for (int seg = 0; seg < segCount; seg++) {
        final segHeight = barHeight / segCount;
        final segY = size.height - barHeight + (seg * segHeight);
        final alpha = 1.0 - (seg / segCount) * 0.5;
        
        _paint.color = Color.fromRGBO(
          76.0 + seg * 30, // R increases slightly
          175.0 - seg * 20, // G decreases
          46.0 + seg * 10, // B increases slightly  
          alpha * intensity,
        );

        canvas.drawRect(
          Rect.fromLTWH(x, segY, barWidth, segHeight),
          _paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Ring Pulse - Rings that pulse in thickness and opacity based on energy
class _RingPulseVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _ringPaint = Paint();

  const _RingPulseVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = math.min(12, bands.length);
    final step = (bands.length / bandCount).ceil();
    
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final maxRadius = math.min(size.width, size.height) * 0.35;

    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final radius = (i + 1) * (maxRadius / bandCount);
      final thickness = 2.0 + value * 8.0 * intensity; // Thickness varies with energy
      final alpha = 0.3 + value * 0.7 * intensity;

      _ringPaint
        ..color = Color.fromRGBO(
          156.0 + i * 10, // Gradient through purple/magenta
          39.0 - i * 2,
          233.0 - i * 5,
          alpha,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness;

      canvas.drawCircle(Offset(centerX, centerY), radius, _ringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Dot Wave - Dots arranged in a wave pattern that follows the frequency curve
class _DotWaveVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _dotPaint = Paint();

  const _DotDotWaveVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = math.min(32, bands.length);
    final step = (bands.length / bandCount).ceil();
    
    final baseY = size.height / 2;
    final maxAmp = size.height * 0.35;

    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final x = (i / (bandCount - 1)) * size.width;
      final y = baseY - value * maxAmp * intensity;
      final dotSize = 4.0 + value * 8.0 * intensity;

      _dotPaint.color = Color.fromRGBO(
        255.0, // Full red
        193.0 - value * 100, // Yellow to orange
        7.0 + value * 20, // Slight green tint
        0.8 * intensity,
      );

      canvas.drawCircle(Offset(x, y), dotSize / 2, _dotPaint);
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
    print('✓ Added 4 final painter classes (Line Fill, Bar Stack, Ring Pulse, Dot Wave)')

with open('lib/main.dart', 'w') as f:
    f.write(content)

print('Done!')
