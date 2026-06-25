#!/usr/bin/env python3
"""Add Particle Burst visualizer - optimized to avoid GC pressure by reusing particle objects"""

with open('lib/main.dart', 'r') as f:
    content = f.read()

# Define the Particle Burst painter class
particle_burst_painter = '''

/// Particle Burst - Dots that "explode" outward from center when bands spike
/// Optimized to reuse particle objects to avoid GC pressure at ~7fps
class _ParticleBurstVizPainter extends CustomPainter {
  final FftFrame? frame;
  final double intensity;
  final List<double>? bandsOverride;
  
  static final Paint _particlePaint = Paint();
  
  // Pre-allocate particles to avoid GC (reused every frame)
  final List<_Particle> _particles = [];

  _ParticleBurstVizPainter({this.frame, this.intensity = 1.0, this.bandsOverride}) {
    // Initialize with 32 particles (one per band max)
    for (int i = 0; i < 32; i++) {
      _particles.add(_Particle());
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (frame == null || (bandsOverride ?? frame!.bands).isEmpty) return;

    final bands = bandsOverride ?? frame!.bands;
    final bandCount = math.min(bands.length, _particles.length);
    final step = (bands.length / bandCount).ceil();
    
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final maxRadius = math.min(size.width, size.height) * 0.4;

    // Clear inactive particles and update active ones
    for (int i = 0; i < bandCount && i * step < bands.length; i++) {
      double value = 0;
      int count = 0;
      for (int j = 0; j < step && i * step + j < bands.length; j++) {
        value += bands[i * step + j];
        count++;
      }
      if (count > 0) value /= count;
      
      final particle = _particles[i];
      
      // If band is active (value > threshold), trigger new burst
      if (value > 0.15) {
        particle.trigger(centerX, centerY, i * maxRadius / bandCount, value, intensity);
      }
      
      // Update particle position and opacity
      particle.update(0.92); // Decay factor (slows down over time)

      // Draw particle if still active
      if (particle.alpha > 0.01) {
        final offset = Offset(
          centerX + particle.dx,
          centerY + particle.dy,
        );
        
        _particlePaint.color = Color.fromRGBO(
          int(255 * value), 
          int(193 - value * 100), 
          int(7 + value * 50),
          particle.alpha * intensity,
        );
        
        canvas.drawCircle(offset, particle.size, _particlePaint);
      }
    }

    // Fade out any extra particles that are no longer active
    for (int i = bandCount; i < _particles.length; i++) {
      final particle = _particles[i];
      if (particle.alpha > 0.01) {
        particle.update(0.85); // Faster decay for unused slots
        
        final offset = Offset(
          centerX + particle.dx,
          centerY + particle.dy,
        );
        
        _particlePaint.color = Colors.grey.withOpacity(particle.alpha * intensity * 0.3);
        canvas.drawCircle(offset, particle.size * 0.5, _particlePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Internal particle class - simple struct-like to avoid GC
class _Particle {
  double dx = 0.0;
  double dy = 0.0;
  double vx = 0.0;
  double vy = 0.0;
  double alpha = 0.0;
  double size = 4.0;

  void trigger(double cx, double cy, double baseRadius, double value, double intensity) {
    // Random direction outward from center
    final angle = (DateTime.now().millisecondsSinceEpoch % 360000) / 1000.0 + (baseRadius * 0.01);
    final speed = (2.0 + value * 4.0) * intensity;
    
    vx = math.cos(angle) * speed;
    vy = math.sin(angle) * speed;
    
    // Start at center, move outward
    dx = 0.0;
    dy = 0.0;
    
    alpha = 1.0;
    size = 3.0 + value * 5.0 * intensity;
  }

  void update(double decay) {
    dx += vx;
    dy += vy;
    vx *= decay; // Slow down over time
    vy *= decay;
    alpha *= decay; // Fade out
    if (alpha < 0) alpha = 0;
  }
}

'''

# Remove the old dotWave painter class first
import re

# Pattern to match DotWaveVizPainter class
dotwave_pattern = r'/// Dot Wave.*?shouldRepaint\(covariant CustomPainter oldDelegate\) => true;\n}\n'
content = re.sub(dotwave_pattern, '', content, flags=re.DOTALL)

print('✓ Removed dotWave painter')

# Find insertion point before _VizTileState class (after all other painters)
viz_state_start = content.find('class _VizTileState extends State<_VizTile>')
if viz_state_start == -1:
    print('? Could not find insertion point')
else:
    content = content[:viz_state_start] + particle_burst_painter + content[viz_state_start:]
    print('✓ Added ParticleBurst painter class')

with open('lib/main.dart', 'w') as f:
    f.write(content)

print('Done!')
