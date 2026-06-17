/// DuskTune — a music player app.
library;

import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_theme.dart';
import 'models/song.dart';
import 'services/audio_player.dart';
import 'services/music_library.dart';
import 'services/music_scanner.dart' as desktop_scanner;
import 'services/app_settings.dart';
import 'widgets/tile_pattern.dart';
import 'dart:async';

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
  final separator = uri.contains(r'\\') ? r'\\' : '/';
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

class DuskTuneApp extends StatelessWidget {
  const DuskTuneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dusktune',
      debugShowCheckedModeBanner: false,
      theme: appDarkTheme,
      home: const AppRoot(),
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

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
    if (enabled) {
      // Set flag so next launch does a full artwork extraction
      await AppSettings.saveRescanFlag(true);
    }

    if (_isDesktop) {
      // Desktop: SystemNavigator.pop() doesn't work — show restart prompt instead
      // The snackbar is shown by the caller; we just return here
      return;
    } else {
      // Mobile: close app immediately
      SystemNavigator.pop();
    }
  }

  /// Rescan album artwork — sets flag. On mobile closes; on desktop shows restart prompt.
  Future<void> rescanAlbumArt() async {
    await AppSettings.saveRescanFlag(true);

    if (_isDesktop) {
      return; // Desktop: caller handles snackbar with restart message
    } else {
      SystemNavigator.pop();
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
    );
  }
}

/// Main app shell with top nav bar and bottom player.
class DuskTuneShell extends StatefulWidget {
  final List<Song> allSongs;
  final int tabIndex;
  final ValueChanged<int> onTabChanged;
  final bool isDesktop;

  const DuskTuneShell({
    super.key,
    required this.allSongs,
    required this.tabIndex,
    required this.onTabChanged,
    this.isDesktop = false,
  });

  @override
  State<DuskTuneShell> createState() => _DuskTuneShellState();
}

class _DuskTuneShellState extends State<DuskTuneShell> {
  String _appName = 'dusktune';
  Song? _currentSong;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
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

  // Pin mode: overlay for assigning current song to a tile.
  bool _pinMode = false;
  Song?
  _pinSourceSong; // Song to pin when entering pin mode (from tile long-press or grid button)

  // Mixes: list of saved mixes, each with id, name, and songIds.
  final List<Map<String, dynamic>> _mixes = [];
  final List<Song> _favorites = [];

  // Mix grid: temporary storage for a mix being displayed.
    List<Song>? _mixGridSongs;
    bool _showingMix = false;

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
  }

  /// Load favorites from persistent storage (async, non-blocking).
  Future<void> _loadFavoritesAsync() async {
    final favIds = await AppSettings.loadFavorites();
    if (!mounted) return;
    setState(() {
      _favorites.clear();
      for (final idStr in favIds) {
        final id = int.tryParse(idStr);
        if (id != null) {
          final match = widget.allSongs.firstWhere(
            (s) => s.id == id,
            orElse: () => Song(id: -1, title: '', uri: '', duration: 0),
          );
          if (match.uri.isNotEmpty) _favorites.add(match);
        }
      }
    });
  }

  Future<void> _loadSettings() async {
     final appName = await AppSettings.loadAppName();
     final playCounts = await AppSettings.loadPlayCounts();
     final showAlbumArt = await AppSettings.loadShowAlbumArt();
     if (mounted) {
       setState(() {
         _appName = appName;
         _playCounts.clear();
         _playCounts.addAll(playCounts);
         _showAlbumArt = showAlbumArt;
       });
     }
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
    await AppSettings.saveAppName(name);
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
    super.dispose();
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

    /// Shuffle the top 9 to random songs — does NOT start playback.
  void shuffleTopNine(BuildContext context) {
    final rng = math.Random();
    final shuffled = List<Song>.from(widget.allSongs)..shuffle(rng);
    setState(() {
      _shuffledTopNine = shuffled.take(9).toList();
      _showingMix = false;
      _mixGridSongs = null;
    });
  }

  /// Reset top picks back to most-played ranking.
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

    /// Cycle to the next page of most-played songs (batch of 9).
        void showTops() {
          setState(() {
            _topsPage = (_topsPage + 1) % ((widget.allSongs.length + 8) ~/ 9);
            // Store the topped batch — overrides pins, just like shuffle does.
            _toppedNine = _getTopsBatch(9);
            // Clear shuffle/mix so we go back to ranked tops display
            _shuffledTopNine = null;
            _showingMix = false;
            _mixGridSongs = null;
          });
        }

      /// Reset tops back to the beginning (page 0) and show that batch.
      void resetTops() {
        setState(() {
          _topsPage = 0;
          _toppedNine = _getTopsBatch(9);
          // Clear shuffle/mix so we go back to ranked tops display
          _shuffledTopNine = null;
          _showingMix = false;
          _mixGridSongs = null;
        });
      }

    // -- Pinned grid helpers --

  /// Load pinned grid from persistent storage.
  Future<void> _loadPinnedGrid(List<Song> allSongs) async {
    final raw = await AppSettings.loadPinnedGrid();
    if (mounted) {
      setState(() {
        for (final entry in raw.entries) {
          final songData = entry.value;
          final song = allSongs.firstWhere(
            (s) => s.id == songData['id'],
            orElse: () => Song(
              id: songData['id'] as int,
              title: songData['title'] as String? ?? 'Unknown',
              uri: songData['uri'] as String? ?? '',
              duration: songData['duration'] as int? ?? 0,
            ),
          );
          _pinnedGrid[entry.key] = song;
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
    };

    setState(() {
      _mixes.add(mixData);
    });
    await AppSettings.saveMixes(_mixes);
  }

  /// Load a mix into the grid display.
  void loadMixIntoGrid(Map<String, dynamic> mix) {
    final songIds = List<int>.from(mix['songIds'] as List);
    // Resolve song IDs to Song objects from current library
    final resolvedSongs = <Song>[];
    for (final id in songIds) {
      final found = widget.allSongs.where((s) => s.id == id).toList();
      if (found.isNotEmpty) {
        resolvedSongs.add(found.first);
      } else {
        // Song no longer in library — reconstruct from stored data
        // Try to find by ID in mixes or skip
      }
    }

    setState(() {
          _mixGridSongs = resolvedSongs;
          _showingMix = true;
          _shuffledTopNine = null; // clear shuffle when loading mix
        });
      }

      /// Delete a mix by ID.
  Future<void> deleteMix(int id) async {
    setState(() {
      _mixes.removeWhere((m) => (m['id'] as int) == id);
    });
    await AppSettings.saveMixes(_mixes);
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
                       _buildLibraryTab(),
                       _buildMixesTab(),
                       _buildFavoritesTab(),
                         const _SettingsContent(),
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

    // Wrap with keyboard shortcuts on desktop (KeyboardListener avoids focus issues)
    if (isDesktop) {
      content = KeyboardListener(
        focusNode: _keyboardFocusNode,
        onKeyEvent: _handleKeyEvent,
        child: content,
      );
    }

    return content;
  }

  /// Handle desktop keyboard shortcuts.
  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final key = event.logicalKey;

    // Disable all hotkeys when a search field has focus so typing works normally.
     if (_librarySearchFocusNode.hasFocus || _mixesSearchFocusNode.hasFocus || _favoritesSearchFocusNode.hasFocus)
       return;

    // Backtick (`) → shuffle grid
     if (key == LogicalKeyboardKey.backquote) {
       shuffleTopNine(context);
       return;
     }

    // Space → toggle play/pause
    if (key == LogicalKeyboardKey.space) {
      AudioPlayerService.togglePlayPause();
      setState(() => _isPlaying = !_isPlaying);
      return;
    }

    // Left Arrow → previous song
    if (key == LogicalKeyboardKey.arrowLeft) {
      _skipToPrevious();
      return;
    }

    // Right Arrow → next song
    if (key == LogicalKeyboardKey.arrowRight) {
      _skipToNext();
      return;
    }
    // 1-9 → play tile by position
    int? tileIndex;
    if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1)
      tileIndex = 0;
    if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2)
      tileIndex = 1;
    if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3)
      tileIndex = 2;
    if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4)
      tileIndex = 3;
    if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5)
      tileIndex = 4;
    if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6)
      tileIndex = 5;
    if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7)
      tileIndex = 6;
    if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8)
      tileIndex = 7;
    if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9)
      tileIndex = 8;

    if (tileIndex != null) {
       final gridSongs = getGridSongs();
       if (tileIndex < gridSongs.length) {
         setState(() => _selectedGridTile = tileIndex);
         playSong(gridSongs[tileIndex], queue: gridSongs);
       }
     }
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
          // App name — tap goes home, hold/right-click opens rename
          GestureDetector(
            onTap: () {
                          widget.onTabChanged(0);
                        },
            onLongPress: () {
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
                            setState(() => _appName = name);
                            _saveAppName(name);
                          }
                          Navigator.pop(ctx);
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  );
                },
              );
            },
            onSecondaryTap: () {
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
                            setState(() => _appName = name);
                            _saveAppName(name);
                          }
                          Navigator.pop(ctx);
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  );
                },
              );
            },
            child: Text(
              _appName,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.white70,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Tab buttons (icons only)
             _tabIcon(Icons.queue_music, 1),
             const SizedBox(width: 4),
             _tabIcon(Icons.audiotrack, 2),
             const SizedBox(width: 4),
             _tabIcon(Icons.favorite, 3),
             // Settings tab
                  const SizedBox(width: 4),
                  _tabIcon(Icons.tune, 4),
             ],
             ),
             );
             }

             Widget _tabIcon(IconData icon, int index) {
    final isActive = widget.tabIndex == index;
    return IconButton(
      onPressed: () => widget.onTabChanged(index),
      icon: Icon(
        icon,
        size: 20,
        color: isActive ? Colors.white : Colors.white54,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      constraints: const BoxConstraints(),
    );
  }

  /// Home tab content.

  /// Home tab content.
  Widget _buildHomeTab() {
    final gridSongs = getGridSongs();

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            // Spacing above the grid (replaces former top picks header)
            const SliverToBoxAdapter(child: SizedBox(height: 16)),

            // Top 9 grid
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isDesktop =
                        Platform.isWindows ||
                        Platform.isMacOS ||
                        Platform.isLinux;
                    // On desktop, cap tile height so grid doesn't dominate the viewport
                    final maxTileHeight = isDesktop ? 180.0 : double.infinity;
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
                          onTap: () {
                            setState(() => _selectedGridTile = index);
                            playSong(song, queue: gridSongs);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ),

            // Recent songs section header
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'recent songs',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                        letterSpacing: 0.5,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                        // "Mix" button — tap prompts to name/save current grid as a mix; long-press/right-click opens mixes tab
                         GestureDetector(
                           onSecondaryTap: () {
                             widget.onTabChanged(2);
                           },
                           onLongPress: () {
                             widget.onTabChanged(2);
                           },
                           child: TextButton.icon(
                             onPressed: () {
                               promptSaveMix(context);
                             },
                            icon: const Icon(
                              Icons.audiotrack,
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
                        // "The Grid" button — tap restores pinned grid, long-press/right-click enters pin mode
                        GestureDetector(
                          onSecondaryTap: () {
                            if (_currentSong != null) {
                              _pinSourceSong = _currentSong;
                              setState(() => _pinMode = true);
                            }
                          },
                          onLongPress: () {
                            if (_currentSong != null) {
                              _pinSourceSong = _currentSong;
                              setState(() => _pinMode = true);
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
                              Icons.grid_view,
                              size: 16,
                              color: Colors.white54,
                            ),
                            label: const Text(
                              'the grid',
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
                        // Shuffle button — original behavior preserved
                                                TextButton.icon(
                                                  onPressed: () {
                                                    shuffleTopNine(context);
                                                  },
                          icon: const Icon(
                            Icons.shuffle,
                            size: 16,
                            color: Colors.white54,
                          ),
                          label: const Text(
                            'shuffle',
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
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Recent songs list (ordered by last played)
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final recentSongs = getRecentSongs();
                if (index >= recentSongs.length) return const SizedBox.shrink();
                final song = recentSongs[index];
                return _buildSongListItem(song);
              }, childCount: widget.allSongs.length),
            ),

            // Bottom padding for player
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      ],
    );
  }

  /// Pin mode overlay — semi-transparent dialog for assigning current song to a tile.
  Widget _buildPinModeOverlay(List<Song> gridSongs) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _pinMode = false),
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
                    const Text(
                      'Pin current song to a tile',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    // Show the song that will be pinned (from tile or current song)
                    if (_pinSourceSong != null || _currentSong != null)
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
                    // 3x3 grid for tile selection
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
                      itemCount: 9,
                      itemBuilder: (context, index) {
                        final hasPinned = _pinnedGrid.containsKey(index);
                        final Song? pinnedSong = hasPinned
                            ? _pinnedGrid[index]
                            : null;
                        return GestureDetector(
                          onTap: () async {
                            if (_pinSourceSong != null) {
                              await pinSongToTile(_pinSourceSong!, index);
                            }
                            setState(() => _pinMode = false);
                            _pinSourceSong = null; // clear after use
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: hasPinned
                                  ? Colors.white24
                                  : Colors.grey[850],
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: hasPinned
                                    ? Colors.white70
                                    : Colors.white12,
                                width: 1,
                              ),
                            ),
                            child: Stack(
                              children: [
                                if (hasPinned) ...[
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
                                  // Show pinned song title centered
                                  Center(
                                    child: Text(
                                      pinnedSong?.title ?? '',
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
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    // Pin to Favorites button (only when NOT in favorites tab)
                      if (widget.tabIndex != 3)
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
                                Icons.favorite_border,
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
                      // Remove from Favorites button (only when in favorites tab)
                      if (widget.tabIndex == 3 && _pinSourceSong != null)
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
                                Icons.favorite_border,
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
                      onPressed: () => setState(() => _pinMode = false),
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
  }) {
    final context = _tileContext(song);

    return GestureDetector(
      onTap: onTap,
      onLongPress: () {
        _pinSourceSong = song;
        setState(() => _pinMode = true);
      },
      onSecondaryTap: () {
        _pinSourceSong = song;
        setState(() => _pinMode = true);
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
                  child: _showAlbumArt
                      ? AlbumArtTile(title: song.title, artworkBytes: song.artworkBytes)
                      : TitlePattern(title: song.title),
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
      _favorites.map((s) => s.id.toString()).toList(),
    );
  }

  /// Remove song from favorites and persist.
  Future<void> _removeFromFavorites(int songId) async {
    setState(() => _favorites.removeWhere((s) => s.id == songId));
    await AppSettings.saveFavorites(
      _favorites.map((s) => s.id.toString()).toList(),
    );
  }

   /// Shared ListTile for song list items — used by both main lists and favorites.
     Widget _buildSongTile(Song song, {VoidCallback? onTap, Widget? trailingWidget}) {
       return GestureDetector(
         onLongPress: () {
           setState(() {
             _pinSourceSong = song;
             _pinMode = true;
           });
         },
         onSecondaryTap: () {
           if (_isDesktop) {
             setState(() {
               _pinSourceSong = song;
               _pinMode = true;
             });
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
                        setState(() {
                          _pinSourceSong = song;
                          _pinMode = true;
                        });
                      },
                      onSecondaryTap: () {
                        if (_isDesktop) {
                          setState(() {
                            _pinSourceSong = song;
                            _pinMode = true;
                          });
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
            top: 0,
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
                        setState(() {
                          _pinSourceSong = song;
                          _pinMode = true;
                        });
                      },
                      onSecondaryTap: () {
                        if (_isDesktop) {
                          setState(() {
                            _pinSourceSong = song;
                            _pinMode = true;
                          });
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
                             Icons.favorite,
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

     return ListTile(
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
     );
   }

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
                // Song info (expandable)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _currentSong!.artist ?? 'Unknown Artist',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${fmt(_position)} / ${fmt(_duration)}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

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

                const SizedBox(width: 8),

                // Shuffle All toggle button
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
}

/// Search content widget.
class _SearchContent extends StatefulWidget {
  const _SearchContent();

  @override
  State<_SearchContent> createState() => _SearchContentState();
}

class _SearchContentState extends State<_SearchContent> {
  final TextEditingController _controller = TextEditingController();
  List<Song> _results = [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      _debounce?.cancel();
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _searching = true);
      final lib = MusicLibrary();
      await lib.init();
      final results = await lib.search(q);
      if (mounted) {
        setState(() {
          _results = results;
          _searching = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // Search field
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              autofocus: true,
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
                  borderSide: BorderSide(color: Colors.white38),
                ),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: _doSearch,
            ),
          ),
        ),

        if (_searching)
          const SliverFillRemaining(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_results.isEmpty && _controller.text.isNotEmpty)
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
              final song = _results[index];
              return ListTile(
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
                trailing:
                    Platform.isWindows || Platform.isMacOS || Platform.isLinux
                    ? null
                    : Text(
                        song.formattedDuration,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                onTap: () {
                  // Access parent state to play the song within search results context
                  final shell = context
                      .findAncestorStateOfType<_DuskTuneShellState>();
                  shell?.playSong(song, queue: _results);
                },
              );
            }, childCount: _results.length),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
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
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onChanged: onChanged,
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

/// Settings content — music folder management (desktop only).
class _SettingsContent extends StatefulWidget {
  const _SettingsContent();

  @override
  State<_SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<_SettingsContent> {
  List<String> _folders = [];
  bool _loading = true;
  bool _scanning = false; // true while rescanning after add/remove
  final TextEditingController _addPathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      _loadFolders();
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _addPathController.dispose();
    super.dispose();
  }

  Future<void> _loadFolders() async {
    final folders = await AppSettings.loadMusicFolders();
    if (mounted) {
      setState(() {
        _folders = folders;
        _loading = false;
      });
    }
  }

  Future<void> _addFolder(String? path) async {
    final trimmed = (path ?? _addPathController.text).trim();
    if (trimmed.isEmpty) return;

    final normalized = desktop_scanner.normalizePath(trimmed);

    if (!await desktop_scanner.isFolderAccessible(normalized)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot access folder: $normalized'),
            backgroundColor: Colors.orange[900],
          ),
        );
      }
      return;
    }

    final updated = List<String>.from(_folders)..add(normalized);
    await AppSettings.saveMusicFolders(updated);
    setState(() {
      _folders = updated;
      _addPathController.clear();
      _scanning = true;
    });

    if (!mounted) return;
    final shell = context.findAncestorStateOfType<_AppRootState>();
    final songCount = await shell?.rescanLibrary() ?? 0;

    if (mounted) {
      setState(() => _scanning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added folder — found $songCount songs')),
      );
    }
  }

  Future<void> _removeFolder(int index) async {
    final removed = _folders.removeAt(index);
    await AppSettings.saveMusicFolders(_folders);
    setState(() {});

    if (!mounted) return;
    final shell = context.findAncestorStateOfType<_AppRootState>();
    final songCount = await shell?.rescanLibrary() ?? 0;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed: $removed — $songCount songs remaining'),
        ),
      );
    }
  }

  Future<void> _clearAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Data', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will permanently delete all favorites, mixes, pinned grid songs, play counts, and app name. This cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await AppSettings.clearAllData();

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All data cleared')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = _isDesktop;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Mobile settings view
    if (!isDesktop) {
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Settings',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[200],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Manage your app data.',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                  ),

                  // --- Rescan music library (Android) ---
                  const SizedBox(height: 24),
                  InkWell(
                    onTap: () async {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Rescanning music library...')),
                        );
                      }
                      final shell = context.findAncestorStateOfType<_AppRootState>();
                      final songCount = await shell?.rescanLibrary() ?? 0;
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Found $songCount songs')),
                        );
                      }
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey[700]!),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.refresh, color: Colors.grey[300], size: 22),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Rescan Music Library',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.grey[300],
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Re-query MediaStore for new or missing songs',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: Colors.grey[500], size: 20),
                        ],
                      ),
                    ),
                  ),

                  // --- Album art toggle (mobile) ---
                  const SizedBox(height: 24),
                  FutureBuilder<bool>(
                    future: AppSettings.loadShowAlbumArt(),
                    builder: (context, snapshot) {
                      final enabled = snapshot.data ?? false;
                      return InkWell(
                        onTap: () async {
                          if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    _isDesktop
                                        ? (enabled ? 'Album art disabled — please restart the app' : 'Album art enabled — please restart the app. First run may take a moment.')
                                        : (enabled ? 'Album art disabled...' : 'Enabling album art...'),
                                  ),
                                  duration: Duration(seconds: _isDesktop ? 5 : 2),
                                ),
                              );
                            }
                            if (!_isDesktop) {
                              await Future.delayed(const Duration(milliseconds: 500));
                            }
                            final shell = context.findAncestorStateOfType<_AppRootState>();
                            shell?.toggleAlbumArt(!enabled);
                          },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            color: enabled
                                ? Colors.blueGrey[900]?.withValues(alpha: 0.3)
                                : Colors.grey[900],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: enabled ? Colors.blueGrey[700]! : Colors.grey[800]!,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.album,
                                color: enabled ? Colors.blueGrey[300] : Colors.white54,
                                size: 22,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Show Album Art',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: enabled ? Colors.blueGrey[300] : Colors.white70,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      enabled
                                          ? 'Enabled — tap to disable'
                                          : 'Disabled — first run may take a moment',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey[500],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                color: enabled ? Colors.blueGrey[400] : Colors.white38,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  // Note about restart
                  Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 24),
                    child: Text(
                      'App will close after toggling — reopen to apply. First enable extracts artwork from your music library.',
                      style: TextStyle(fontSize: 10, color: Colors.grey[600], height: 1.5),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24),
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await AppSettings.clearArtworkCache();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Artwork cache cleared')),
                          );
                        }
                      },
                      icon: const Icon(Icons.delete_sweep, size: 18),
                      label: const Text(
                        'Clear Artwork Cache',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),

                  // Rescan album art button (only visible when enabled)
                  FutureBuilder<bool>(
                    future: AppSettings.loadShowAlbumArt(),
                    builder: (context, snapshot) {
                      final enabled = snapshot.data ?? false;
                      if (!enabled) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24),
                        child: OutlinedButton.icon(
                          onPressed: () {
                               final shell = context.findAncestorStateOfType<_AppRootState>();
                               if (_isDesktop) {
                                 if (context.mounted) {
                                   ScaffoldMessenger.of(context).showSnackBar(
                                     const SnackBar(content: Text('Rescanning artwork — please restart the app')),
                                   );
                                 }
                               }
                               shell?.rescanAlbumArt();
                             },
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text(
                            'Rescan Album Art',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      );
                    },
                  ),

                  // Clear all data button
                  InkWell(
                    onTap: _clearAllData,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.red[900]?.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red[800]!),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.delete_forever, color: Colors.red[400], size: 22),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Clear All Data',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.red[300],
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Delete favorites, mixes, pins, play counts, and app name',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: Colors.red[400], size: 20),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Info section
                  Text(
                    'Persistent Storage',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[400],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your data is stored in /Documents/dusktune/ and survives app reinstalls. '
                    'Only clearing data here or deleting the folder manually will remove it.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      );
    }

    // Desktop settings view (music folders)
    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Music Folders',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[200],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'dusktune will scan these folders for audio files.',
                      style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                    ),
                    const SizedBox(height: 16),

                    // Add folder row
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _addPathController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Enter folder path or smb:// URL',
                              hintStyle: const TextStyle(color: Colors.white38),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey[800]!,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: Colors.grey[800]!,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                  color: Colors.white38,
                                ),
                              ),
                            ),
                            onSubmitted: (_) => _addFolder(null),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () => _addFolder(null),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add'),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Folder list with accessibility check on load
                    if (_folders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: Text(
                            'No music folders configured.',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                        ),
                      )
                    else
                      ..._folders.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final folder = entry.value;
                        return _MusicFolderTile(
                          index: idx,
                          folder: folder,
                          onRemove: () => _removeFolder(idx),
                        );
                      }),

                    const SizedBox(height: 32),

                    // --- Album art settings (desktop) ---
                    Divider(color: Colors.grey[800], height: 24),
                    Text(
                      'Album Art',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[300],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Display album artwork in grid tiles and song lists.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                    const SizedBox(height: 8),

                    FutureBuilder<bool>(
                      future: AppSettings.loadShowAlbumArt(),
                      builder: (context, snapshot) {
                        final enabled = snapshot.data ?? false;
                        return InkWell(
                           onTap: () async {
                             if (context.mounted) {
                                 ScaffoldMessenger.of(context).showSnackBar(
                                   SnackBar(
                                        content: Text(
                                          _isDesktop
                                              ? (enabled ? 'Album art disabled — please restart the app' : 'Album art enabled — please restart the app. First run may take a moment.')
                                              : (enabled ? 'Album art disabled...' : 'Enabling album art...'),
                                        ),
                                        duration: Duration(seconds: _isDesktop ? 5 : 2),
                                      ),
                                 );
                               }
                               if (!_isDesktop) {
                                 await Future.delayed(const Duration(milliseconds: 500));
                               }
                               final shell = context.findAncestorStateOfType<_AppRootState>();
                               shell?.toggleAlbumArt(!enabled);
                             },
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              color: enabled
                                  ? Colors.blueGrey[900]?.withValues(alpha: 0.3)
                                  : Colors.grey[900],
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: enabled ? Colors.blueGrey[700]! : Colors.grey[800]!,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.album,
                                  color: enabled ? Colors.blueGrey[300] : Colors.white54,
                                  size: 22,
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Show Album Art',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: enabled ? Colors.blueGrey[300] : Colors.white70,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        enabled
                                            ? 'Enabled — tap to disable'
                                            : 'Disabled — first run may take a moment',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey[500],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  color: enabled ? Colors.blueGrey[400] : Colors.white38,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                      ),

                      // Note about restart (desktop)
                      Padding(
                       padding: const EdgeInsets.only(left: 16, bottom: 8),
                       child: Text(
                         'App will close after toggling — reopen to apply. First enable extracts artwork from your music library.',
                         style: TextStyle(fontSize: 10, color: Colors.grey[600], height: 1.5),
                       ),
                      ),

                      Padding(
                       padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                       child: OutlinedButton.icon(
                         onPressed: () async {
                           await AppSettings.clearArtworkCache();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Artwork cache cleared')),
                            );
                          }
                        },
                        icon: const Icon(Icons.delete_sweep, size: 18),
                        label: const Text(
                          'Clear Artwork Cache',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                      child: OutlinedButton.icon(
                        onPressed: () {
                             final shell = context.findAncestorStateOfType<_AppRootState>();
                             if (_isDesktop) {
                               if (context.mounted) {
                                 ScaffoldMessenger.of(context).showSnackBar(
                                   const SnackBar(content: Text('Rescanning artwork — please restart the app')),
                                 );
                               }
                             }
                             shell?.rescanAlbumArt();
                           },
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text(
                          'Rescan Album Art',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Info
                    Text(
                      'Supported formats: MP3, FLAC, WAV, M4A, OGG, AAC, WMA, Opus\n\n'
                      'Network/SMB folders are supported — enter the mount path (e.g. /Volumes/Share/Music)\n'
                      'or SMB URL (smb://host/share/path). Folders must be mounted and accessible.\n\n'
                      'Changes take effect immediately — your library is re-scanned when you add or remove a folder.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),

        // Scanning overlay
        if (_scanning)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      'Scanning music files...',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
class _MusicFolderTile extends StatefulWidget {
  final int index;
  final String folder;
  final VoidCallback onRemove;

  const _MusicFolderTile({
    required this.index,
    required this.folder,
    required this.onRemove,
  });

  @override
  State<_MusicFolderTile> createState() => _MusicFolderTileState();
}

class _MusicFolderTileState extends State<_MusicFolderTile> {
  bool? _accessible; // null = checking, true/false = result

  @override
  void initState() {
    super.initState();
    _checkAccess();
  }

  Future<void> _checkAccess() async {
    setState(() => _accessible = null);
    final accessible = await desktop_scanner.isFolderAccessible(widget.folder);
    if (mounted) {
      setState(() => _accessible = accessible);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _accessible == false
              ? Colors.red[900]?.withValues(alpha: 0.3)
              : Colors.grey[900],
          borderRadius: BorderRadius.circular(6),
          border: _accessible == false
              ? Border.all(color: Colors.orange[800]!)
              : null,
        ),
        child: Row(
          children: [
            Icon(
              Icons.folder,
              size: 20,
              color: _accessible == false ? Colors.orange : Colors.white54,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.folder,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_accessible == null)
                    const Text(
                      'Checking...',
                      style: TextStyle(fontSize: 10, color: Colors.white38),
                    )
                  else if (!_accessible!)
                    Text(
                      '⚠ Not accessible — make sure the volume is mounted',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.orange,
                      ),
                    ),
                ],
              ),
            ),
            // Re-check button
            IconButton(
              icon: Icon(
                Icons.refresh,
                size: 18,
                color: _accessible == null ? Colors.white38 : Colors.white54,
              ),
              onPressed: _checkAccess,
              tooltip: 'Re-check',
            ),
            // Remove button
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                size: 20,
                color: Colors.white54,
              ),
              onPressed: widget.onRemove,
              tooltip: 'Remove',
            ),
          ],
        ),
      ),
    );
  }
}
