/// Generates unique monochrome patterns from song titles for the Top 9 grid.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Creates a deterministic [Canvas] painter from a string seed (song title).
/// All colors are strictly shades of black/grey — no color tints.
///
/// [sunlightFactor] controls how much the background blends toward mid-grey:
///   0.0 = normal dark tile, 1.0 = fully desaturated grey (direct sunlight mode).
class TitlePatternPainter extends CustomPainter {
  final String seed;
  final double sunlightFactor;

  TitlePatternPainter(this.seed, {this.sunlightFactor = 0.0}) : _hash = _computeHash(seed);

  static int _computeHash(String s) {
    int h = 0;
    for (int i = 0; i < s.codeUnits.length; i++) {
      h = ((h << 5) - h + s.codeUnits[i]) & 0xFFFFFFFF;
    }
    return h;
  }

  final int _hash;

  /// Returns a deterministic random from the hash.
  double _rand(int index) {
    var state = (_hash + index * 2654435761) & 0xFFFFFFFF;
    return (state % 10000) / 10000.0;
  }

  /// Linear interpolation with clamping to [0, 1].
  double _lerp(double a, double b, double t) => a + (b - a) * t.clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final center = Offset(w / 2, h / 2);

    // Background: dark grey gradient (no color tints)
    final bg1 = 18 + _rand(0).round() * 15;   // 18-33 range
    final bg2 = 8 + _rand(1).round() * 12;     // 8-20 range

    // Blend toward mid-grey (value ~80) when in sunlight.
    // At sunlightFactor=1.0, bg becomes a uniform mid-grey tile for readability.
    final blendedBg1 = _lerp(bg1.toDouble(), 75.0 + (_rand(30).round() * 15).toDouble(), sunlightFactor);   // 75-90 grey in sun
    final blendedBg2 = _lerp(bg2.toDouble(), 65.0 + (_rand(31).round() * 10).toDouble(), sunlightFactor);   // 65-75 grey in sun

    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = Color.fromRGBO(blendedBg1.round(), blendedBg1.round(), blendedBg1.round(), 1.0),
    );

    // Subtle gradient overlay — also brightened in sunlight
    final gradPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.transparent,
          Color.fromRGBO(blendedBg2.round(), blendedBg2.round(), blendedBg2.round(), 0.8),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));

    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), gradPaint);

    // Boost ring alpha in sunlight so patterns remain visible against lighter bg
    final alphaBoost = 1.0 + sunlightFactor * 2.5; // up to 3.5x brighter rings

    // Concentric circles only — multiple randomized variations
    final variation = _hash % 8;
    final ringCount = 3 + (_hash % 12);   // 3-14 rings (sparse to dense)
    final baseAlpha = 0.06 + _rand(6) * 0.12;

    switch (variation) {
      case 0: // Sparse evenly spaced — sonar ping style (fewer rings, wide gaps)
        for (int i = 0; i < ringCount; i++) {
          final t = (i + 1) / (ringCount + 1);
          final radius = w * 0.45 * t;
          final alpha = (baseAlpha * (1 - t * 0.6)) * alphaBoost;
          canvas.drawCircle(
            center,
            radius,
            Paint()
              ..color = Colors.white.withValues(alpha: alpha)
              ..strokeWidth = 0.8 + _rand(10 + i) * 0.5
              ..style = PaintingStyle.stroke,
          );
        }
        break;

      case 1: // Dense evenly spaced with strong fade outward
        for (int i = 0; i < ringCount; i++) {
          final t = (i + 1) / (ringCount + 1);
          final radius = w * 0.45 * t;
          final alpha = (baseAlpha * math.pow(1 - t, 1.5)) * alphaBoost;
          canvas.drawCircle(
            center,
            radius,
            Paint()
              ..color = Colors.white.withValues(alpha: alpha)
              ..strokeWidth = 0.4 + _rand(20 + i) * 0.6
              ..style = PaintingStyle.stroke,
          );
        }
        break;

      case 2: // Tight inner rings, wider outer spacing (ripple effect)
        for (int i = 0; i < ringCount; i++) {
          final t = (i + 1) / (ringCount + 1);
          final radius = w * 0.45 * math.pow(t, 0.6);
          final alpha = (baseAlpha * (1 - t * 0.5)) * alphaBoost;
          canvas.drawCircle(
            center,
            radius,
            Paint()
              ..color = Colors.white.withValues(alpha: alpha)
              ..strokeWidth = 0.4 + _rand(30 + i) * 0.8
              ..style = PaintingStyle.stroke,
          );
        }
        break;

      case 3: // Wide outer rings, sparse inner (reverse ripple)
        for (int i = 0; i < ringCount; i++) {
          final t = (i + 1) / (ringCount + 1);
          final radius = w * 0.45 * math.pow(t, 1.4);
          final alpha = (baseAlpha * (0.3 + _rand(40 + i) * 0.7) * (1 - t * 0.4)) * alphaBoost;
          canvas.drawCircle(
            center,
            radius,
            Paint()
              ..color = Colors.white.withValues(alpha: alpha)
              ..strokeWidth = 0.5 + _rand(50 + i) * 1.5
              ..style = PaintingStyle.stroke,
          );
        }
        break;

      case 4: // Variable ring thickness with organic feel
        for (int i = 0; i < ringCount; i++) {
          final t = (i + 1) / (ringCount + 1);
          final radius = w * 0.45 * t;
          final alpha = (baseAlpha * (0.4 + _rand(60 + i) * 0.6) * (1 - t * 0.5)) * alphaBoost;
          canvas.drawCircle(
            center,
            radius,
            Paint()
              ..color = Colors.white.withValues(alpha: alpha)
              ..strokeWidth = 0.3 + _rand(70 + i) * 2.8
              ..style = PaintingStyle.stroke,
          );
        }
        break;

      case 5: // Offset center — organic ripple / water drop look
        final offsetX = (_rand(80) - 0.5) * w * 0.1;
        final offsetY = (_rand(81) - 0.5) * h * 0.1;
        final offCenter = Offset(center.dx + offsetX, center.dy + offsetY);
        for (int i = 0; i < ringCount; i++) {
          final t = (i + 1) / (ringCount + 1);
          final radius = w * 0.45 * t;
          final alpha = (baseAlpha * (1 - t * 0.6)) * alphaBoost;
          canvas.drawCircle(
            offCenter,
            radius,
            Paint()
              ..color = Colors.white.withValues(alpha: alpha)
              ..strokeWidth = 0.4 + _rand(90 + i) * 1.0
              ..style = PaintingStyle.stroke,
          );
        }
        break;

      case 6: // Alternating thin/thick rings (target reticle style)
        for (int i = 0; i < ringCount; i++) {
          final t = (i + 1) / (ringCount + 1);
          final radius = w * 0.45 * t;
          final alpha = (baseAlpha * (1 - t * 0.55)) * alphaBoost;
          final isThick = i % 2 == 0;
          canvas.drawCircle(
            center,
            radius,
            Paint()
              ..color = Colors.white.withValues(alpha: alpha)
              ..strokeWidth = isThick ? (1.5 + _rand(100 + i) * 1.5) : (0.3 + _rand(110 + i) * 0.4)
              ..style = PaintingStyle.stroke,
          );
        }
        break;

      case 7: // Minimalist — very few rings with bold strokes and central dot
        final minRings = math.max(3, ringCount ~/ 2);
        for (int i = 0; i < minRings; i++) {
          final t = (i + 1) / (minRings + 1);
          final radius = w * 0.45 * t;
          final alpha = (baseAlpha * (1 - t * 0.5)) * alphaBoost;
          canvas.drawCircle(
            center,
            radius,
            Paint()
              ..color = Colors.white.withValues(alpha: alpha)
              ..strokeWidth = 1.0 + _rand(120 + i) * 1.8
              ..style = PaintingStyle.stroke,
          );
        }
        // Central dot
        canvas.drawCircle(
          center,
          w * 0.03,
          Paint()
            ..color = Colors.white.withValues(alpha: baseAlpha * 0.8 * alphaBoost)
            ..style = PaintingStyle.fill,
        );
        break;
    }

    // Large initial letter of the title overlaid subtly
    if (seed.isNotEmpty) {
      final letter = seed[0].toUpperCase();
      final textPainter = TextPainter(
        text: TextSpan(
          text: letter,
          style: TextStyle(
            fontSize: w * 0.55,
            fontWeight: FontWeight.w100,
            color: Colors.white.withValues(alpha: (0.04 + _rand(80) * 0.05) * alphaBoost),
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(center.dx - textPainter.width / 2, center.dy - textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(TitlePatternPainter oldDelegate) => seed != oldDelegate.seed || sunlightFactor != oldDelegate.sunlightFactor;
}

/// Widget that displays a monochrome geometric pattern based on song title.
class TitlePattern extends StatelessWidget {
  final String title;
  final double sunlightFactor;

  const TitlePattern({super.key, required this.title, this.sunlightFactor = 0.0});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: TitlePatternPainter(title, sunlightFactor: sunlightFactor),
      size: Size.infinite,
    );
  }
}

/// Widget that shows album artwork if available, otherwise falls back to TitlePattern.
class AlbumArtTile extends StatelessWidget {
  final String title;
  final Uint8List? artworkBytes;
  final double sunlightFactor;

  const AlbumArtTile({
    super.key,
    required this.title,
    this.artworkBytes,
    this.sunlightFactor = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    if (artworkBytes != null && artworkBytes!.isNotEmpty) {
      return Image.memory(
        artworkBytes!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => TitlePattern(title: title, sunlightFactor: sunlightFactor),
      );
    }
    return TitlePattern(title: title, sunlightFactor: sunlightFactor);
  }
}

/// Small album art thumbnail for list items (leading icon).
class AlbumArtThumbnail extends StatelessWidget {
  final String title;
  final Uint8List? artworkBytes;
  final double size;

  const AlbumArtThumbnail({
    super.key,
    required this.title,
    this.artworkBytes,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    if (artworkBytes != null && artworkBytes!.isNotEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(
            artworkBytes!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallbackIcon(),
          ),
        ),
      );
    }
    return _fallbackIcon();
  }

  Widget _fallbackIcon() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.music_note, size: 18, color: Colors.white24),
    );
  }
}
