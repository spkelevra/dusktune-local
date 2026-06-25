#!/usr/bin/env python3
"""Add 4 new visualizer painters to main.dart"""

with open('lib/main.dart', 'r') as f:
    content = f.read()

# Define the 4 new painter classes
new_painters = '''

/// Gradient Bars - Rainbow-colored bars by frequency band
class _GradientBarsVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _paint = Paint();

  const _GradientBarsVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final barCount = bands.length.clamp(16, 64);
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
      
      // Rainbow gradient by frequency band (blue -> green -> yellow -> red)
      final hue = i * (360.0 / barCount);
      _paint.color = HSLColor.fromAHSL(1.0, hue, 0.85, value * 0.7 + 0.2).toColor();

      canvas.drawRect(
        Rect.fromLTWH(i * barWidth, size.height - barHeight, barWidth - 2, barHeight),
        _paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Smooth Wave with Gradient Fill - Enhanced wave with filled area under curve
class _SmoothWaveVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _strokePaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.0;
  static final Paint _fillPaint = Paint();

  const _SmoothWaveVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = bands.length.clamp(16, 64);
    final step = (bands.length / bandCount).ceil();
    
    final path = Path();
    final centerY = size.height / 2;
    final maxAmp = size.height * 0.35;

    // Build smooth curve through averaged bands
    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final x = (i / (bandCount - 1)) * size.width;
      final amp = value * maxAmp * intensity;
      final y = centerY + amp;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        // Simple smooth curve using quadratic bezier
        final prevX = ((i - 1) / (bandCount - 1)) * size.width;
        final prevY = centerY + bands[(i - 1) * step.clamp(0, bands.length - 1)] * maxAmp * intensity;
        final cpX = (prevX + x) / 2;
        path.quadraticBezierTo(prevX, prevY, cpX, (y + prevY) / 2);
      }
    }

    // Draw filled area under curve with gradient-like color
    _fillPaint.color = Colors.cyan.withOpacity(0.3 * intensity);
    canvas.drawPath(path..close(), _fillPaint);

    // Draw wave line
    _strokePaint.color = Colors.cyan.withOpacity(intensity);
    canvas.drawPath(path, _strokePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Circle Rings - Concentric circles expanding/contracting with bands
class _CircleRingsVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _ringPaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 3.0;

  const _CircleRingsVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = math.min(12, bands.length); // Use fewer rings for clarity
    final step = (bands.length / bandCount).ceil();
    
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final maxRadius = math.min(size.width, size.height) * 0.35;
    final baseRadius = 20.0;
    final ringSpacing = (maxRadius - baseRadius) / bandCount;

    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final radius = baseRadius + i * ringSpacing + value * ringSpacing * intensity;
      
      // Color shifts from blue to red as frequency increases
      _ringPaint.color = HSLColor.fromAHSL(1.0, i * (360.0 / bandCount), 0.8, value * 0.7 + 0.2).toColor();

      canvas.drawCircle(Offset(centerX, centerY), radius.clamp(baseRadius, maxRadius), _ringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Dot Matrix - Grid of dots sized by band intensity (retro LED style)
class _DotMatrixVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _dotPaint = Paint();

  const _DotMatrixVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride});

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    
    // Create a grid: columns for frequency, rows for time/height
    final colCount = 16;
    final rowCount = 8;
    final step = (bands.length / colCount).ceil();
    
    final dotSizeX = size.width / (colCount + 2);
    final dotSizeY = size.height / (rowCount + 2);

    for (int col = 0; col < colCount && col * step < bands.length; col++) {
      // Average band value for this column
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && col * step + j < bands.length; j++) {
        value += bands[col * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      // Calculate how many dots should light up in this column
      final activeDots = (value * rowCount * intensity).round().clamp(0, rowCount);

      for (int row = 0; row < rowCount; row++) {
        final x = dotSizeX + col * dotSizeX;
        final y = size.height - dotSizeY - (row + 1) * dotSizeY;
        
        // Larger and brighter dots at bottom, smaller/faded at top
        final isActive = row < activeDots;
        final scale = isActive ? (0.6 + value * 0.4) : 0.3;
        _dotPaint.color = isActive 
            ? HSLColor.fromAHSL(1.0, 180 + value * 60, 0.7, value * 0.9).toColor()
            : Colors.grey.withOpacity(0.2);

        canvas.drawCircle(Offset(x, y), dotSizeX * scale * 0.4, _dotPaint);
      }
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
    print('✓ Added 4 new painter classes')

with open('lib/main.dart', 'w') as f:
    f.write(content)

print('Done!')
