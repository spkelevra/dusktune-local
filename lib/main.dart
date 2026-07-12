/// DuskTune — a music player app.
library;

import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'app_theme.dart';
import 'models/song.dart';
import 'services/artwork_extractor.dart';
import 'services/audio_player.dart';
import 'services/music_library.dart';
import 'services/music_scanner.dart' as desktop_scanner;
import 'services/app_settings.dart';
import 'widgets/rotary_filter_knob.dart';
import 'widgets/tile_pattern.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';
import 'audio/fft_isolate.dart';
import 'dart:async';
import 'settings/settings_content.dart';

/// Returns true if running on a desktop platform (Windows, macOS, Linux).
/// Returns a display artist for any song — uses the actual artist name,
/// falls back to the parent folder name from the file path if unknown.
String songDisplayArtist(Song song) {
  final artist = song.artist;
  if (artist != null &&
      artist.isNotEmpty &&
      artist.toLowerCase() != 'unknown artist') {
    return artist;
  }
  final uri = song.uri;
  final separator = uri.contains(r'\') ? r'\' : '/';
  final parts = uri.split(separator);
  if (parts.length >= 2) {
    return parts[parts.length - 2];
  }
  return '';
}

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AudioPlayerService.init();
  runApp(const DuskTuneApp());
}

/// Easter egg: if the user sets their app title to "dawntune" (case-insensitive),
/// the entire app theme inverts to a light/white palette.
class DuskTuneApp extends StatefulWidget {
  const DuskTuneApp({super.key});

  @override
  State<DuskTuneApp> createState() => _DuskTuneAppState();
}

class _DuskTuneAppState extends State<DuskTuneApp> {
  ThemeData _theme = appDarkTheme;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  /// Load the app name and apply the appropriate theme.
  Future<void> _loadTheme() async {
    final name = await AppSettings.loadAppName();
    if (mounted && name.toLowerCase().startsWith('dawntune')) {
      setState(() => _theme = appLightTheme);
    }
  }

  /// Re-evaluate the theme (called by [AppRoot] when the app name changes).
  void refreshTheme() {
    _loadTheme();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dusktune',
      debugShowCheckedModeBanner: false,
      theme: _theme,
      home: AppRoot(onThemeRefresh: refreshTheme),
    );
  }
}

class AppRoot extends StatefulWidget {
  final VoidCallback onThemeRefresh;
  const AppRoot({required this.onThemeRefresh, super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  bool _isLoading = true;
  List<Song> _songs = [];
  int _tabIndex = 0; // 0=home, 1=library, 2=mixes, 3=favorites, 4=settings (desktop)
  bool _needsFolderSetup = false; // Desktop: no music folders configured yet
  
  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final library = MusicLibrary();
    final hasPermission = await library.requestPermission();
    if (!hasPermission) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // On desktop, check if music folders are configured
    if (_isDesktop) {
      final hasFolders = await library.hasMusicFolders();
      if (!hasFolders && mounted) {
        setState(() {
          _needsFolderSetup = true;
          _isLoading = false;
        });
        return;
      }
    }

    try {
      final songs = await library.init();
      if (mounted) {
        setState(() {
          _songs = songs;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('AppRoot _loadLibrary error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Re-scan music folders after settings change.
  Future<int> rescanLibrary() async {
    final library = MusicLibrary();
    try {
      final songs = await library.rescan();
      if (mounted) {
        setState(() {
          _songs = songs;
          _needsFolderSetup = false;
        });
      }
      return songs.length;
    } catch (e, st) {
      debugPrint('AppRoot rescanLibrary error: $e\n$st');
      return 0;
    }
  }

  void setTab(int index) => setState(() => _tabIndex = index);

  /// Toggle album art display setting. On mobile closes the app; on desktop shows restart prompt.
  Future<void> toggleAlbumArt(bool enabled) async {
    await AppSettings.saveShowAlbumArt(enabled);
    
    // No full rescan triggered on toggle — artwork extracts lazily

    if (_isDesktop) {
      // Desktop: SystemNavigator.pop() doesn't work — show restart prompt instead
      // The snackbar is shown by the caller; we just return here
      return;
    } else {
      // Mobile: close app safely — try SystemNavigator first, ignore if it fails.
      try {
        SystemNavigator.pop();
      } catch (_) {}
    }
  }

  /// Rescan album artwork — sets flag. On mobile closes; on desktop shows restart prompt.
  Future<void> rescanAlbumArt() async {
    await AppSettings.saveRescanFlag(true);

    if (_isDesktop) {
      return; // Desktop: caller handles snackbar with restart message
    } else {
      try {
        SystemNavigator.pop();
      } catch (_) {}
    }
  }

  /// Clear the artwork cache from disk.
  Future<void> clearArtworkCache() async {
    await AppSettings.clearArtworkCache();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
          ),
        ),
      );
    }

    // Desktop: show folder setup screen if no music folders configured
    if (_needsFolderSetup && _isDesktop) {
      return _DesktopFolderSetup(
        onReady: () async {
          await rescanLibrary();
        },
      );
    }

    return DuskTuneShell(
       allSongs: _songs,
       tabIndex: _tabIndex,
       onTabChanged: setTab,
       isDesktop: _isDesktop,
       onThemeRefresh: widget.onThemeRefresh,
       onRescanLibrary: rescanLibrary,
       onToggleAlbumArt: toggleAlbumArt,
      );
    }
    }
/// Visualizer style enum — persisted as string.
enum _VizStyle { bars, wave, dots, circles, peakhold }

class _BarsVizPainter extends CustomPainter {
  final List<double>? bandsOverride;
  final bool isPlaying;
  final double intensity;

  static final Paint _paint = Paint();

  const _BarsVizPainter({this.bandsOverride, this.isPlaying = false, this.intensity = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsOverride;
    if (bands == null || bands.isEmpty) return;

    final barWidth = size.width / bands.length - 1.0;

    for (int i = 0; i < bands.length; i++) {
      final value = bands[i];
      final effectiveValue = math.min(1.0, value * intensity);
      final barHeight = math.max(1.0, effectiveValue * size.height);

      _paint.color = Colors.grey[350]!.withOpacity(math.min(1.0, 0.4 + effectiveValue * 0.6));

      canvas.drawRect(
        Rect.fromLTWH(i * (barWidth + 1.0), size.height - barHeight, barWidth, barHeight),
        _paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsVizPainter old) => true;
}

/// Waveform-style visualizer -- smooth wave envelope driven by FFT bands.
class _WaveVizPainter extends CustomPainter {
  final List<double>? bandsOverride;
  final double intensity;

  static final Paint _paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5;

  const _WaveVizPainter({this.bandsOverride, this.intensity = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsOverride;
    if (bands == null || bands.isEmpty) return;

    final bandCount = bands.length;
    final path = Path()..moveTo(0, size.height * 0.5);

    for (int i = 0; i < bandCount; i++) {
      final value = bands[i];
      final x = (i / bandCount) * size.width;
      final effectiveValue = math.min(1.0, value * intensity);
      final y = size.height * 0.5 - effectiveValue * size.height * 0.4;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // Mirror the bottom half for symmetry
    final mirrorPath = Path()..moveTo(size.width, size.height * 0.5);
    for (int i = bandCount - 1; i >= 0; i--) {
      final value = bands[i];
      final x = (i / bandCount) * size.width;
      final effectiveValueMirror = math.min(1.0, value * intensity);
      final y = size.height * 0.5 + effectiveValueMirror * size.height * 0.4;
      mirrorPath.lineTo(x, y);
    }
    path.addPath(mirrorPath, Offset.zero);

    _paint.color = Colors.grey[350]!.withOpacity(0.8);
    canvas.drawPath(path, _paint);
  }

  @override
  bool shouldRepaint(_WaveVizPainter old) => true;
}

/// Dot-matrix visualizer — grid of dots whose brightness follows FFT bands.
class _DotsVizPainter extends CustomPainter {
  final List<double>? bandsOverride;
  final double intensity;

  static final Paint _paint = Paint();

  const _DotsVizPainter({this.bandsOverride, this.intensity = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsOverride;
    if (bands == null || bands.isEmpty) return;

    const cols = 16;
    const rows = 8;
    final bandCount = bands.length;

    final baseDotRadius = math.min(size.width / (cols * 2.5), size.height / (rows * 2.5));

    for (int col = 0; col < cols; col++) {
      for (int row = 0; row < rows; row++) {
        final bandIdx = ((col * rows + row) * bandCount) ~/ (cols * rows);
        if (bandIdx >= bands.length) continue;

        final value = bands[bandIdx];
        final effectiveValueDots = math.min(1.0, value * intensity);
        final opacity = math.max(0.1, math.min(1.0, 0.3 + effectiveValueDots * 0.7));
        final dotRadius = baseDotRadius * (0.5 + effectiveValueDots * 1.0);
        final x = (col + 0.5) * (size.width / cols);
        final y = size.height - (row + 0.5) * (size.height / rows) - effectiveValueDots * baseDotRadius;

        _paint.color = Colors.grey[350]!.withOpacity(opacity);
        canvas.drawCircle(Offset(x, y), dotRadius, _paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotsVizPainter old) => true;
}


/// Radar-style visualizer -- concentric rings whose radii expand with FFT energy.
class _CirclesVizPainter extends CustomPainter {
  final double intensity;
  /// Pre-aggregated display bars (32 values, 0..1). No inner aggregation needed.
  final List<double>? displayBars;
  /// Reusable Paint -- avoids allocating one per ring at 60fps.
  static final Paint _paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5;

  const _CirclesVizPainter({this.intensity = 1.0, this.displayBars});

  @override
  void paint(Canvas canvas, Size size) {
    final bars = displayBars;
    if (bars == null || bars.isEmpty) return;
    const ringCount = 12;
    // Aggregate the 32 display bars down to 12 rings -- simple subsampling
    final barsPerRing = (bars.length / ringCount).floor();

    final centerX = size.width * 0.5;
    final centerY = size.height * 0.5;
    final maxRadius = math.min(centerX, centerY) - 4.0;

    for (int i = 0; i < ringCount; i++) {
      // Average a few display bars per ring for smoother rings
      double value = 0;
      int count = 0;
      final startIdx = i * barsPerRing;
      final endIdx = math.min(startIdx + barsPerRing, bars.length);
      for (int j = startIdx; j < endIdx; j++) {
        value += bars[j];
        count++;
      }
      if (count > 0) value /= count;

      final effectiveValue = math.min(1.0, value * intensity);
      final baseRadius = maxRadius * ((i + 1) / ringCount);
      final radius = math.max(2.0, baseRadius * (0.3 + effectiveValue * 0.7));

      // Apply smoothing to opacity: higher smoothing = more opaque rings
      final opacity = math.min(1.0, 0.3 + effectiveValue * 0.7);
      _paint.color = Colors.grey[350]!.withOpacity(opacity);
      canvas.drawCircle(Offset(centerX, centerY), radius, _paint);
    }
  }

  @override
  bool shouldRepaint(_CirclesVizPainter old) => true;
}

/// Peak Hold visualizer — bars with a small peak indicator that decays slowly, showing energy history.
class _PeakHoldVizPainter extends CustomPainter {
  final List<double>? bandsOverride;
  final List<double>? peakHoldOverride;
  final double intensity;

  static final Paint _paint = Paint();
  static final Paint _mainPaint = Paint()..style = PaintingStyle.fill;

  const _PeakHoldVizPainter({this.bandsOverride, this.peakHoldOverride, this.intensity = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsOverride;
    if (bands == null || bands.isEmpty) return;

    final bandCount = bands.length;
    final barWidth = size.width / bandCount - 1.0;
    final peaks = peakHoldOverride;

    for (int i = 0; i < bandCount; i++) {
      final value = bands[i];
      final effectiveValue = math.min(1.0, value * intensity);
      final barHeight = math.max(1.0, effectiveValue * size.height);

      // Main bar
      _paint.color = Colors.grey[350]!.withOpacity(math.min(1.0, 0.4 + effectiveValue * 0.6));
      canvas.drawRect(
        Rect.fromLTWH(i * (barWidth + 1.0), size.height - barHeight, barWidth, barHeight),
        _paint,
      );

      // Peak hold indicator: small white line at peak level from isolate.
      final peakValue = peaks != null && peaks.length > i
          ? math.min(1.0, peaks[i])
          : math.min(1.0, effectiveValue + 0.15);
      final peakHeight = math.max(2.0, peakValue * size.height);

      _mainPaint.color = Colors.white.withOpacity(0.9);
      canvas.drawRect(
        Rect.fromLTWH(i * (barWidth + 1.0), size.height - peakHeight, barWidth, 2.5),
        _mainPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_PeakHoldVizPainter old) => true;
}


/// Isolated visualizer tile -- manages its own FFT subscription.
/// Rebuilds independently from the shell, so grid tiles don't re-layout at 30 Hz on Android.
class _VizTile extends StatefulWidget {
  final String songTitle;
  const _VizTile({required this.songTitle, super.key});

  @override
  State<_VizTile> createState() => _VizTileState();
}

class _VizTileState extends State<_VizTile> with TickerProviderStateMixin {
  /// Latest processed visualiser data from the FFT isolate.
  VisualizerData? _vizData;
  StreamSubscription<VisualizerData>? _sub;
  late final AnimationController _fadeCtrl;
  /// Interpolated display bars for circles visualizer (32 values, 0..1).
  final List<double> _displayBars = List<double>.filled(32, 0.0);
  /// Target display bars from the latest FFT frame.
  final List<double> _targetBars = List<double>.filled(32, 0.0);
  /// Animation controller drives 60fps interpolation between FFT frames (circles only).
  late final AnimationController _interpCtrl;
  late final Animation<double> _interpTween;
  /// Notifier that triggers painter repaints at 60fps without widget rebuilds.
  final _vizNotifier = ValueNotifier<int>(0);
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    // 60fps interpolation controller for circles visualizer.
    _interpCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 16));
    _interpTween = CurvedAnimation(parent: _interpCtrl, curve: Curves.linear);
    _interpTween.addListener(_onInterpTick);
    // Listen to processed visualiser stream from the FFT isolate.
    // Smoothing + band aggregation are done off the UI thread.
    _sub = AudioPlayerService.processedVizStream.listen(_onVizData);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _interpCtrl.stop();
    _vizNotifier.dispose();
    _interpTween.removeListener(_onInterpTick);
    _interpCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  /// 60fps ticker — EMA interpolation toward target for ALL styles.
  void _onInterpTick() {
    const alpha = 0.15; // per-frame blend factor
    for (int i = 0; i < 32; i++) {
      _displayBars[i] += alpha * (_targetBars[i] - _displayBars[i]);
    }
    _vizNotifier.value = ++_tick;
  }

  /// New frame from isolate — update target.
  void _onVizData(VisualizerData data) {
    _vizData = data;
    for (int i = 0; i < 32 && i < data.displayBars.length; i++) {
      _targetBars[i] = math.min(1.0, data.displayBars[i]);
    }
    if (!_interpCtrl.isAnimating) _interpCtrl.repeat();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: _fadeCtrl..forward(),
        curve: Curves.easeOut,
      ),
      child: RepaintBoundary(
        child: ValueListenableBuilder<int>(
          valueListenable: _vizNotifier,
          builder: (context, _, child) {
            return CustomPaint(painter: _vizPainter());
          },
        ),
      ),
    );
  }

  _VizStyle get _style {
    final s = AudioPlayerService.vizStyle;
    switch (s) {
      case 'wave':     return _VizStyle.wave;
      case 'dots':     return _VizStyle.dots;
      case 'circles':  return _VizStyle.circles;
      case 'peakhold': return _VizStyle.peakhold;
      default:        return _VizStyle.bars;
    }
  }

  CustomPainter _vizPainter() {
    final intensity = AudioPlayerService.vizIntensity;
    switch (_style) {
      case _VizStyle.wave:     return _WaveVizPainter(bandsOverride: _displayBars, intensity: intensity);
      case _VizStyle.dots:     return _DotsVizPainter(bandsOverride: _displayBars, intensity: intensity);
      case _VizStyle.circles:  return _CirclesVizPainter(displayBars: _displayBars, intensity: intensity);
      case _VizStyle.peakhold: return _PeakHoldVizPainter(bandsOverride: _displayBars, peakHoldOverride: _vizData?.peakHold, intensity: intensity);
      default:                 return _BarsVizPainter(bandsOverride: _displayBars, isPlaying: AudioPlayerService.isPlaying, intensity: intensity);
    }
  }
}


/// Intensity slider widget with real-time percentage label.
class _VizIntensitySlider extends StatefulWidget {
  final double initialValue;
  final ValueChanged<double> onSaved;

  const _VizIntensitySlider({required this.initialValue, required this.onSaved});

  @override
  State<_VizIntensitySlider> createState() => _VizIntensitySliderState();
}

class _VizIntensitySliderState extends State<_VizIntensitySlider> {
  double _value = 1.0;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  void _onChanged(double v) {
    setState(() => _value = v);
    AppSettings.saveVizIntensity(v).then((_) {
      AudioPlayerService.vizIntensity = v;
    });
    widget.onSaved(v);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.tune_rounded, size: 18, color: Colors.white70),
            const SizedBox(width: 6),
            Text('Intensity: ${(_value * 100).round()}%', style: TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
        Slider(
          value: _value,
          min: 0.0,
          max: 2.0,
          divisions: 40,
          onChanged: _onChanged,
        ),
      ],
    );
  }
}



/// Smoothing slider widget with real-time percentage label.
class _VizSmoothingSlider extends StatefulWidget {
  final double initialValue;
  final ValueChanged<double> onSaved;

  const _VizSmoothingSlider({required this.initialValue, required this.onSaved});

  @override
  State<_VizSmoothingSlider> createState() => _VizSmoothingSliderState();
}

class _VizSmoothingSliderState extends State<_VizSmoothingSlider> {
  double _value = 0.5;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  void _onChanged(double v) {
    setState(() => _value = v);
    AppSettings.saveVizSmoothing(v).then((_) {
      AudioPlayerService.smoothingFactor = v;
      // Push smoothing to isolate in real time
      AudioPlayerService.setVizSmoothing(v);
    });
    widget.onSaved(v);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.blur_on_rounded, size: 18, color: Colors.white70),
            const SizedBox(width: 6),
            Text("Smoothing: ${(_value * 100).round()}%", style: TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
        Slider(
          value: _value,
          min: 0.0,
          max: 1.0,
          divisions: 20,
          onChanged: _onChanged,
        ),
      ],
    );
  }
}

/// Main app shell with top nav bar and bottom player.
/// Custom intents for desktop keyboard shortcuts.
/// These are used with Shortcuts + Actions to intercept keys at the action layer,
/// preventing Space/Enter from activating focused buttons and menus.

class _TogglePlayPauseIntent extends Intent {
  const _TogglePlayPauseIntent();
}

class _PreviousSongIntent extends Intent {
  const _PreviousSongIntent();
}

class _NextSongIntent extends Intent {
  const _NextSongIntent();
}

class _ShuffleGridIntent extends Intent {
  const _ShuffleGridIntent();
}

class _PlayTileIntent extends Intent {
  final int index;
  const _PlayTileIntent(this.index);
}


class DuskTuneShell extends StatefulWidget {
  final List<Song> allSongs;
  final int tabIndex;
  final ValueChanged<int> onTabChanged;
  final bool isDesktop;
  /// Callback to refresh the app theme (e.g. after renaming app title).
  final VoidCallback onThemeRefresh;
  /// Callbacks for settings panel actions.
  final Future<int> Function()? onRescanLibrary;
  final Future<void> Function(bool)? onToggleAlbumArt;

  const DuskTuneShell({
    super.key,
    required this.allSongs,
    required this.tabIndex,
    required this.onTabChanged,
    this.isDesktop = false,
    required this.onThemeRefresh,
    this.onRescanLibrary,
    this.onToggleAlbumArt,
  });

  @override
  State<DuskTuneShell> createState() => _DuskTuneShellState();
}

class _DuskTuneShellState extends State<DuskTuneShell> {

  bool _listCollapsed = false; // Toggled by arrow button — collapses current section's list (all sections)
  // Active section on home page: null = recent, 'library'/'mixes'/'favorites'
  String? _activeHomeSection;
  bool _showHomeSearch = false;
  String? _searchQuery;
  final TextEditingController _homeSearchController = TextEditingController();
  final FocusNode _homeSearchFocusNode = FocusNode();
  String _appName = 'dusktune';
  Song? _currentSong;
  bool _isPlaying = false;
    Duration _position = Duration.zero;
    Duration _duration = Duration.zero;
    double _volume = 1.0;
  // Play count tracking for "Top 9"
  final Map<int, int> _playCounts = {};
  // Last-played order tracking (most recent first)
  final List<Song> _recentlyPlayed = [];
  // Shuffle All mode — when enabled, next/prev picks random songs
  bool _shuffleAll = false;
  // Play queue: the ordered list of songs for current playback session.
  // Set whenever a song is tapped — grid order, alphabetical, or search results.
  List<Song> _playQueue = [];
  int _playQueueIndex = -1;
  // Last-tapped tile in the top-9 grid (by index into topSongs).
  int? _selectedGridTile;
  // Keyboard focus node for desktop shortcuts (always focused, never visible)
  final FocusNode _keyboardFocusNode = FocusNode(skipTraversal: true);
  // Debounce: prevent re-entry while playSong is in flight
  bool _isTransitioning = false;

// Pinned grid: tile index (0-8) → Song, persisted across sessions.
  final Map<int, Song> _pinnedGrid = {};

  // Album art display toggle
  bool _showAlbumArt = false;
  /// Visualizer toggle — when true, the selected grid tile shows a spectrum analyzer
  bool _vizEnabled = false;
  /// FFT processing is now handled by the background isolate in AudioPlayerService.
  /// The shell no longer holds _fftSub or _latestFftFrame — _VizTile subscribes
  /// to AudioPlayerService.processedVizStream independently.
  /// Visualizer style: "bars", "wave", or "dots"
  String _vizStyle = 'bars';
  /// Visualizer intensity: 0.0 to 2.0, default 1.0
  double _vizIntensity = 1.0;
  /// Visualizer smoothing factor: 0.0 (raw) to 1.0 (heavy), default 0.5.
  double _vizSmoothing = 0.5;


  // Bright album art toggle — makes default tile backgrounds brighter for light environments
  bool _brightAlbumArt = false;

  /// Filter control state in range [-1, +1]: negative = LPF, positive = HPF, ~0 = none.
  double _filterControl = 0.0;

  // Pin mode: overlay for assigning current song to a tile.
  bool _pinMode = false;
    int? _pinSwapSourceIndex; // source tile for swap in pin mode overlay
  Song?
  _pinSourceSong; // Song to pin when entering pin mode (from tile long-press or grid button)

  // Mixes: list of saved mixes, each with id, name, and songIds.
  final List<Map<String, dynamic>> _mixes = [];
  final List<Song> _favorites = [];

  // Peek mode: double-tap on a grid tile opens an expanded preview dialog
  Song? _peekSong; // Track which song is being peeked (for external dismiss)
  int? _peekGridIndex;

  // Mix grid: temporary storage for a mix being displayed.
    List<Song>? _mixGridSongs;
    bool _showingMix = false;

      // Mix edit: reuses _pinMode with a working copy of songs and swap source tracking.
    Map<String, dynamic>? _editingMix; // the mix being edited via pin mode overlay
    List<Song>? _editMixSongs;         // working copy of songs for the mix being edited

      // Search state for library/favorites/mixes tabs
   final TextEditingController _searchController = TextEditingController();
   final FocusNode _librarySearchFocusNode = FocusNode();
   final FocusNode _mixesSearchFocusNode = FocusNode();
   final FocusNode _favoritesSearchFocusNode = FocusNode();
  List<Song> _searchResults = [];
  bool _isSearching = false;
  Timer? _searchDebounce;

  // Favorites search state
  List<Song> _favSearchResults = [];
  bool _favIsSearching = false;
  Timer? _favSearchDebounce;

  // Grid/home search state — works across all source modes (local)
  String? _gridSearchQuery;
  final TextEditingController _gridSearchController = TextEditingController();
  final FocusNode _gridSearchFocusNode = FocusNode();
  List<Song>? _homeGridSearchResults;
  int _searchPage = 0;

  // Scroll controller for home tab — used by title button to snap to top
  final ScrollController _homeScrollController = ScrollController();
  OverlayEntry? _gridSearchOverlayEntry;

  @override
  void initState() {
    super.initState();
    // Ensure keyboard listener always has focus on desktop
    if (_isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _keyboardFocusNode.requestFocus();
      });
    }
    _listenToPlayback();
    // FFT processing is now handled by the background isolate.
    // _VizTile subscribes to AudioPlayerService.processedVizStream independently.

    // Wire up auto-advance when a track finishes
    AudioPlayerService.setOnTrackComplete(_skipToNext);
    // Wire up notification panel next/previous controls
    AudioPlayerService.setNotificationCallbacks(
      onNext: _skipToNext,
      onPrevious: _skipToPrevious,
    );
    // Load persisted settings and favorites
    _loadSettings();
    _loadFavoritesAsync();

    // Load bright album art preference (Android only)
    if (!_isDesktop) {
      AppSettings.loadBrightAlbumArt().then((enabled) {
        if (!mounted) return;
        setState(() => _brightAlbumArt = enabled);
      });
    }
  }

  /// Toggle bright album art on/off. Sets sunlight factor to 1.0 when on, 0.0 when off.
  Future<void> toggleBrightAlbumArt(bool enabled) async {
    await AppSettings.saveBrightAlbumArt(enabled);
    if (mounted) {
      setState(() => _brightAlbumArt = enabled);
    }
  }


  /// Load favorites from persistent storage (async, non-blocking).
  Future<void> _loadFavoritesAsync() async {
    final favDataList = await AppSettings.loadFavorites();
    if (!mounted) return;
    setState(() {
      _favorites.clear();
      for (final data in favDataList) {
        // Support both old format (String ID) and new format (Map with full song data)
        final id;
        if (data is String) {
          id = int.tryParse(data);
        } else if (data is Map<String, dynamic>) {
          id = data['id'] as int? ?? 0;
        } else {
          continue;
        }

        // Try to find in local library first (gets updated metadata/artwork)
        final match = widget.allSongs.firstWhere(
          (s) => s.id == id,
          orElse: () {
            // Song not in local library — reconstruct from stored data
            if (data is Map<String, dynamic>) {
              return Song(
                id: id,
                title: data['title'] as String? ?? 'Unknown',
                uri: data['uri'] as String? ?? '',
                duration: data['duration'] as int? ?? 0,
                artist: data['artist'] as String?,
              );
            }
            return Song(id: -1, title: '', uri: '', duration: 0);
          },
        );
        if (match.uri.isNotEmpty) _favorites.add(match);
      }
    });
  }

  // ─── Filter Control — continuous slider [-1, +1] ──

  /// Apply filter control change from the UI slider — fire-and-forget for lowest latency.
  void _onFilterChanged(double value) {
    _filterControl = value;
    // Don't await — let each tick run concurrently so drag feels immediate.
    AudioPlayerService.setFilterControl(value);
  }

  /// Reset filter to neutral when the 'Filter' label is tapped.
  Future<void> _resetFilter() async {
    await AudioPlayerService.clearFilters();
    setState(() => _filterControl = 0.0);
  }

  /// Reset filter state when a new track starts (clear filters).
  /// No-op now — user manages filter via slider. Kept for potential future use.
  void _resetFadeState() {
    // Intentionally no-op: filter persists across tracks.
  }

  Future<void> _loadSettings() async {
     final appName = await AppSettings.loadAppName();
     final playCounts = await AppSettings.loadPlayCounts();
     final showAlbumArt = await AppSettings.loadShowAlbumArt();
     final vizEnabled = await AppSettings.loadVizEnabled();
     final vizStyle = await AppSettings.loadVizStyle();
     final vizIntensity = await AppSettings.loadVizIntensity();
     final vizSmoothing = await AppSettings.loadVizSmoothing();
     if (mounted) {
       setState(() {
         _appName = appName;
         _playCounts.clear();
         _playCounts.addAll(playCounts);
         _showAlbumArt = showAlbumArt;
        _vizEnabled = vizEnabled;
        _vizStyle = vizStyle;
        _vizIntensity = vizIntensity;
        _vizSmoothing = vizSmoothing;
       });
     }

     // Sync persisted viz settings to AudioPlayerService so painters pick them up immediately
     AudioPlayerService.vizStyle = _vizStyle;
     AudioPlayerService.vizIntensity = _vizIntensity;
     AudioPlayerService.smoothingFactor = _vizSmoothing;
    // Load pinned grid after settings are loaded
    await _loadPinnedGrid(widget.allSongs);
    // Load mixes
    final List<Map<String, dynamic>> loadedMixes =
        await AppSettings.loadMixes();
    if (mounted) {
      setState(() {
        _mixes.clear();
        _mixes.addAll(loadedMixes);
      });
    }
  }

  Future<void> _savePlayCounts() async {
    await AppSettings.savePlayCounts(_playCounts);
  }

  Future<void> _saveAppName(String name) async {
    // Easter egg: append ":>" to "dawntune"
    if (name.toLowerCase() == 'dawntune') name = 'dawntune :>';
    await AppSettings.saveAppName(name);
    widget.onThemeRefresh();
  }

  @override
  void dispose() {
    // Clear callbacks on dispose to avoid stale references
    AudioPlayerService.setOnTrackComplete(null);
    AudioPlayerService.setNotificationCallbacks(onNext: null, onPrevious: null);
    _searchDebounce?.cancel();
     _searchController.dispose();
     _librarySearchFocusNode.dispose();
     _mixesSearchFocusNode.dispose();
     _favoritesSearchFocusNode.dispose();
    // Remove search overlay if visible
    _hideGridSearchOverlay();
    _homeScrollController.dispose();
    _gridSearchController.dispose();
    _gridSearchFocusNode.dispose();
    _homeSearchController.dispose();
    _homeSearchFocusNode.dispose();
    super.dispose();
  }


  /// Show viz style options menu (called from long-press/right-click on viz button).
  void _showVizOptions() {
    // Ensure viz is enabled when showing options — user clearly wants to use it.
    if (!_vizEnabled) {
      setState(() => _vizEnabled = true);
      // FFT isolate is always running — no subscription needed here.
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('visualizer', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _vizStyleOption('bars', Icons.bar_chart_rounded, 'Bars'),
            _vizStyleOption('wave', Icons.show_chart_rounded, 'Wave'),
            _vizStyleOption('dots', Icons.grid_view_rounded, 'Dots'),
            _vizStyleOption('circles', Icons.circle_rounded, 'Circles'),
            _vizStyleOption('peakhold', Icons.equalizer_rounded, 'Peak Hold'),
            const SizedBox(height: 12),
            _VizIntensitySlider(initialValue: _vizIntensity, onSaved: (v) {
              setState(() => _vizIntensity = v);
            }),
            const SizedBox(height: 4),
            _VizSmoothingSlider(initialValue: _vizSmoothing, onSaved: (v) {
              setState(() => _vizSmoothing = v);
            }),
          ],
        ),
      ),
    );
  }

  Widget _vizStyleOption(String style, IconData icon, String label) {
    final isSelected = _vizStyle == style;
    return ListTile(
      leading: Icon(icon, color: isSelected ? Colors.white : Colors.white54, size: 20),
      title: Text(label.toUpperCase(), style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontWeight: isSelected ? FontWeight.bold : null)),
      trailing: isSelected ? const Icon(Icons.check_rounded, color: Colors.white) : null,
      onTap: () {
        setState(() => _vizStyle = style);
        AppSettings.saveVizStyle(style).then((_) {
          AudioPlayerService.vizStyle = style;
        });
        Navigator.of(context).pop();
      },
    );
  }


  void _listenToPlayback() {
    // Use playingStateStream which works on ALL platforms (Android + desktop)
    AudioPlayerService.playingStateStream.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });
    AudioPlayerService.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    AudioPlayerService.durationStream.listen((dur) {
      if (mounted) setState(() => _duration = dur ?? Duration.zero);
    });
  }

  /// Play a song, optionally within a specific play queue.
  /// If [queue] is provided, use it for next/previous navigation.
  /// If omitted, default to alphabetical (allSongs).
  void playSong(Song song, {List<Song>? queue}) async {
     _isTransitioning = true;
     // Reset fade state so new track starts at full volume
     if (!_isDesktop) {
       _resetFadeState();
     }
     // Track play count and recent order
     setState(() {
       _playCounts[song.id] = (_playCounts[song.id] ?? 0) + 1;
       // Move to front of recently played (remove if already there first)
       _recentlyPlayed.removeWhere((s) => s.id == song.id);
       _recentlyPlayed.insert(0, song);
       _currentSong = song;

       // Set up the play queue for continuous playback
       final effectiveQueue = queue ?? widget.allSongs;
       _playQueue = effectiveQueue;
       _playQueueIndex = _playQueue.indexWhere((s) => s.id == song.id);
     });
     // Persist play counts to disk
     _savePlayCounts();
     await AudioPlayerService.playSong(song);
     // Force UI sync — stream may not have emitted yet on desktop release builds
     if (mounted) {
       setState(() {
         _isPlaying = AudioPlayerService.isPlaying;
         _isTransitioning =
             false; // Clear transition flag so next auto-advance can fire
       });
     }
   }

  /// Get top N songs by play count, sorted descending.
  List<Song> getTopSongs(int n) {
    // If we have a shuffled set, use it instead of ranked list
    if (_shuffledTopNine != null) return _shuffledTopNine!.take(n).toList();

    if (_playCounts.isEmpty) return widget.allSongs.take(n).toList();
    final sorted =
        widget.allSongs.where((s) => _playCounts.containsKey(s.id)).toList()
          ..sort(
            (a, b) =>
                (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0),
          );
    // Fill remaining slots with deterministic songs from the library (not random)
    final rng = math.Random(42);
    final usedIds = sorted.toSet();
    for (int i = 0; i < widget.allSongs.length && sorted.length < n; i++) {
      final idx = rng.nextInt(widget.allSongs.length);
      if (!usedIds.contains(widget.allSongs[idx])) {
        sorted.add(widget.allSongs[idx]);
        usedIds.add(widget.allSongs[idx]);
      }
    }
    return sorted.take(n).toList();
  }

  /// Top 9 grid — temporarily holds shuffled random set.
    List<Song>? _shuffledTopNine;

    /// Temporarily holds a batch of most-played songs for the "tops" button.
    /// When set, getGridSongs ignores pinned tiles and shows these songs.
    List<Song>? _toppedNine;

    /// Current page index for cycling through most-played batches of 9.
    int _topsPage = 0;

    /// Whether the Tops button has been tapped at least once since launch.
    bool _topsFirstUse = true;

    /// Shuffle the top 9 to random songs — does NOT start playback.
     /// When in streaming mode, fetches random tracks from the active source instead.
     Future<void> shuffleTopNine(BuildContext context) async {
      final rng = math.Random();

      // If search is active, advance to next page of results instead of shuffling
      if (_homeGridSearchResults != null && _homeGridSearchResults!.isNotEmpty) {
        _advanceSearchPage();
        return;
      }

      // Local mode: shuffle from local library — tracks appear immediately, artwork loads async
      final shuffled = List<Song>.from(widget.allSongs)..shuffle(rng);
      
      debugPrint('shuffleTopNine: ${shuffled.length} songs before clearing artwork');
      final withArtBefore = shuffled.where((s) => s.artworkBytes != null).length;
      debugPrint('shuffleTopNine: $withArtBefore/${shuffled.length} songs have artwork from library cache');
      
      // Log first song's artwork size if it exists
      if (shuffled.isNotEmpty && shuffled[0].artworkBytes != null) {
        debugPrint('shuffleTopNine: first song artwork size=${shuffled[0].artworkBytes!.length} bytes, id=${shuffled[0].id}');
      }
      
      // Clear artwork from all songs BEFORE showing them to ensure fresh extraction
      final clearedShuffled = shuffled.take(9).map((s) => s.copyWith(clearArtwork: true)).toList();
      
      final clearedWithArt = clearedShuffled.where((s) => s.artworkBytes != null).length;
      debugPrint('shuffleTopNine: cleared artwork, now $clearedWithArt/${clearedShuffled.length} have artwork (should be 0)');
      
      // Verify clearing worked by checking first song
      if (clearedShuffled.isNotEmpty && clearedShuffled[0].artworkBytes != null) {
        debugPrint('shuffleTopNine: ERROR - first song still has artwork after clearing! size=${clearedShuffled[0].artworkBytes!.length}');
      } else if (clearedShuffled.isNotEmpty) {
        debugPrint('shuffleTopNine: OK - first song artwork cleared successfully');
      }
      
      setState(() {
        _shuffledTopNine = clearedShuffled;
        _showingMix = false;
        _mixGridSongs = null;
      });
      // Extract artwork in background — doesn't block UI
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          final extractedSongs = await ArtworkExtractor.extractForSongsInMemory(_shuffledTopNine!);
          
          if (mounted && extractedSongs != null) {
            final withArtAfter = extractedSongs.where((s) => s.artworkBytes != null).length;
            debugPrint('shuffleTopNine: extraction complete, $withArtAfter/${extractedSongs.length} songs have artwork');
            
            // Log first song's artwork size after extraction
            if (extractedSongs.isNotEmpty && extractedSongs[0].artworkBytes != null) {
              debugPrint('shuffleTopNine: first song artwork size=${extractedSongs[0].artworkBytes!.length} bytes, id=${extractedSongs[0].id}');
              
              // Compare with original to see if it's fresh extraction
              final originalSong = shuffled.first;
              if (originalSong.artworkBytes != null && extractedSongs[0].artworkBytes != null) {
                final sameSize = originalSong.artworkBytes!.length == extractedSongs[0].artworkBytes!.length;
                debugPrint('shuffleTopNine: artwork size matches original? $sameSize (${originalSong.artworkBytes!.length} vs ${extractedSongs[0].artworkBytes!.length})');
              }
            }
            
            setState(() {
              _shuffledTopNine = extractedSongs; // New list reference forces rebuild
            });
          }
        } catch (e) {
          debugPrint('shuffleTopNine artwork extraction failed: $e');
        }
      });
    }

  /// Advance to next page of search results on swipe/shuffle.
    void _advanceSearchPage() {
      if (_homeGridSearchResults == null || _homeGridSearchResults!.isEmpty) return;

      final totalPages = (_homeGridSearchResults!.length + 8) ~/ 9;
      final nextPage = (_searchPage + 1) % totalPages;
      final nextStart = nextPage * 9;

      // If approaching end of results, fetch more in background (infinite scroll)
      if (nextPage >= totalPages - 2 || _homeGridSearchResults!.length <= 18) {
        _fetchMoreSearchResults();
      }

      setState(() {
        _searchPage = nextPage;
        final end = math.min(nextStart + 9, _homeGridSearchResults!.length);
        if (nextStart < _homeGridSearchResults!.length) {
          _shuffledTopNine = _homeGridSearchResults!.sublist(nextStart, end);
        } else {
          // Wrap around to start while more results load
          _searchPage = 0;
          _shuffledTopNine = _homeGridSearchResults!.take(9).toList();
        }
      });

      // Extract artwork for local songs in background
      if (_shuffledTopNine != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          try {
            final extractedSongs = await ArtworkExtractor.extractForSongsInMemory(_shuffledTopNine!);
            if (mounted && extractedSongs != null) {
              setState(() => _shuffledTopNine = extractedSongs);
            }
          } catch (_) {}
        });
      }
    }

    /// Fetch more search results and append to existing list.
    Future<void> _fetchMoreSearchResults() async {
      if (_gridSearchQuery == null || _gridSearchQuery!.isEmpty) return;
      // Local-only: no streaming search support
    }

  /// Reset top picks back to most-played ranking.
    /// Restore pinned grid by clearing shuffle, tops, and mix state.
    void resetTopPicks() {
      setState(() {
        _shuffledTopNine = null;
        _toppedNine = null;
        _showingMix = false;
        _mixGridSongs = null;
        _topsPage = 0;
      });
    }

    /// Get a batch of N most-played songs, starting at offset = _topsPage * n.
    List<Song> _getTopsBatch(int n) {
      final sorted = <Song>[];
      if (_playCounts.isEmpty) {
        sorted.addAll(widget.allSongs);
      } else {
        sorted.addAll(
          widget.allSongs.where((s) => _playCounts.containsKey(s.id)).toList()
            ..sort(
              (a, b) =>
                  (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0),
            ),
        );
      }

      // Apply page offset: skip _topsPage * n songs, then take next n.
      final offset = (_topsPage * n) % sorted.length;
      final result = <Song>[];
      for (int i = 0; i < n && result.length < n; i++) {
        final idx = (offset + i) % sorted.length;
        result.add(sorted[idx]);
      }
      return result.take(n).toList();
    }

    /// Cycle to the next page of most-played songs (batch of 9) with album art extraction.
        void showTops() async {
      // Get the batch first, then extract artwork before showing it
      final batchSongs = _getTopsBatch(9);
      if (batchSongs.isEmpty) return;

      try {
        final clearedSongs = batchSongs.map((s) => s.copyWith(clearArtwork: true)).toList();
        final extractedSongs = await ArtworkExtractor.extractForSongsInMemory(clearedSongs);

        if (mounted && extractedSongs != null) {
          setState(() {
            // First tap after launch: show page 0 (most played) without incrementing.
            if (_topsFirstUse) {
              _topsFirstUse = false;
              _topsPage = 0;
            } else {
              _topsPage = (_topsPage + 1) % ((widget.allSongs.length + 8) ~/ 9);
            }
            // Store the topped batch with artwork — overrides pins, just like shuffle does.
            _toppedNine = extractedSongs;
            // Clear shuffle/mix so we go back to ranked tops display
            _shuffledTopNine = null;
            _showingMix = false;
            _mixGridSongs = null;
          });
        } else {
          // Fallback if extraction fails - still show the songs without art
          setState(() {
            if (_topsFirstUse) {
              _topsFirstUse = false;
              _topsPage = 0;
            } else {
              _topsPage = (_topsPage + 1) % ((widget.allSongs.length + 8) ~/ 9);
            }
            _toppedNine = clearedSongs;
            _shuffledTopNine = null;
            _showingMix = false;
            _mixGridSongs = null;
          });
        }
      } catch (_) {
        // Fallback on error - just show the songs normally
        setState(() {
          if (_topsFirstUse) {
            _topsFirstUse = false;
            _topsPage = 0;
          } else {
            _topsPage = (_topsPage + 1) % ((widget.allSongs.length + 8) ~/ 9);
          }
          _toppedNine = batchSongs;
          _shuffledTopNine = null;
          _showingMix = false;
          _mixGridSongs = null;
        });
      }
    }

      /// Reset tops back to the beginning (page 0) and show that batch with album art.
      void resetTops() async {
      final batchSongs = _getTopsBatch(9);
      if (batchSongs.isEmpty) return;

      try {
        final clearedSongs = batchSongs.map((s) => s.copyWith(clearArtwork: true)).toList();
        final extractedSongs = await ArtworkExtractor.extractForSongsInMemory(clearedSongs);

        if (mounted && extractedSongs != null) {
          setState(() {
            _topsPage = 0;
            _topsFirstUse = true; // allow first-tap behavior again after reset
            _toppedNine = extractedSongs;
            _shuffledTopNine = null;
            _showingMix = false;
            _mixGridSongs = null;
          });
        } else {
          setState(() {
            _topsPage = 0;
            _topsFirstUse = true;
            _toppedNine = clearedSongs;
            _shuffledTopNine = null;
            _showingMix = false;
            _mixGridSongs = null;
          });
        }
      } catch (_) {
        setState(() {
          _topsPage = 0;
          _topsFirstUse = true;
          _toppedNine = batchSongs;
          _shuffledTopNine = null;
          _showingMix = false;
          _mixGridSongs = null;
        });
      }
    }

    // -- Pinned grid helpers --

  /// Load pinned grid from persistent storage.
  Future<void> _loadPinnedGrid(List<Song> allSongs) async {
    final raw = await AppSettings.loadPinnedGrid();
    
    // Show placeholders immediately (no artwork yet)
    if (mounted) {
      setState(() {
        for (final entry in raw.entries) {
          final songData = entry.value;
          final song = allSongs.firstWhere(
            (s) => s.id == songData['id'],
            orElse: () {
              // Song not in local library — reconstruct from stored data
              return Song(
                id: songData['id'] as int,
                title: songData['title'] as String? ?? 'Unknown',
                uri: songData['uri'] as String? ?? '',
                duration: songData['duration'] as int? ?? 0,
                artist: songData['artist'] as String?,
              );
            },
          );
          _pinnedGrid[entry.key] = song;
        }
      });
    }
    
    // Extract artwork AFTER frame renders (like shuffle does)
    if (_showAlbumArt && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        
        final pinnedSongs = List<Song>.from(_pinnedGrid.values);
        debugPrint('Pinned grid: extracting artwork for ${pinnedSongs.length} songs');
        
        final extractedSongs = await ArtworkExtractor.extractForSongsInMemory(pinnedSongs);
        
        // Debug logging
        final withArtAfter = extractedSongs.where((s) => s.artworkBytes != null).length;
        debugPrint('Pinned grid extraction: $withArtAfter/${extractedSongs.length} songs have artwork');
        
        if (mounted && extractedSongs.isNotEmpty) {
          setState(() {
            // Build map of extracted songs by ID for matching
            final extractedById = <int, Song>{};
            for (final song in extractedSongs) {
              extractedById[song.id] = song;
            }
            
            // Create NEW map reference to force rebuild
            final newGrid = Map<int, Song>.from(_pinnedGrid);
            int updatedCount = 0;
            
            for (final key in _pinnedGrid.keys.toList()) {
              final currentSong = _pinnedGrid[key];
              if (currentSong != null && extractedById.containsKey(currentSong.id)) {
                final extracted = extractedById[currentSong.id]!;
                if (extracted.artworkBytes != null) {
                  newGrid[key] = extracted;
                  updatedCount++;
                }
              }
            }
            
            // Replace contents to trigger rebuild
            _pinnedGrid.clear();
            _pinnedGrid.addAll(newGrid);
            
            debugPrint('Pinned grid: updated $updatedCount entries with artwork');
          });
        }
      });
    }
  }

  /// Save pinned grid to persistent storage.
  Future<void> _savePinnedGrid() async {
    final raw = _pinnedGrid.map((k, v) => MapEntry(k, v.toJson()));
    await AppSettings.savePinnedGrid(raw);
  }

  /// Pin the currently playing song to a specific tile (0-8).
  Future<void> pinCurrentSongToTile(int tileIndex) async {
    if (_currentSong == null) return;
    setState(() {
      _pinnedGrid[tileIndex] = _currentSong!;
    });
    await _savePinnedGrid();
  }

  /// Pin a given song to a specific tile (0-8).
  Future<void> pinSongToTile(Song song, int tileIndex) async {
    setState(() {
      _pinnedGrid[tileIndex] = song;
    });
    await _savePinnedGrid();
  }

  /// Unpin a tile (remove pinned song).
  Future<void> unpinTile(int tileIndex) async {
    setState(() {
      _pinnedGrid.remove(tileIndex);
    });
    await _savePinnedGrid();
  }

  // -- Mix helpers --

  /// Save the current grid songs as a named mix.
  Future<void> saveCurrentGridAsMix(String name) async {
    final gridSongs = getGridSongs();
    if (gridSongs.length < 9) return;

    final mixData = {
      'id': DateTime.now().millisecondsSinceEpoch,
      'name': name.trim(),
      'songIds': List<int>.from(gridSongs.map((s) => s.id)),
      'songData': gridSongs.map((s) => s.toJson()).toList(),
    };

    setState(() {
      _mixes.add(mixData);
    });
    await AppSettings.saveMixes(_mixes);
  }

  /// Load a mix into the grid display — extracts album art for tiles.
  Future<void> loadMixIntoGrid(Map<String, dynamic> mix) async {
    final songIds = List<int>.from(mix['songIds'] as List);
    final resolvedSongs = <Song>[];
    for (final id in songIds) {
      final found = widget.allSongs.where((s) => s.id == id).toList();
      if (found.isNotEmpty) {
        resolvedSongs.add(found.first);
      } else {
        final songDataList = mix['songData'] as List? ?? [];
        for (final data in songDataList) {
          if ((data['id'] as int?) == id) {
            resolvedSongs.add(Song(
              id: id,
              title: data['title'] as String? ?? 'Unknown',
              uri: data['uri'] as String? ?? '',
              duration: data['duration'] as int? ?? 0,
              artist: data['artist'] as String?,
            ));
            break;
          }
        }
      }
    }

    try {
      final cleared = resolvedSongs.map((s) => s.copyWith(clearArtwork: true)).toList();
      final extracted = await ArtworkExtractor.extractForSongsInMemory(cleared);
      if (mounted) {
        setState(() {
          _mixGridSongs = extracted ?? cleared;
          _showingMix = true;
          _shuffledTopNine = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _mixGridSongs = resolvedSongs;
          _showingMix = true;
          _shuffledTopNine = null;
        });
      }
    }
  }

      /// Delete a mix by ID.
        Future<void> deleteMix(int id) async {
          setState(() {
            _mixes.removeWhere((m) => (m['id'] as int) == id);
          });
          await AppSettings.saveMixes(_mixes);
        }

        /// Open the mix edit overlay for a given mix.
        void openMixEdit(Map<String, dynamic> mix) {
          final songIds = List<int>.from(mix['songIds'] as List);
          final songData = (mix['songData'] as List?) ?? [];
          final songs = <Song>[];
          for (final id in songIds) {
            final found = widget.allSongs.where((s) => s.id == id).toList();
            if (found.isNotEmpty) {
              songs.add(found.first);
            } else {
              // Fallback: reconstruct from saved songData.
              for (final data in songData) {
                if ((data['id'] as int?) == id) {
                  songs.add(Song(
                    id: id,
                    title: data['title'] as String? ?? 'Unknown',
                    uri: data['uri'] as String? ?? '',
                    duration: data['duration'] as int? ?? 0,
                    artist: data['artist'] as String?,
                  ));
                  break;
                }
              }
            }
          }
          setState(() {
            _editingMix = mix;
            _editMixSongs = List.from(songs);
            // Enter pin mode to reuse the existing grid overlay UI.
            _pinMode = true;
            _pinSourceSong = null;
          });
        }

        /// Save the edited song order back to the mix (called when exiting pin mode).
        Future<void> saveEditMix() async {
          if (_editingMix == null || _editMixSongs == null) return;
          final id = _editingMix!['id'] as int;
          setState(() {
            for (int i = 0; i < _mixes.length; i++) {
              if ((_mixes[i]['id'] as int) == id) {
                _mixes[i]['songIds'] = List<int>.from(
                  _editMixSongs!.map((s) => s.id),
                );
                break;
              }
            }
          });
          await AppSettings.saveMixes(_mixes);
          setState(() {
            _editingMix = null;
            _editMixSongs = null;
          });
        }

          /// Prompt user to name and save current grid as a mix.
  Future<void> promptSaveMix(BuildContext context) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('name your mix'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'mix name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) Navigator.pop(ctx, value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (ctrl.text.trim().isNotEmpty)
                  Navigator.pop(ctx, ctrl.text.trim());
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result != null && result.isNotEmpty) {
      await saveCurrentGridAsMix(result);
    }
  }

  /// Build the list of 9 songs for the grid display.
    /// When shuffled (_shuffledTopNine is set), shows pure shuffle — no pins.
    /// When topped (_toppedNine is set), shows a batch of most-played — no pins.
    /// Otherwise, pinned tiles show their song; unpinned slots use getTopSongs fallback.
    List<Song> getGridSongs() {
      // If showing a mix, return that mix's songs.
      if (_showingMix && _mixGridSongs != null) {
        return _mixGridSongs!.take(9).toList();
      }
      // If in shuffle mode, show pure shuffle (pins hidden)
      if (_shuffledTopNine != null) return _shuffledTopNine!.take(9).toList();
      // If topped, show the most-played batch (pins hidden)
      if (_toppedNine != null) return _toppedNine!.take(9).toList();

      final base = getTopSongs(9);
    final result = <Song>[];
    int baseIndex = 0;

    for (int i = 0; i < 9; i++) {
      if (_pinnedGrid.containsKey(i)) {
        result.add(_pinnedGrid[i]!);
      } else if (baseIndex < base.length) {
        result.add(base[baseIndex++]);
      } else {
        break;
      }
    }

    return result;
  }

  /// Get recently played songs in reverse chronological order.
  List<Song> getRecentSongs() {
    if (_recentlyPlayed.isEmpty) return widget.allSongs;
    return _recentlyPlayed.toList();
  }


  /// Toggle Shuffle All — plays a random song and enables shuffle mode.
  void toggleShuffleAll(BuildContext context) {
    setState(() {
      _shuffleAll = !_shuffleAll;
    });
    if (_shuffleAll) {
      // Play a random song immediately when enabling
      final rng = math.Random();
      final randomSong = widget.allSongs[rng.nextInt(widget.allSongs.length)];
      playSong(randomSong);
    }
  }

  /// Override skipToNext to pick random song when shuffle is on, or next in play queue.
  void _skipToNext() {
    // Debounce: prevent re-entry while a track transition is in flight
    if (_isTransitioning) return;
    if (_shuffleAll) {
      final rng = math.Random();
      final randomSong = widget.allSongs[rng.nextInt(widget.allSongs.length)];
      playSong(randomSong);
    } else if (_playQueue.isNotEmpty && _playQueueIndex >= 0) {
      final nextIdx = (_playQueueIndex + 1) % _playQueue.length;
      playSong(_playQueue[nextIdx]);
    } else if (_currentSong != null && widget.allSongs.isNotEmpty) {
      // Fallback: alphabetical from allSongs
      final idx = widget.allSongs.indexWhere((s) => s.id == _currentSong!.id);
      final nextIdx = (idx + 1) % widget.allSongs.length;
      playSong(widget.allSongs[nextIdx]);
    }
  }

  /// Override skipToPrevious to pick random song when shuffle is on, or previous in play queue.
  void _skipToPrevious() {
    // Debounce: prevent re-entry while a track transition is in flight
    if (_isTransitioning) return;
    if (_shuffleAll) {
      final rng = math.Random();
      final randomSong = widget.allSongs[rng.nextInt(widget.allSongs.length)];
      playSong(randomSong);
    } else if (_playQueue.isNotEmpty && _playQueueIndex >= 0) {
      final prevIdx =
          (_playQueueIndex - 1 + _playQueue.length) % _playQueue.length;
      playSong(_playQueue[prevIdx]);
    } else if (_currentSong != null && widget.allSongs.isNotEmpty) {
      // Fallback: alphabetical from allSongs
      final idx = widget.allSongs.indexWhere((s) => s.id == _currentSong!.id);
      final prevIdx =
          (idx - 1 + widget.allSongs.length) % widget.allSongs.length;
      playSong(widget.allSongs[prevIdx]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    // Build the scaffold content
    Widget content = Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top nav bar
            _buildTopNav(),

            // Content area with overlays on top of all tabs
            Expanded(
              child: Stack(
                children: [
                  IndexedStack(
                     index: widget.tabIndex,
                     children: [
                       _buildHomeTab(),
                       _SwipeableTab(
                         onLeft: () => widget.onTabChanged(0), // Library → Home
                         onRight: () => widget.onTabChanged(2), // Library → Mixes
                         child: _buildLibraryTab(),
                       ),
                       _SwipeableTab(
                         onLeft: () => widget.onTabChanged(0), // Mixes → Home
                         onRight: () => widget.onTabChanged(3), // Mixes → Favorites
                         child: _buildMixesTab(),
                       ),
                       _SwipeableTab(
                         onLeft: () => widget.onTabChanged(0), // Favorites → Home
                         child: _buildFavoritesTab(),
                       ),
                         SettingsContent(
                           onRescanLibrary: widget.onRescanLibrary,
                           onToggleAlbumArt: widget.onToggleAlbumArt,
                           onToggleBrightAlbumArt: toggleBrightAlbumArt,
                         ),
                       ],
                   ),

                  // Pin mode overlay — appears on all tabs when triggered
                   if (_pinMode) _buildPinModeOverlay(getGridSongs()),
                  ],
              ),
            ),

            // Bottom player (always visible when a song is playing)
            if (_currentSong != null) _buildBottomPlayer(),
          ],
        ),
      ),
    );

    // Wrap with Shortcuts + Actions for desktop keyboard shortcuts.
    // Shortcuts intercepts keys at the action layer — higher priority than focused widgets,
    // so Space/Enter never reach buttons and menus when a shortcut is registered.
    if (isDesktop) {
      content = Shortcuts(
        shortcuts: _buildShortcutMap(),
        child: Actions(
          actions: _buildActionMap(context),
          child: content,
        ),
      );
    }

    return content;
  }

  /// Check if any search field currently has focus.
  bool get _anySearchFieldFocused =>
      _librarySearchFocusNode.hasFocus ||
      _mixesSearchFocusNode.hasFocus ||
      _favoritesSearchFocusNode.hasFocus ||
      _gridSearchFocusNode.hasFocus ||
      _homeSearchFocusNode.hasFocus;

  /// Build the Shortcuts map for desktop keyboard shortcuts.
  Map<LogicalKeySet, Intent> _buildShortcutMap() {
    return <LogicalKeySet, Intent>{
      LogicalKeySet(LogicalKeyboardKey.space): const _TogglePlayPauseIntent(),
      LogicalKeySet(LogicalKeyboardKey.arrowLeft): const _PreviousSongIntent(),
      LogicalKeySet(LogicalKeyboardKey.arrowRight): const _NextSongIntent(),
      LogicalKeySet(LogicalKeyboardKey.backquote): const _ShuffleGridIntent(),
      // Numpad variants for arrows
      LogicalKeySet(LogicalKeyboardKey.numpad4): const _PreviousSongIntent(),
      LogicalKeySet(LogicalKeyboardKey.numpad6): const _NextSongIntent(),
      // 1-9 → play tile by position
      LogicalKeySet(LogicalKeyboardKey.digit1): const _PlayTileIntent(0),
      LogicalKeySet(LogicalKeyboardKey.digit2): const _PlayTileIntent(1),
      LogicalKeySet(LogicalKeyboardKey.digit3): const _PlayTileIntent(2),
      LogicalKeySet(LogicalKeyboardKey.digit4): const _PlayTileIntent(3),
      LogicalKeySet(LogicalKeyboardKey.digit5): const _PlayTileIntent(4),
      LogicalKeySet(LogicalKeyboardKey.digit6): const _PlayTileIntent(5),
      LogicalKeySet(LogicalKeyboardKey.digit7): const _PlayTileIntent(6),
      LogicalKeySet(LogicalKeyboardKey.digit8): const _PlayTileIntent(7),
      LogicalKeySet(LogicalKeyboardKey.digit9): const _PlayTileIntent(8),
      LogicalKeySet(LogicalKeyboardKey.numpad1): const _PlayTileIntent(0),
      LogicalKeySet(LogicalKeyboardKey.numpad2): const _PlayTileIntent(1),
      LogicalKeySet(LogicalKeyboardKey.numpad3): const _PlayTileIntent(2),
      LogicalKeySet(LogicalKeyboardKey.numpad4): const _PlayTileIntent(3),
      LogicalKeySet(LogicalKeyboardKey.numpad5): const _PlayTileIntent(4),
      LogicalKeySet(LogicalKeyboardKey.numpad6): const _PlayTileIntent(5),
      LogicalKeySet(LogicalKeyboardKey.numpad7): const _PlayTileIntent(6),
      LogicalKeySet(LogicalKeyboardKey.numpad8): const _PlayTileIntent(7),
      LogicalKeySet(LogicalKeyboardKey.numpad9): const _PlayTileIntent(8),
    };
  }

  /// Build the Actions map for desktop keyboard shortcuts.
  Map<Type, Action<Intent>> _buildActionMap(BuildContext context) {
    return <Type, Action<Intent>>{
      _TogglePlayPauseIntent: CallbackAction<_TogglePlayPauseIntent>(
        onInvoke: (_) {
          if (_anySearchFieldFocused) return null;
          AudioPlayerService.togglePlayPause();
          setState(() => _isPlaying = !_isPlaying);
          return null;
        },
      ),
      _PreviousSongIntent: CallbackAction<_PreviousSongIntent>(
        onInvoke: (_) {
          if (_anySearchFieldFocused) return null;
          _skipToPrevious();
          return null;
        },
      ),
      _NextSongIntent: CallbackAction<_NextSongIntent>(
        onInvoke: (_) {
          if (_anySearchFieldFocused) return null;
          _skipToNext();
          return null;
        },
      ),
      _ShuffleGridIntent: CallbackAction<_ShuffleGridIntent>(
        onInvoke: (_) {
          if (_anySearchFieldFocused) return null;
          shuffleTopNine(context);
          return null;
        },
      ),
      _PlayTileIntent: CallbackAction<_PlayTileIntent>(
        onInvoke: (intent) {
          if (_anySearchFieldFocused) return null;
          final gridSongs = getGridSongs();
          if (intent.index < gridSongs.length) {
            setState(() => _selectedGridTile = intent.index);
            playSong(gridSongs[intent.index], queue: gridSongs);
          }
          return null;
        },
      ),
    };
  }

  /// Show the rename dialog for editing the app title.
  void _showRenameDialog() {
    showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: _appName);
        return AlertDialog(
          title: const Text('Rename'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'App name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isNotEmpty) {
                  final saved = name.toLowerCase() == 'dawntune' ? 'dawntune :>' : name;
                  setState(() => _appName = saved);
                  _saveAppName(saved);
                }
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  /// Top navigation bar with editable app name + tab buttons.
  Widget _buildTopNav() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          // App name — tap goes home/scrolls-to-top, hold/right-click opens rename
          GestureDetector(
            onTap: () {
              if (widget.tabIndex == 0) {
                // Already on home page — snap to top instantly
                if (_homeScrollController.hasClients) {
                  _homeScrollController.jumpTo(0);
                }
              } else {
                // On another page (e.g. settings) — go back to home
                widget.onTabChanged(0);
              }
            },
            onLongPress: _showRenameDialog,
            onSecondaryTap: _showRenameDialog,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _appName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.white70,
                    letterSpacing: 0.5,
                  ),
                ),
                if (_appName.toLowerCase() == 'dinnertune') ...[
                  const SizedBox(width: 4),
                  const Icon(PhosphorIcons.pizza, size: 16, color: Colors.white70),
                ],
              ],
            ),
          ),
          const SizedBox(width: 4),

          // Source switcher — local only (no streaming sources)
          _buildSourceModeSwitcher(),

          // Spacer pushes remaining items to the right
          const Expanded(child: SizedBox.shrink()),

          // Grid search toggle — far right
          _buildGridSearchToggle(),
        ],
      ),
    );
  }

              /// Popup menu button: source selection + settings merged into one menu.
              /// Local-only version: just "local" (always active) and "settings".
              Widget _buildSourceModeSwitcher() {
                return PopupMenuButton<String>(
                  icon: const Icon(
                    PhosphorIcons.gridNine,
                    size: 18,
                    color: Colors.white70,
                  ),
                  enableFeedback: true,
                  color: Colors.grey[850],
                  position: PopupMenuPosition.under,
                  itemBuilder: (context) => [
                    // Local source — always active with checkmark
                    const PopupMenuItem<String>(
                      value: 'local',
                      child: Row(
                        children: [
                          Icon(PhosphorIcons.gridNine, size: 18, color: Colors.white70),
                          SizedBox(width: 12),
                          Text('local', style: TextStyle(fontSize: 13, color: Colors.white70)),
                          Spacer(),
                          Icon(Icons.check_rounded, size: 16, color: Colors.white70),
                        ],
                      ),
                    ),
                    // Divider before settings
                    const PopupMenuDivider(height: 8),
                    // Settings item — navigates to settings tab
                    const PopupMenuItem<String>(
                      value: 'settings',
                      child: Row(
                        children: [
                          Icon(Icons.tune, size: 18, color: Colors.white70),
                          SizedBox(width: 12),
                          Text('settings', style: TextStyle(fontSize: 13, color: Colors.white70)),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) {
                    if (value == 'settings') {
                      widget.onTabChanged(4);
                    } else if (value == 'local') {
                      widget.onTabChanged(0);
                    }
                  },
                );
              }

              /// Small toggle button — shows/hides the grid search overlay via OverlayEntry.
              Widget _buildGridSearchToggle() {
                final hasActiveSearch = _homeGridSearchResults != null && _homeGridSearchResults!.isNotEmpty;
                return IconButton(
                  icon: Icon(
                    Icons.search,
                    size: 20,
                    color: (_gridSearchOverlayEntry != null || hasActiveSearch) ? Colors.white : Colors.white54,
                  ),
                  onPressed: () {
                    if (_gridSearchOverlayEntry != null) {
                      _hideGridSearchOverlay();
                    } else {
                      _showGridSearchOverlay();
                    }
                  },
                );
              }

              /// Show the search overlay using OverlayEntry (renders above everything).
              void _showGridSearchOverlay() {
                // Pre-fill with current query so user sees context
                if (_gridSearchQuery != null) {
                  _gridSearchController.text = _gridSearchQuery!;
                } else {
                  _gridSearchController.clear();
                }

                final overlayEntry = OverlayEntry(
                  builder: (context) => Positioned(
                    top: 48, // Just below the header row
                    right: 12,
                    width: MediaQuery.of(context).size.width - 24, // Full width minus padding
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.grey[900]!.withOpacity(0.97),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12, width: 1),
                        ),
                        child: Row(
                          children: [
                            // Search field takes remaining space
                            Expanded(
                              child: TextField(
                                controller: _gridSearchController,
                                focusNode: _gridSearchFocusNode,
                                style: const TextStyle(fontSize: 14, color: Colors.white),
                                decoration: InputDecoration(
                                  hintText: 'search...',
                                  hintStyle: const TextStyle(color: Colors.white38),
                                  prefixIcon: const Icon(Icons.search, size: 20, color: Colors.white54),
                                  suffixIcon: null,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(color: Colors.white12, width: 1),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(color: Colors.white12, width: 1),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: Colors.white38, width: 1.5),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                ),
                                onSubmitted: (value) {
                                  _performGridSearch(value.trim());
                                },
                              ),
                            ),
                            // Close button
                            IconButton(
                              icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                              onPressed: _hideGridSearchOverlay,
                              constraints: const BoxConstraints(),
                              padding: EdgeInsets.zero,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );

                Overlay.of(context).insert(overlayEntry);
                setState(() => _gridSearchOverlayEntry = overlayEntry);
                WidgetsBinding.instance.addPostFrameCallback((_) =>
                    _gridSearchFocusNode.requestFocus());
              }

              /// Hide the search overlay and reset to default grid view.
              void _hideGridSearchOverlay() {
                if (_gridSearchOverlayEntry != null) {
                  _gridSearchOverlayEntry!.remove();
                  setState(() => _gridSearchOverlayEntry = null);
                  _gridSearchFocusNode.unfocus();
                  // Clear search results and restore default grid view
                  setState(() {
                    _homeGridSearchResults = null;
                    _gridSearchQuery = null;
                    _searchPage = 0;
                  });
                  resetTopPicks();
                }
              }




              /// Execute search across local library or streaming source.
              Future<void> _performGridSearch(String query) async {
                 // Empty query: reset to default grid view and close overlay
                 if (query.isEmpty) {
                   setState(() {
                     _homeGridSearchResults = null;
                     _gridSearchQuery = null;
                     _searchPage = 0;
                   });
                   resetTopPicks();
                   _hideGridSearchOverlay();
                   return;
                 }
                
                _hideGridSearchOverlay();
                setState(() {
                  _gridSearchQuery = query;
                  _searchPage = 0;
                });

                List<Song>? results;
                try {
                  // Search local library by title and artist
                  final lowerQuery = query.toLowerCase();
                  results = widget.allSongs.where((s) =>
                    s.title.toLowerCase().contains(lowerQuery) ||
                    (s.artist != null && s.artist!.toLowerCase().contains(lowerQuery))
                  ).toList()..shuffle(math.Random());
                } catch (e) {
                  debugPrint('Grid search error: $e');
                }

                if (mounted && results != null && results.isNotEmpty) {
                  setState(() {
                    _homeGridSearchResults = results;
                    _shuffledTopNine = results!.take(9).toList();
                  });
                  // Extract artwork for local songs in background
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    if (!mounted) return;
                    try {
                      final extractedSongs = await ArtworkExtractor.extractForSongsInMemory(_shuffledTopNine!);
                      if (mounted && extractedSongs != null) {
                        setState(() => _shuffledTopNine = extractedSongs);
                      }
                    } catch (_) {}
                  });
                } else if (mounted) {
                  // No results — clear search state
                  setState(() {
                    _homeGridSearchResults = null;
                    _gridSearchQuery = null;
                  });
                }
              }



  /// Home tab content.

  /// Home tab content.
  Widget _buildHomeTab() {
    final gridSongs = getGridSongs();

    return Stack(
      children: [
        CustomScrollView(
          controller: _homeScrollController,
          slivers: [
            // Spacing above the grid — reduced when collapsed so center buttons stay visible
            SliverToBoxAdapter(child: SizedBox(height: _listCollapsed ? 8.0 : 16.0)),

            // Top 9 grid
            // Top 9 grid (with horizontal swipe: right→shuffle, left→restore grid)
            SliverToBoxAdapter(
              child: GestureDetector(
                onHorizontalDragEnd: (details) {
                  if (details.primaryVelocity != null) {
                    setState(() {
                      if (details.primaryVelocity! > 0) {
                        // Swipe right → shuffle
                        shuffleTopNine(context);
                      } else {
                        // Swipe left → restore pinned grid (The Grid function)
                        resetTopPicks();
                        final scrollable = Scrollable.of(context);
                        scrollable.position.animateTo(
                          0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      }
                    });
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isDesktop =
                          Platform.isWindows ||
                          Platform.isMacOS ||
                          Platform.isLinux;
                      // On desktop, cap tile height so grid doesn't dominate the viewport
                       final bool _shouldExpandGrid = _listCollapsed;
                       final maxTileHeight = isDesktop ? (_shouldExpandGrid ? 270.0 : 180.0) : double.infinity;
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: isDesktop ? 1.0 : 0.9,
                          mainAxisExtent: isDesktop ? maxTileHeight : null,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: gridSongs.length,
                        itemBuilder: (context, index) {
                          final song = gridSongs[index];
                          return _buildTopTile(
                            song,
                            queue: gridSongs,
                            isSelected: _selectedGridTile == index,
                            showViz: _vizEnabled,
                            onTap: () {
                              setState(() => _selectedGridTile = index);
                              playSong(song, queue: gridSongs);
                            },
                          );
                        },
                      );
                    },
                  ),
                ), // close Padding
              ), // close GestureDetector (swipe handler)
            ),

            // Recent songs section header
             SliverToBoxAdapter(
               child: Padding(
                 padding: EdgeInsets.fromLTRB(8, _listCollapsed ? 6.0 : 12.0, 16, _listCollapsed ? 0.0 : 4.0),
                 child: Row(
                   mainAxisAlignment: MainAxisAlignment.spaceBetween,
                   children: [
                     Row(
                       mainAxisSize: MainAxisSize.min,
                       children: [
                          IconButton(
                            icon: Icon(
                              _listCollapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                              color: Colors.white70,
                              size: _listCollapsed ? 20.0 : 24.0,
                            ),
                              onPressed: () {
                                setState(() => _listCollapsed = !_listCollapsed);
                              },
                            ),
                         // Search icon — opens search bar popup under header buttons
                         IconButton(
                           onPressed: () {
                             setState(() { 
                               _showHomeSearch = !_showHomeSearch;
                               if (_showHomeSearch) {
                                 WidgetsBinding.instance.addPostFrameCallback((_) {
                                   _homeSearchFocusNode.requestFocus();
                                 });
                               }
                             });
                           },
                           icon: Icon(
                             Icons.search,
                             size: _listCollapsed ? 18.0 : 20.0,
                             color: _showHomeSearch ? Colors.white : Colors.white70,
                           ),
                         ),
                          // Section name button — tap opens Library/Mixes/Favorites popup menu
                           PopupMenuButton<String>(
                            onSelected: (selected) => setState(() { _activeHomeSection = selected; }),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'recent', child: Row(children: [Icon(Icons.history, size: 18, color: Colors.white70), SizedBox(width: 12), Text('recent songs')])),
                              PopupMenuItem(value: 'library', child: Row(children: [Icon(Icons.queue_music, size: 18, color: Colors.white70), SizedBox(width: 12), Text('library')])),
                              PopupMenuItem(value: 'mixes', child: Row(children: [Icon(PhosphorIcons.vinylRecordFill, size: 18, color: Colors.white70), SizedBox(width: 12), Text('mixes')])),
                              PopupMenuItem(value: 'favorites', child: Row(children: [Icon(PhosphorIcons.fireFill, size: 18, color: Colors.white70), SizedBox(width: 12), Text('favorites')])),
                            ],
                            child: Container(
                              padding: EdgeInsets.symmetric(horizontal: 8, vertical: _listCollapsed ? 1.0 : 3.0),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _activeHomeSection == null || _activeHomeSection == 'recent' ? 'recent' :
                                _activeHomeSection == 'library' ? 'library' :
                                _activeHomeSection == 'mixes' ? 'mixes' :
                                _activeHomeSection == 'favorites' ? 'favs' : 'recent',
                                style: TextStyle(
                                  fontSize: _listCollapsed ? 12.0 : 13.0,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white70,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // "Viz" button — toggle spectrum analyzer on selected tile.
                        // Long-press/right-click opens style options menu.
                        GestureDetector(
                          onSecondaryTapDown: (details) => _showVizOptions(),
                          onLongPress: _showVizOptions,
                          child: TextButton.icon(
                            onPressed: () {
                              setState(() => _vizEnabled = !_vizEnabled);
                              // FFT isolate is always running — no subscription toggle needed.
                            },
                            icon: Icon(
                              Icons.equalizer,
                              size: 16,
                              color: _vizEnabled ? Colors.white : Colors.white54,
                            ),
                            label: Text(
                              'viz',
                              style: TextStyle(
                                fontSize: 12,
                                color: _vizEnabled ? Colors.white : Colors.white54,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              minimumSize: const Size(0, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // "Tops" button — tap cycles most-played page; long-press/right-click resets to beginning
                                                                        GestureDetector(
                                                                          onSecondaryTap: () {
                                                                            resetTops();
                                                                          },
                                                                          onLongPress: () {
                                                                            resetTops();
                                                                          },
                                                  child: TextButton.icon(
                                                    onPressed: () {
                                                      showTops();
                                                    },
                                                    icon: const Icon(
                                                      Icons.trending_up,
                                                      size: 16,
                                                      color: Colors.white54,
                                                    ),
                                                    label: const Text(
                                                      'tops',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: Colors.white54,
                                                      ),
                                                    ),
                                                    style: TextButton.styleFrom(
                                                      padding: const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 2,
                                                      ),
                                                      minimumSize: const Size(0, 28),
                                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                    ),
                                                  ),
                                                ),
                        const SizedBox(width: 4),
                        // "Mix" button — tap saves mix; long-press/right-click randomly loads a mix
                         GestureDetector(
                           onSecondaryTap: () {
                             if (_mixes.isEmpty) return;
                             final randomMix = _mixes[math.Random().nextInt(_mixes.length)];
                             loadMixIntoGrid(randomMix);
                             widget.onTabChanged(0);
                           },
                           onLongPress: () {
                             if (_mixes.isEmpty) return;
                             final randomMix = _mixes[math.Random().nextInt(_mixes.length)];
                             loadMixIntoGrid(randomMix);
                             widget.onTabChanged(0);
                           },
                           child: TextButton.icon(
                             onPressed: () {
                               promptSaveMix(context);
                             },
                            icon: const Icon(
                              PhosphorIcons.vinylRecordFill,
                              size: 16,
                              color: Colors.white54,
                            ),
                            label: const Text(
                              'mix',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              minimumSize: const Size(0, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // "The Grid" button — tap restores pinned grid, long-press/right-click opens peek dialog
                        GestureDetector(
                          onSecondaryTap: () {
                            if (_currentSong != null) {
                              _openPeekDialog(_currentSong!);
                            }
                          },
                          onLongPress: () {
                            if (_currentSong != null) {
                              _openPeekDialog(_currentSong!);
                            }
                          },
                          child: TextButton.icon(
                            onPressed: () {
                                                          // Restore pinned grid by clearing shuffle, then scroll to top
                                                          resetTopPicks();
                              final scrollable = Scrollable.of(context);
                              scrollable.position.animateTo(
                                0,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              );
                            },
                            icon: const Icon(
                              PhosphorIcons.gridNineFill,
                              size: 16,
                              color: Colors.white54,
                            ),
                            label: Text(
                              _appName.toLowerCase() == 'undernightintune' ? 'GRD' : 'grid',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              minimumSize: const Size(0, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Shuffle button — icon only
                                                TextButton.icon(
                                                  onPressed: () {
                                                    shuffleTopNine(context);
                                                  },
                          icon: const Icon(
                            Icons.shuffle,
                            size: 16,
                            color: Colors.white54,
                          ),
                          label: const SizedBox.shrink(),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Home search bar popup — appears under the header buttons when active
            if (_showHomeSearch) SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: TextField(
                  controller: _homeSearchController,
                  focusNode: _homeSearchFocusNode,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search songs...',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                    prefixIcon: const Icon(Icons.search, size: 20, color: Colors.white54),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                      onPressed: () {
                        setState(() { 
                          _showHomeSearch = false; 
                          _searchQuery = null;
                          _homeSearchController.clear();
                          _homeSearchFocusNode.unfocus();
                        });
                      },
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onChanged: (q) {
                    if (_homeSearchController.text.trim().isEmpty && q.isEmpty) {
                      setState(() { _showHomeSearch = false; _searchQuery = null; });
                      return;
                    }
                    setState(() => _searchQuery = q);
                  },
                ),
              ),
            ),

            // Recent songs list (ordered by last played) — collapsed by default
            // Section content — swap based on active section selection, filtered when searching
            if (_activeHomeSection == 'library' && !_listCollapsed) ...[
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final songs = _searchQuery != null ? widget.allSongs.where((s) => s.title.toLowerCase().contains(_searchQuery!.toLowerCase()) || (s.artist != null && s.artist!.toLowerCase().contains(_searchQuery!.toLowerCase()))).toList() : widget.allSongs;
                  if (index >= songs.length) return const SizedBox.shrink();
                  final song = songs[index];
                  return _buildSongListItem(song);
                }, childCount: (_searchQuery != null ? widget.allSongs.where((s) => s.title.toLowerCase().contains(_searchQuery!.toLowerCase()) || (s.artist != null && s.artist!.toLowerCase().contains(_searchQuery!.toLowerCase()))).toList() : widget.allSongs).length),
              ),
            ] else if (_activeHomeSection == 'mixes' && !_listCollapsed) ...[
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final mixes = _searchQuery != null ? _mixes.where((m) => m['title'].toString().toLowerCase().contains(_searchQuery!.toLowerCase())).toList() : _mixes;
                  if (index >= mixes.length) return const SizedBox.shrink();
                  final mix = mixes[index];
                  return _buildMixTile(mix);
                }, childCount: (_searchQuery != null ? _mixes.where((m) => m['title'].toString().toLowerCase().contains(_searchQuery!.toLowerCase())).toList() : _mixes).length),
              ),
            ] else if (_activeHomeSection == 'favorites' && !_listCollapsed) ...[
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final songs = _searchQuery != null ? _favorites.where((s) => s.title.toLowerCase().contains(_searchQuery!.toLowerCase()) || (s.artist != null && s.artist!.toLowerCase().contains(_searchQuery!.toLowerCase()))).toList() : _favorites;
                  if (index >= songs.length) return const SizedBox.shrink();
                  final song = songs[index];
                  return _buildSongTile(
                    song,
                    onTap: () => playSong(song, queue: _favorites),
                    trailingWidget: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _playCounts[song.id]?.toString() ?? '0',
                          style: const TextStyle(fontSize: 10, color: Colors.white38),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white38),
                          onPressed: () => _removeFromFavorites(song.id),
                          tooltip: 'Remove from favorites',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  );
                }, childCount: (_searchQuery != null ? _favorites.where((s) => s.title.toLowerCase().contains(_searchQuery!.toLowerCase()) || (s.artist != null && s.artist!.toLowerCase().contains(_searchQuery!.toLowerCase()))).toList() : _favorites).length),
              ),
            ] else if (!_listCollapsed) ...[
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final recentSongList = getRecentSongs();
                  final songs = _searchQuery != null ? recentSongList.where((s) => s.title.toLowerCase().contains(_searchQuery!.toLowerCase()) || (s.artist != null && s.artist!.toLowerCase().contains(_searchQuery!.toLowerCase()))).toList() : recentSongList;
                  if (index >= songs.length) return const SizedBox.shrink();
                  final song = songs[index];
                  return _buildSongListItem(song);
                }, childCount: (() {
                  final recentSongList = getRecentSongs();
                  return (_searchQuery != null ? recentSongList.where((s) => s.title.toLowerCase().contains(_searchQuery!.toLowerCase()) || (s.artist != null && s.artist!.toLowerCase().contains(_searchQuery!.toLowerCase()))).toList() : recentSongList).length;
                })()),
              ),
            ],

            // Bottom padding — reduced when collapsed (no song list behind play bar)
            SliverToBoxAdapter(child: SizedBox(height: _listCollapsed ? 4.0 : 80.0)),
          ],
        ),
      ],
    );
  }

  /// Pin mode overlay — semi-transparent dialog for assigning current song to a tile.
  Widget _buildPinModeOverlay(List<Song> gridSongs) {
    // Check if we're in mix edit mode (editing a mix via the mixes tab)
    final isMixEdit = _editingMix != null;
    final List<Song>? displaySongs = isMixEdit ? _editMixSongs : null;

    return Positioned.fill(
      child: GestureDetector(
        onTap: () async {
          if (isMixEdit) await saveEditMix();
          setState(() {
            _pinMode = false;
            _pinSwapSourceIndex = null;
          });
        },
        child: Container(
          color: Colors.black54,
          child: Center(
            child: GestureDetector(
              onTap: () {}, // prevent tap from propagating to dismiss
              child: Container(
                width: 320,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isMixEdit ? 'Edit mix' : 'Pin current song to a tile',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    // Show swap hint when in swap mode (not mix edit)
                    if (!isMixEdit && _pinSwapSourceIndex != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'Tap a tile to swap with ${_pinSwapSourceIndex! + 1}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    // Show the song that will be pinned (from tile or current song) — only in pin mode
                    if (!isMixEdit && _pinSourceSong != null || !isMixEdit && _currentSong != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          _pinSourceSong?.displayName ??
                              _currentSong?.displayName ??
                              '',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 12),
                    // 3x3 grid for tile selection (or mix edit)
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 1.0,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          ),
                      itemCount: isMixEdit ? (displaySongs?.length ?? 9) : 9,
                      itemBuilder: (context, index) {
                        // In mix edit mode, use displaySongs; otherwise use pinned grid.
                        final Song? song = isMixEdit
                            ? (displaySongs != null && index < displaySongs.length ? displaySongs[index] : null)
                            : (_pinnedGrid.containsKey(index) ? _pinnedGrid[index] : null);

                        final bool hasSong = song != null;
                        final bool isSwapSource = _pinSwapSourceIndex == index;
                        final bool showPinIcon = !isMixEdit && _pinnedGrid.containsKey(index);

                        return GestureDetector(
                          onTap: () async {
                            if (isMixEdit) {
                              // Mix edit mode: two-tap swap between songs in the mix.
                              if (_pinSwapSourceIndex == null) {
                                setState(() => _pinSwapSourceIndex = index);
                              } else {
                                // Swap the two tiles in the working copy.
                                final temp = displaySongs![index];
                                displaySongs[index] = displaySongs[_pinSwapSourceIndex!];
                                displaySongs[_pinSwapSourceIndex!] = temp;
                                setState(() => _pinSwapSourceIndex = null);
                              }
                            } else if (_pinSourceSong != null) {
                              // Normal pin mode: assign the source song to this tile.
                              await pinSongToTile(_pinSourceSong!, index);
                              setState(() => _pinMode = false);
                              _pinSourceSong = null;
                            } else if (!isMixEdit && _pinSwapSourceIndex != null) {
                              // Swap mode: swap two tiles in the pinned grid.
                              final sourceIdx = _pinSwapSourceIndex!;
                              final hasSrc = _pinnedGrid.containsKey(sourceIdx);
                              final hasDst = _pinnedGrid.containsKey(index);

                              if (hasSrc && hasDst) {
                                // Both have songs — swap them.
                                final srcSong = _pinnedGrid[sourceIdx]!;
                                final dstSong = _pinnedGrid[index]!;
                                _pinnedGrid[index] = srcSong;
                                _pinnedGrid[sourceIdx] = dstSong;
                              } else if (hasSrc && !hasDst) {
                                // Source has a song, destination is empty — move it.
                                final movedSong = _pinnedGrid.remove(sourceIdx)!;
                                _pinnedGrid[index] = movedSong;
                              } else if (!hasSrc && hasDst) {
                                // Reverse: source was empty tap, dest has song — swap anyway.
                                final dstSong = _pinnedGrid.remove(index)!;
                                _pinnedGrid[sourceIdx] = dstSong;
                              }

                              setState(() => _pinSwapSourceIndex = null);
                            } else if (!isMixEdit && hasSong) {
                              // No source song and no swap in progress — start a swap.
                              setState(() => _pinSwapSourceIndex = index);
                            }
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSwapSource ? Colors.white38 : (hasSong ? Colors.white24 : Colors.grey[850]),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: showPinIcon ? Colors.white70 : (isSwapSource ? Colors.white70 : Colors.white12),
                                width: 1,
                              ),
                            ),
                            child: Stack(
                              children: [
                                if (showPinIcon) ...[
                                  Positioned(
                                    top: 2,
                                    right: 2,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: BoxDecoration(
                                        color: Colors.white54,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.push_pin,
                                        size: 10,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ),
                                ],
                                Positioned(
                                  bottom: 2,
                                  left: 4,
                                  child: Text(
                                    '${index + 1}',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: Colors.white38,
                                    ),
                                  ),
                                ),
                                // Show song title centered (if a song is in this tile)
                                if (hasSong)
                                  Center(
                                    child: Text(
                                      song!.title,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    // Pin to Favorites button (only when NOT in favorites tab/section and not mix edit)
                      if (!isMixEdit && widget.tabIndex != 3 && _activeHomeSection != 'favorites')
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: () async {
                                final song = _pinSourceSong ?? _currentSong;
                                if (song != null) await _addToFavorites(song);
                                setState(() => _pinMode = false);
                                _pinSourceSong = null;
                              },
                              icon: const Icon(
                                 PhosphorIcons.fire,
                                   size: 14,
                                   color: Colors.white54,
                                 ),
                                 label: const Text(
                                   'Pin to Favorites',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                          ],
                        ),
                      // Remove from Favorites button (only when in favorites tab or favorites home section)
                      if (!isMixEdit && (widget.tabIndex == 3 || _activeHomeSection == 'favorites') && _pinSourceSong != null)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: () async {
                                await _removeFromFavorites(_pinSourceSong!.id);
                                setState(() => _pinMode = false);
                                _pinSourceSong = null;
                              },
                              icon: const Icon(
                                 PhosphorIcons.fire,
                                   size: 14,
                                   color: Colors.white54,
                                 ),
                                 label: const Text(
                                   'Remove from Favorites',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                          ],
                        ),
                    TextButton(
                      onPressed: () async {
                        if (isMixEdit) await saveEditMix();
                        setState(() => _pinMode = false);
                        _pinSwapSourceIndex = null;
                      },
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 12, color: Colors.white54),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

    /// Top tile with generated pattern.
  Widget _buildTopTile(
    Song song, {
    List<Song>? queue,
    bool isSelected = false,
    required VoidCallback onTap,
    bool showViz = false,
  }) {
    final context = _tileContext(song);

    return GestureDetector(
      onTap: onTap,
      onLongPress: () {
        _openPeekDialog(song);
      },
      onSecondaryTap: () {
        _openPeekDialog(song);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            flex: 3,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: isSelected ? Colors.grey[500]! : Colors.transparent,
                  width: isSelected ? 1.0 : 0,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
             child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: showViz && isSelected
                      ? _VizTile(songTitle: song.title)
                      : _showAlbumArt
                      ? AlbumArtTile(title: song.title, artworkBytes: song.artworkBytes, sunlightFactor: _brightAlbumArt ? 1.0 : 0.0)
                      : TitlePattern(title: song.title, sunlightFactor: _brightAlbumArt ? 1.0 : 0.0),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            flex: context.isNotEmpty ? 2 : 1,
            child: context.isNotEmpty
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                          song.title,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 1),
                        Text(
                          context,
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.white54,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ],
                      )
                      : Text(
                      song.title,
                      style: const TextStyle(
                        fontSize: 12,
                      color: Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
          ),
        ],
      ),
    );
  }

  /// Returns a context string for the tile label — artist first, then folder.
  String _tileContext(Song song) {
    // Treat "Unknown Artist" as blank — fall through to folder
    final artist = song.artist;
    if (artist != null &&
        artist.isNotEmpty &&
        artist.toLowerCase() != 'unknown artist') {
      return artist;
    }
    // Fallback: extract parent folder name from URI/path
    final uri = song.uri;
    final separator = uri.contains(r'\') ? r'\' : '/';
    final parts = uri.split(separator);
    if (parts.length >= 2) {
      return parts[parts.length - 2];
    }
    return '';
  }

  /// Check if a song is in favorites.
  bool _isFavorite(int songId) => _favorites.any((s) => s.id == songId);

  /// Add song to favorites and persist.
  Future<void> _addToFavorites(Song song) async {
    if (_isFavorite(song.id)) return;
    setState(() => _favorites.add(song));
    await AppSettings.saveFavorites(
      _favorites.map((s) => s.toJson()).toList(),
    );
  }

  /// Remove song from favorites and persist.
  Future<void> _removeFromFavorites(int songId) async {
    setState(() => _favorites.removeWhere((s) => s.id == songId));
    await AppSettings.saveFavorites(
      _favorites.map((s) => s.toJson()).toList(),
    );
  }

   /// Shared ListTile for song list items — used by both main lists and favorites.
     Widget _buildSongTile(Song song, {VoidCallback? onTap, Widget? trailingWidget}) {
       return GestureDetector(
         onLongPress: () {
           _openPeekDialog(song);
         },
         onSecondaryTap: () {
           if (_isDesktop) {
             _openPeekDialog(song);
           }
         },
         child: ListTile(
           leading: _showAlbumArt
               ? AlbumArtThumbnail(title: song.title, artworkBytes: song.artworkBytes)
               : Container(
                   width: 40,
                   height: 40,
                   decoration: BoxDecoration(
                     color: Colors.grey[850],
                     borderRadius: BorderRadius.circular(4),
                   ),
                   alignment: Alignment.center,
                   child: const Icon(Icons.music_note, size: 18, color: Colors.white24),
                 ),
           title: Text(
             song.title,
             style: const TextStyle(color: Colors.white, fontSize: 13),
             maxLines: 1,
             overflow: TextOverflow.ellipsis,
           ),
           subtitle: Text(
             songDisplayArtist(song),
             style: const TextStyle(color: Colors.white54, fontSize: 11),
             maxLines: 1,
             overflow: TextOverflow.ellipsis,
           ),
           trailing: trailingWidget ?? Text(
              _playCounts[song.id]?.toString() ?? '0',
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
           onTap: onTap,
         ),
       );
     }

    Widget _buildSongListItem(Song song) {
    return _buildSongTile(song, onTap: () => playSong(song));
  }

  /// Perform search with debounce.
  Future<void> _doSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _searchResults = []);
      _searchDebounce?.cancel();
      return;
    }
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _isSearching = true);

      // Search local library
      final lib = MusicLibrary();
      await lib.init();
      final results = await lib.search(q);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
    });
  }

  /// Search within favorites list with debounce.
  Future<void> _doFavSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _favSearchResults = []);
      _favSearchDebounce?.cancel();
      return;
    }
    _favSearchDebounce?.cancel();
    _favSearchDebounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _favIsSearching = true);
      final lib = MusicLibrary();
      await lib.init();
      final results = await lib.search(q);
      final favIds = _favorites.map((s) => s.id).toSet();
      if (mounted) {
        setState(() {
          _favSearchResults = results
              .where((r) => favIds.contains(r.id))
              .toList();
          _favIsSearching = false;
        });
      }
    });
  }

  /// Library tab content.
  /// Group songs by first character (A-Z, 0-9, # for other).
  Map<String, List<Song>> _groupedSongs = {};
  List<String> _sortedSectionKeys = [];
  final Map<String, GlobalKey> _sectionKeys = {};

  void _buildGroupedSongs() {
    if (_groupedSongs.isNotEmpty) return; // Only build once
    final groups = <String, List<Song>>{};
    for (final song in widget.allSongs) {
      final firstChar = song.title.isNotEmpty
          ? song.title[0].toUpperCase()
          : '#';
      if (!RegExp(r'^[A-Z0-9]$').hasMatch(firstChar)) {
        groups.putIfAbsent('#', () => []).add(song);
      } else {
        groups.putIfAbsent(firstChar, () => []).add(song);
      }
    }
    _groupedSongs = groups;

    // Sorted section keys: # first, then numbers, then letters
    final allKeys = groups.keys.toList()
      ..sort((a, b) {
        if (a == '#') return -2;
        if (b == '#') return 2;
        final aIsDigit = RegExp(r'^[0-9]$').hasMatch(a);
        final bIsDigit = RegExp(r'^[0-9]$').hasMatch(b);
        if (aIsDigit && !bIsDigit) return -1;
        if (!aIsDigit && bIsDigit) return 1;
        return a.compareTo(b);
      });
    _sortedSectionKeys = allKeys;

    // Create keys for each section
    for (final key in allKeys) {
      _sectionKeys[key] = GlobalKey();
    }
  }

  /// Scroll to the given letter section.
  void _scrollToSection(String key) {
    final context = _sectionKeys[key]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
      );
    }
  }

  Widget _buildLibraryTab() {
    _buildGroupedSongs();

    final hasSearchQuery = _searchController.text.trim().isNotEmpty;

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            // Sticky search field at top of library tab
            SliverPersistentHeader(
              pinned: true,
              delegate: _SearchBarDelegate(
                _searchController,
                _doSearch,
                focusNode: _librarySearchFocusNode,
              ),
            ),

            // Show search results or full library based on query
            if (hasSearchQuery) ...[
              if (_isSearching)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_searchResults.isEmpty)
                const SliverFillRemaining(
                  child: Center(
                    child: Text(
                      'no results found',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final song = _searchResults[index];
                    return GestureDetector(
                      onLongPress: () {
                        _openPeekDialog(song);
                      },
                      onSecondaryTap: () {
                        if (_isDesktop) {
                          _openPeekDialog(song);
                        }
                      },
                      child: ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.grey[850],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.music_note,
                            size: 18,
                            color: Colors.white24,
                          ),
                        ),
                        title: Text(
                          song.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          songDisplayArtist(song),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: _isDesktop
                            ? null
                            : Text(
                                song.formattedDuration,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white38,
                                ),
                              ),
                        onTap: () => playSong(song, queue: _searchResults),
                      ),
                    );
                  }, childCount: _searchResults.length),
                ),
            ] else ...[
              // Full library with alphabet sections
              ..._sortedSectionKeys.map((key) {
                final songs = _groupedSongs[key]!;
                return SliverMainAxisGroup(
                  key: _sectionKeys[key],
                  slivers: [
                    // Sticky section header
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _SectionHeaderDelegate(key),
                    ),
                    // Songs in this group
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final song = songs[index];
                        return _buildSongListItem(song);
                      }, childCount: songs.length),
                    ),
                  ],
                );
              }),
            ],
            // Bottom padding for player
            if (!hasSearchQuery)
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),

        // Alphabet index bar on the right edge (only show when not searching)
        if (!hasSearchQuery)
          Positioned(
            top: 68, // Start below the search bar area, inside black bar separator
            bottom: 80, // Leave room for player
            right: 0,
            child: _buildAlphabetIndex(),
          ),
      ],
    );
  }

  /// Thin vertical alphabet index bar.
  Widget _buildAlphabetIndex() {
    // Build all possible section labels (# + 0-9 + A-Z)
    final allLabels = <String>['#'];
    for (int i = 0; i <= 9; i++) {
      allLabels.add(i.toString());
    }
    for (int c = 65; c <= 90; c++) {
      allLabels.add(String.fromCharCode(c));
    }

    // Filter to only sections that exist
    final activeLabels = allLabels
        .where((l) => _groupedSongs.containsKey(l))
        .toList();

    if (activeLabels.isEmpty) return const SizedBox.shrink();

    return Container(
      width: 16,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListView.builder(
        itemCount: activeLabels.length,
        itemBuilder: (context, index) {
          final label = activeLabels[index];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _scrollToSection(label),
            child: Center(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                  color: Colors.white54,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Favorites tab - mirrors library layout but shows only pinned songs.
  Widget _buildFavoritesTab() {
    final hasSearchQuery = _searchController.text.trim().isNotEmpty;

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            // Sticky search field at top of favorites tab
            SliverPersistentHeader(
              pinned: true,
              delegate: _SearchBarDelegate(
                _searchController,
                _doFavSearch,
                focusNode: _favoritesSearchFocusNode,
              ),
            ),

            if (hasSearchQuery) ...[
              if (_favIsSearching)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_favSearchResults.isEmpty)
                const SliverFillRemaining(
                  child: Center(
                    child: Text(
                      'no results found',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final song = _favSearchResults[index];
                    return GestureDetector(
                      onLongPress: () {
                        _openPeekDialog(song);
                      },
                      onSecondaryTap: () {
                        if (_isDesktop) {
                          _openPeekDialog(song);
                        }
                      },
                      onTap: () => playSong(song, queue: _favSearchResults),
                       child: ListTile(
                         leading: Container(
                           width: 40,
                           height: 40,
                           decoration: BoxDecoration(
                             color: Colors.grey[850],
                             borderRadius: BorderRadius.circular(4),
                           ),
                           alignment: Alignment.center,
                           child: const Icon(
                                PhosphorIcons.fireFill,
                                size: 18,
                                color: Colors.white24,
                              ),
                            ),
                            title: Text(
                              song.title,
                           style: const TextStyle(
                             color: Colors.white,
                             fontSize: 13,
                           ),
                           maxLines: 1,
                           overflow: TextOverflow.ellipsis,
                         ),
                         subtitle: Text(
                           songDisplayArtist(song),
                           style: const TextStyle(
                             color: Colors.white54,
                             fontSize: 11,
                           ),
                           maxLines: 1,
                           overflow: TextOverflow.ellipsis,
                         ),
                         trailing: Row(
                           mainAxisSize: MainAxisSize.min,
                           children: [
                             Text(
                               _playCounts[song.id]?.toString() ?? '0',
                               style: const TextStyle(fontSize: 10, color: Colors.white38),
                             ),
                             const SizedBox(width: 8),
                             IconButton(
                               icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white38),
                               onPressed: () => _removeFromFavorites(song.id),
                               tooltip: 'Remove from favorites',
                               padding: EdgeInsets.zero,
                               constraints: const BoxConstraints(),
                             ),
                           ],
                         ),
                       ),
                    );
                  }, childCount: _favSearchResults.length),
                ),
            ] else ...[
              // Full favorites list
              if (_favorites.isEmpty)
                const SliverFillRemaining(
                  child: Center(
                    child: Text(
                      'no favorites yet',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              else
                SliverList(
                   delegate: SliverChildBuilderDelegate((context, index) {
                     final song = _favorites[index];
                     return _buildSongTile(
                       song,
                       onTap: () => playSong(song, queue: _favorites),
                       trailingWidget: Row(
                         mainAxisSize: MainAxisSize.min,
                         children: [
                           Text(
                             _playCounts[song.id]?.toString() ?? '0',
                             style: const TextStyle(fontSize: 10, color: Colors.white38),
                           ),
                           const SizedBox(width: 8),
                           IconButton(
                             icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white38),
                             onPressed: () => _removeFromFavorites(song.id),
                             tooltip: 'Remove from favorites',
                             padding: EdgeInsets.zero,
                             constraints: const BoxConstraints(),
                           ),
                         ],
                       ),
                     );
                   }, childCount: _favorites.length),
                 ),
            ],

            // Bottom padding for player
            if (!hasSearchQuery)
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      ],
    );
  }

   /// Mixes tab — list of saved mixes with search and delete.
   Widget _buildMixesTab() {
     final hasSearchQuery = _searchController.text.trim().isNotEmpty;
     final filteredMixes = hasSearchQuery
         ? _mixes.where((m) {
             final name = (m['name'] as String? ?? '').toLowerCase();
             return name.contains(_searchController.text.toLowerCase());
           }).toList()
         : _mixes;

     return Stack(
       children: [
         CustomScrollView(
           slivers: [
             // Sticky search field at top of mixes tab
             SliverPersistentHeader(
               pinned: true,
               delegate: _SearchBarDelegate(
                 _searchController,
                 (_) {}, // no async search needed — filter is synchronous
                 focusNode: _mixesSearchFocusNode,
               ),
             ),

             if (hasSearchQuery) ...[
               if (filteredMixes.isEmpty)
                 const SliverFillRemaining(
                   child: Center(
                     child: Text(
                       'no results found',
                       style: TextStyle(color: Colors.white54),
                     ),
                   ),
                 )
               else
                 SliverList(
                   delegate: SliverChildBuilderDelegate((context, index) {
                     final mix = filteredMixes[index];
                     return _buildMixTile(mix);
                   }, childCount: filteredMixes.length),
                 ),
             ] else ...[
               // Full mixes list
               if (_mixes.isEmpty)
                 const SliverFillRemaining(
                   child: Center(
                     child: Text(
                       'no mixes yet',
                       style: TextStyle(color: Colors.white54),
                     ),
                   ),
                 )
               else
                 SliverList(
                   delegate: SliverChildBuilderDelegate((context, index) {
                     final mix = _mixes[index];
                     return _buildMixTile(mix);
                   }, childCount: _mixes.length),
                 ),
             ],

             // Bottom padding for player
             if (!hasSearchQuery)
               const SliverToBoxAdapter(child: SizedBox(height: 80)),
           ],
         ),
       ],
     );
   }

   /// Build a single mix list tile with delete button.
   Widget _buildMixTile(Map<String, dynamic> mix) {
     final name = mix['name'] as String? ?? 'untitled';
     final songCount = (mix['songIds'] as List).length;
     final id = mix['id'] as int;

     return GestureDetector(
       onSecondaryTap: () => openMixEdit(mix),
       onLongPress: () => openMixEdit(mix),
       child: ListTile(
         leading: Container(
           width: 40,
           height: 40,
           decoration: BoxDecoration(
             color: Colors.grey[850],
             borderRadius: BorderRadius.circular(4),
           ),
           alignment: Alignment.center,
           child: const Icon(
             Icons.audiotrack,
             size: 18,
             color: Colors.white24,
           ),
         ),
         title: Text(
           name,
           style: const TextStyle(
             color: Colors.white,
             fontSize: 13,
           ),
           maxLines: 1,
           overflow: TextOverflow.ellipsis,
         ),
         subtitle: Text(
           '$songCount songs',
           style: const TextStyle(
             color: Colors.white54,
             fontSize: 11,
           ),
         ),
         onTap: () {
          loadMixIntoGrid(mix);
          widget.onTabChanged(0); // go home to see the mix in the grid
        },
         trailing: IconButton(
           icon: const Icon(
             Icons.delete_outline,
             size: 18,
             color: Colors.white38,
           ),
           onPressed: () async {
             await deleteMix(id);
           },
           tooltip: 'Delete',
           padding: EdgeInsets.zero,
           constraints: const BoxConstraints(),
         ),
       ),
     );
     }

     /// Mix edit overlay — shows all songs in the mix with swap capability.
      /// Bottom player bar with controls.
  Widget _buildBottomPlayer() {
    if (_currentSong == null) return const SizedBox.shrink();

    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    String fmt(Duration d) {
      final m = d.inMinutes.toString().padLeft(2, '0');
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[850],
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress bar (thin) — minHeight increased slightly for easier touch detection
          GestureDetector(
            onTapDown: (tapDetails) {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null && _duration.inMilliseconds > 0) {
                final x =
                    tapDetails.globalPosition.dx -
                    box.localToGlobal(Offset.zero).dx;
                final ratio = x.clamp(0.0, box.size.width) / box.size.width;
                AudioPlayerService.seek(
                  Duration(
                    milliseconds: (_duration.inMilliseconds * ratio).round(),
                  ),
                );
              }
            },
            onHorizontalDragUpdate: (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null) {
                final x =
                    details.globalPosition.dx -
                    box.localToGlobal(Offset.zero).dx;
                final ratio = x.clamp(0.0, box.size.width) / box.size.width;
                AudioPlayerService.seek(
                  Duration(
                    milliseconds: (_duration.inMilliseconds * ratio).round(),
                  ),
                );
              }
            },
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Colors.transparent,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white70),
              minHeight: 5,
            ),
          ),

          // Controls row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // Volume slider (desktop only) — vertical, far left edge. Drag up to increase, down to decrease.
                if (_isDesktop) ...[
                  SizedBox(
                    width: 6,
                    height: 50,
                    child: RotatedBox(
                      quarterTurns: -1,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 3.5),
                           overlayShape: const RoundSliderOverlayShape(overlayRadius: 6),
                          activeTrackColor: Colors.white38,
                          inactiveTrackColor: Colors.transparent,
                          thumbColor: Colors.white54,
                          overlayColor: Colors.white.withValues(alpha: 0.1),
                        ),
                        child: Slider(
                          value: _volume.clamp(0.0, 1.0),
                          onChanged: (v) {
                            setState(() => _volume = v);
                            AudioPlayerService.setVolume(v);
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],

                // Song info (expandable)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Time position — on its own line above title
                      Text(
                        '${fmt(_position)} / ${fmt(_duration)}',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        _currentSong!.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _currentSong!.artist ?? 'Unknown Artist',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 2),

                       // Filter control: rotary knob with small dot below; tap/double-tap/right-click resets to neutral.
                            Listener(
                              onPointerDown: (e) {
                                if (e.buttons == 2) _resetFilter();
                              },
                              child: GestureDetector(
                                onTap: () {}, // absorb single taps so they don't propagate
                                onDoubleTap: _resetFilter,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    RotaryFilterKnob(
                                      value: _filterControl,
                                      onChanged: (v) => setState(() {
                                        _filterControl = v;
                                        AudioPlayerService.setFilterControl(v);
                                      }),
                                    ),
                                    const SizedBox(height: 2),
                                    // Small dot — tappable to reset filter to neutral
                                    GestureDetector(
                                      onTap: _resetFilter,
                                      child: Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: _filterControl.abs() > 0.02 ? Colors.white : Colors.grey[700],
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                        const SizedBox(width: 8),

                // Skip previous
                IconButton(
                  icon: const Icon(
                    Icons.skip_previous,
                    size: 24,
                    color: Colors.white70,
                  ),
                  onPressed: _skipToPrevious,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),

                const SizedBox(width: 8),

                // Play/Pause (square button)
                GestureDetector(
                  onTap: () {
                    AudioPlayerService.togglePlayPause();
                    // Force UI sync — stream emission may lag on release builds
                    setState(() => _isPlaying = !_isPlaying);
                  },
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 24,
                      color: Colors.white,
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // Skip next
                IconButton(
                  icon: const Icon(
                    Icons.skip_next,
                    size: 24,
                    color: Colors.white70,
                  ),
                  onPressed: _skipToNext,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),

                // Shuffle All toggle button — extra space from skip next (desktop only)
                if (_isDesktop) const SizedBox(width: 16),
                IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    size: 22,
                    color: _shuffleAll ? Colors.white : Colors.white54,
                  ),
                  onPressed: () => toggleShuffleAll(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Shuffle All',
                ),

                const SizedBox(width: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Extract parent folder name from song URI — for display and matching.
  String _songFolder(Song song) {
    final uri = song.uri;
    final separator = uri.contains(r'\') ? r'\' : '/';
    final parts = uri.split(separator);
    if (parts.length >= 3) return '${parts[parts.length - 3]} / ${parts[parts.length - 2]}';
    if (parts.length >= 2) return parts[parts.length - 2];
    return '';
  }

  /// Find a similar local song, excluding [sourceSong].
  /// Matches by artist or folder name.
  Song? _findFeaturedShuffle(Song sourceSong) {
    final allSongs = widget.allSongs;
    if (allSongs.isEmpty) return null;

    final sourceArtist = sourceSong.artist;
    final validArtist = sourceArtist != null &&
        sourceArtist.isNotEmpty &&
        sourceArtist.toLowerCase() != 'unknown artist';
    final sourceFolder = _songFolder(sourceSong);

    final candidates = allSongs.where((s) {
      if (s.id == sourceSong.id) return false;
      if (validArtist && s.artist != null && s.artist!.toLowerCase() == sourceArtist.toLowerCase()) {
        return true;
      }
      if (sourceFolder.isNotEmpty && _songFolder(s) == sourceFolder) {
        return true;
      }
      return false;
    }).toList();

    if (candidates.isEmpty) return null;

    final rng = math.Random();
    return candidates[rng.nextInt(candidates.length)];
  }

  /// Open the peek dialog for [song]. When [gridIndex] is provided (from grid tiles),
  /// Featured Shuffle uses it as context. Play always just plays — pin via "Pin to tile".
  void _openPeekDialog(Song song, [int? gridIndex]) {
    setState(() {
      _peekSong = song;
      _peekGridIndex = gridIndex;
    });

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _PeekDialog(
        song: song,
        playCount: _playCounts[song.id] ?? 0,
        isFavorite: _isFavorite(song.id),
        onToggleFavorite: () {
          if (_isFavorite(song.id)) {
            _removeFromFavorites(song.id);
          } else {
            _addToFavorites(song);
          }
          Navigator.of(ctx).pop();
          _openPeekDialog(song, gridIndex);
        },
        onPlay: () {
          Navigator.of(ctx).pop();
          playSong(song);
        },
        onShuffleMore: () async {
          // Cycle to a similar song in peek view — does NOT touch the grid
          final sourceSong = gridIndex != null ? getGridSongs()[gridIndex] : song;
          Song? candidate = _findFeaturedShuffle(sourceSong);
          if (candidate == null) return;

          Song picked = candidate;

          // Extract artwork when album art setting is active.
          if (_showAlbumArt && mounted) {
            try {
              final withArt = await ArtworkExtractor.extractForSongsInMemory([picked]);
              if (withArt.isNotEmpty) {
                picked = withArt[0];
              }
            } catch (e) {
              debugPrint('Peek shuffle artwork extraction failed: $e');
            }
          }

          if (!mounted) return;
          Navigator.of(ctx).pop();
          _openPeekDialog(picked, gridIndex);
        },
        onPinToTile: (tileIndex) {
          Navigator.of(ctx).pop();
          setState(() {
            _pinnedGrid[tileIndex] = song;
          });
          _savePinnedGrid();
        },
        pinnedGrid: Map<int, Song>.from(_pinnedGrid),
      ),
    );
  }
}

/// Peek dialog — album art preview with pin-to-tile grid and action buttons.
class _PeekDialog extends StatefulWidget {
  final Song song;
  final int playCount;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback onPlay;
  /// Featured Shuffle — cycle to a similar song in peek preview.
  final Future<void> Function()? onShuffleMore;
  /// Pin this song to a specific tile index (0-8).
  final ValueChanged<int> onPinToTile;
  /// Current pinned grid state for display in the selector.
  final Map<int, Song> pinnedGrid;

  const _PeekDialog({
    required this.song,
    required this.playCount,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onPlay,
    required this.onShuffleMore,
    required this.onPinToTile,
    required this.pinnedGrid,
  });

  @override
  State<_PeekDialog> createState() => _PeekDialogState();
}

class _PeekDialogState extends State<_PeekDialog> {

  /// Extract parent folder name from song URI.
  String _songFolder(Song song) {
    final uri = song.uri;
    final separator = uri.contains(r'\') ? r'\' : '/';
    final parts = uri.split(separator);
    if (parts.length >= 2) return parts[parts.length - 2];
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final songFolder = _songFolder(widget.song);

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Album art — swipe right to featured shuffle.
            GestureDetector(
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
                  widget.onShuffleMore?.call();
                }
              },
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: widget.song.artworkBytes != null && widget.song.artworkBytes!.isNotEmpty
                      ? Image.memory(
                          widget.song.artworkBytes!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _patternFallback(widget.song.title),
                        )
                      : _patternFallback(widget.song.title),
                ),
              ),
            ),

            // Track details section — compact side-by-side metadata
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.song.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // Artist + album/folder side by side
                  Row(
                    children: [
                      const Icon(Icons.person_outline_rounded, size: 13, color: Colors.white54),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          songDisplayArtist(widget.song),
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if ((widget.song.album != null && widget.song.album!.isNotEmpty) || songFolder.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.album_rounded, size: 13, color: Colors.white54),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            widget.song.album != null && widget.song.album!.isNotEmpty
                                ? widget.song.album!
                                : songFolder,
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Duration + plays + folder on one line
                  Row(
                    children: [
                      const Icon(Icons.schedule_rounded, size: 13, color: Colors.white54),
                      const SizedBox(width: 4),
                      Text(
                        widget.song.formattedDuration,
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(width: 12),
                      const Icon(Icons.play_circle_outline_rounded, size: 13, color: Colors.white54),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.playCount} plays',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      if (songFolder.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.folder_rounded, size: 13, color: Colors.white54),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            songFolder,
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Pin to tile — 3x3 grid selector (no label)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 1.0,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                ),
                itemCount: 9,
                itemBuilder: (context, index) {
                      final Song? pinned = widget.pinnedGrid[index];
                      final bool occupied = pinned != null;
                      return GestureDetector(
                        onTap: () => widget.onPinToTile(index),
                        child: Container(
                          decoration: BoxDecoration(
                            color: occupied ? Colors.white24 : Colors.grey[850],
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.white12, width: 1),
                          ),
                          child: Stack(
                            children: [
                              if (occupied) ...[
                                Positioned(
                                  top: 2,
                                  right: 2,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: Colors.white54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.push_pin, size: 10, color: Colors.black87),
                                  ),
                                ),
                                Center(
                                  child: Text(
                                    pinned!.title,
                                    style: const TextStyle(fontSize: 9, color: Colors.white70),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ] else ...[
                                Center(
                                  child: Text('${index + 1}', style: const TextStyle(fontSize: 14, color: Colors.white38)),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
              ),
            ),

            // Action buttons — right-aligned below pin grid: fav · shuffle · play
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: Icon(
                      widget.isFavorite ? PhosphorIcons.fireFill : PhosphorIcons.fire,
                      color: Colors.white54,
                      size: 20,
                    ),
                    onPressed: widget.onToggleFavorite,
                    tooltip: widget.isFavorite ? 'Remove from favorites' : 'Add to favorites',
                  ),
                  IconButton(
                    icon: const Icon(Icons.shuffle_rounded, size: 20, color: Colors.white54),
                    onPressed: widget.onShuffleMore ?? () {},
                    tooltip: 'Featured Shuffle',
                  ),
                  IconButton(
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    onPressed: widget.onPlay,
                    tooltip: 'Play',
                    color: Colors.white54,
                  ),
                ],
              ),
            ),

          ],
        ),
      ),
    );
  }

  /// Fallback using TitlePattern — same as grid tiles use.
  Widget _patternFallback(String title) {
    return CustomPaint(
      painter: TitlePatternPainter(title, sunlightFactor: 0.0),
      size: Size.infinite,
    );
  }
}

/// Search content widget.
class _SwipeableTab extends StatelessWidget {
  final VoidCallback onLeft;   // swipe left → home
  final VoidCallback? onRight; // swipe right → next tab (null if no next)
  final Widget child;

  const _SwipeableTab({
    required this.onLeft,
    this.onRight,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity!.abs() > 200) {
          if (details.primaryVelocity! > 0) {
            // Swipe right → next tab
            onRight?.call();
          } else {
            // Swipe left → home
            onLeft();
          }
        }
      },
      child: child,
    );
  }
}


/// Sticky search bar delegate for library tab.
class _SearchBarDelegate extends SliverPersistentHeaderDelegate {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  const _SearchBarDelegate(
    this.controller,
    this.onChanged, {
    required this.focusNode,
  });

  @override
  double get minExtent => 64;
  @override
  double get maxExtent => 64;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Colors.grey[900],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'search songs or artists...',
            hintStyle: const TextStyle(color: Colors.white38),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey[800]!),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey[800]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.white38),
            ),
            prefixIcon: const Icon(Icons.search, color: Colors.white54),
            suffixIcon: controller.text.trim().isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20, color: Colors.white54),
                    onPressed: () {
                      final wasSearchActive = controller.text.trim().isNotEmpty;
                      controller.clear();
                      focusNode.unfocus();
                      if (wasSearchActive) {
                        onChanged('');
                      }
                    },
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onChanged: onChanged,
          onSubmitted: (value) {
            if (controller.text.trim().isEmpty) {
              controller.clear();
              focusNode.unfocus();
              onChanged('');
            }
          },
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SearchBarDelegate old) {
    return controller != old.controller;
  }
}

/// Sticky section header for library alphabet grouping.
class _SectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  _SectionHeaderDelegate(this.label);

  @override
  double get minExtent => 28;
  @override
  double get maxExtent => 28;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      color: Colors.black.withValues(
        alpha: 0.85 * (1 - (shrinkOffset / 28).clamp(0, 1)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.white54,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SectionHeaderDelegate oldDelegate) {
    return label != oldDelegate.label;
  }
}

/// Desktop folder setup screen — shown on first launch when no music folders are configured.
class _DesktopFolderSetup extends StatefulWidget {
  final Future<void> Function() onReady;

  const _DesktopFolderSetup({required this.onReady});

  @override
  State<_DesktopFolderSetup> createState() => _DesktopFolderSetupState();
}

class _DesktopFolderSetupState extends State<_DesktopFolderSetup> {
  final TextEditingController _pathController = TextEditingController();
  bool _scanning = false;

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _applyPath() async {
    final path = _pathController.text.trim();
    if (path.isEmpty) return;

    setState(() => _scanning = true);
    try {
      await AppSettings.saveMusicFolders([path]);
      if (mounted) {
        setState(() => _scanning = false);
        await widget.onReady();
      }
    } catch (e) {
      debugPrint('_DesktopFolderSetup error: $e');
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.music_note_rounded,
                    size: 80,
                    color: Colors.grey[600],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Welcome to dusktune',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Point dusktune at a folder containing your music files.\nSupported: MP3, FLAC, WAV, M4A, OGG, AAC, WMA, Opus.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _pathController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'e.g. C:\\Users\\You\\Music',
                      hintStyle: const TextStyle(color: Colors.white38),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.grey[800]!),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.grey[800]!),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Colors.white38),
                      ),
                    ),
                    onSubmitted: (_) => _applyPath(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _scanning ? null : _applyPath,
                      icon: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.folder_open),
                      label: Text(_scanning ? 'Scanning...' : 'Scan Folder'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
