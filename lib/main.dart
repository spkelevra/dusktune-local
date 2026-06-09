/// DuskTune — a music player app.
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'models/song.dart';
import 'services/audio_player.dart';
import 'services/music_library.dart';
import 'widgets/tile_pattern.dart';

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
  int _tabIndex = 0; // 0=home, 1=search, 2=library

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

  void setTab(int index) => setState(() => _tabIndex = index);

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

    return DuskTuneShell(
      allSongs: _songs,
      tabIndex: _tabIndex,
      onTabChanged: setTab,
    );
  }
}

/// Main app shell with top nav bar and bottom player.
class DuskTuneShell extends StatefulWidget {
  final List<Song> allSongs;
  final int tabIndex;
  final ValueChanged<int> onTabChanged;

  const DuskTuneShell({
    super.key,
    required this.allSongs,
    required this.tabIndex,
    required this.onTabChanged,
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

  @override
  void initState() {
    super.initState();
    _listenToPlayback();
  }

  void _listenToPlayback() {
    AudioPlayerService.playbackState.listen((state) {
      if (mounted) setState(() => _isPlaying = state?.playing ?? false);
    });
    AudioPlayerService.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    AudioPlayerService.durationStream.listen((dur) {
      if (mounted) setState(() => _duration = dur ?? Duration.zero);
    });
  }

  void playSong(Song song) async {
    // Track play count and recent order
    setState(() {
      _playCounts[song.id] = (_playCounts[song.id] ?? 0) + 1;
      // Move to front of recently played (remove if already there first)
      _recentlyPlayed.removeWhere((s) => s.id == song.id);
      _recentlyPlayed.insert(0, song);
      _currentSong = song;
    });
    await AudioPlayerService.playSong(song);
  }

  /// Get top N songs by play count, sorted descending.
  List<Song> getTopSongs(int n) {
    // If we have a shuffled set, use it instead of ranked list
    if (_shuffledTopNine != null) return _shuffledTopNine!.take(n).toList();

    if (_playCounts.isEmpty) return widget.allSongs.take(n).toList();
    final sorted = widget.allSongs.where((s) => _playCounts.containsKey(s.id)).toList()
      ..sort((a, b) => (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0));
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

  /// Shuffle the top 9 to random songs — does NOT start playback.
  void shuffleTopNine(BuildContext context) {
    final rng = math.Random();
    final shuffled = List<Song>.from(widget.allSongs)..shuffle(rng);
    setState(() {
      _shuffledTopNine = shuffled.take(9).toList();
    });
  }

  /// Reset top picks back to most-played ranking.
  void resetTopPicks() {
    setState(() {
      _shuffledTopNine = null;
    });
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

  /// Override skipToNext to pick random song when shuffle is on, or next in recent list.
  void _skipToNext() {
    if (_shuffleAll) {
      final rng = math.Random();
      final randomSong = widget.allSongs[rng.nextInt(widget.allSongs.length)];
      playSong(randomSong);
    } else if (_currentSong != null && widget.allSongs.isNotEmpty) {
      // Find current song index in the library and skip to next
      final idx = widget.allSongs.indexWhere((s) => s.id == _currentSong!.id);
      final nextIdx = (idx + 1) % widget.allSongs.length;
      playSong(widget.allSongs[nextIdx]);
    }
  }

  /// Override skipToPrevious to pick random song when shuffle is on, or previous in recent list.
  void _skipToPrevious() {
    if (_shuffleAll) {
      final rng = math.Random();
      final randomSong = widget.allSongs[rng.nextInt(widget.allSongs.length)];
      playSong(randomSong);
    } else if (_currentSong != null && widget.allSongs.isNotEmpty) {
      // Find current song index in the library and skip to previous
      final idx = widget.allSongs.indexWhere((s) => s.id == _currentSong!.id);
      final prevIdx = (idx - 1 + widget.allSongs.length) % widget.allSongs.length;
      playSong(widget.allSongs[prevIdx]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top nav bar
            _buildTopNav(),

            // Content area (scrollable, fills remaining space above player)
            Expanded(
              child: IndexedStack(
                index: widget.tabIndex,
                children: [
                  _buildHomeTab(),
                  _buildSearchTab(),
                  _buildLibraryTab(),
                ],
              ),
            ),

            // Bottom player (always visible when a song is playing)
            if (_currentSong != null) _buildBottomPlayer(),
          ],
        ),
      ),
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
          // Editable app name
          GestureDetector(
            onTap: () {
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
                          if (name.isNotEmpty) setState(() => _appName = name);
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
          _tabIcon(Icons.home_outlined, Icons.home, 0),
          const SizedBox(width: 4),
          _tabIcon(Icons.search_outlined, Icons.search, 1),
          const SizedBox(width: 4),
          _tabIcon(Icons.library_music_outlined, Icons.library_music, 2),
        ],
      ),
    );
  }

  Widget _tabIcon(IconData outlinedIcon, IconData filledIcon, int index) {
    final isActive = widget.tabIndex == index;
    return IconButton(
      onPressed: () => widget.onTabChanged(index),
      icon: Icon(
        isActive ? filledIcon : outlinedIcon,
        size: 20,
        color: isActive ? Colors.white : Colors.white54,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      constraints: const BoxConstraints(),
    );
  }

  /// Home tab content.
  Widget _buildHomeTab() {
    final topSongs = getTopSongs(9);

    return CustomScrollView(
      slivers: [
        // Top 9 section with shuffle button
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'top picks',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                    letterSpacing: 0.5,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => shuffleTopNine(context),
                  icon: const Icon(Icons.shuffle, size: 16, color: Colors.white54),
                  label: const Text(
                    'shuffle',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Top 9 grid
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.9,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: topSongs.length,
              itemBuilder: (context, index) {
                final song = topSongs[index];
                return _buildTopTile(song);
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
                TextButton(
                  onPressed: () => widget.onTabChanged(2),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'see all',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Recent songs list (ordered by last played)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final recentSongs = getRecentSongs();
              if (index >= recentSongs.length) return const SizedBox.shrink();
              final song = recentSongs[index];
              return _buildSongListItem(song);
            },
            childCount: widget.allSongs.length,
          ),
        ),

        // Bottom padding for player
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  /// Top tile with generated pattern.
  Widget _buildTopTile(Song song) {
    return GestureDetector(
      onTap: () => playSong(song),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            flex: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: 1.0,
                child: TitlePattern(title: song.title),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            flex: 1,
            child: Text(
              song.title,
              style: const TextStyle(
                fontSize: 10,
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

  /// Song list item (grey square + info).
  Widget _buildSongListItem(Song song) {
    return ListTile(
      leading: Container(
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
        song.artist ?? 'Unknown Artist',
        style: const TextStyle(color: Colors.white54, fontSize: 11),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        song.formattedDuration,
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      onTap: () => playSong(song),
    );
  }

  /// Search tab content.
  Widget _buildSearchTab() {
    return const _SearchContent();
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
      final firstChar = song.title.isNotEmpty ? song.title[0].toUpperCase() : '#';
      if (!RegExp(r'^[A-Z0-9]$').hasMatch(firstChar)) {
        groups.putIfAbsent('#', () => []).add(song);
      } else {
        groups.putIfAbsent(firstChar, () => []).add(song);
      }
    }
    _groupedSongs = groups;

    // Sorted section keys: # first, then numbers, then letters
    final allKeys = groups.keys.toList()..sort((a, b) {
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
      Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 200));
    }
  }

  Widget _buildLibraryTab() {
    _buildGroupedSongs();

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
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
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final song = songs[index];
                        return _buildSongListItem(song);
                      },
                      childCount: songs.length,
                    ),
                  ),
                ],
              );
            }),
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),

        // Alphabet index bar on the right edge
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
    final activeLabels = allLabels.where((l) => _groupedSongs.containsKey(l)).toList();

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
          // Progress bar (thin)
          GestureDetector(
            onHorizontalDragUpdate: (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null) {
                final x = details.globalPosition.dx - box.localToGlobal(Offset.zero).dx;
                final ratio = x.clamp(0.0, box.size.width) / box.size.width;
                AudioPlayerService.seek(Duration(
                  milliseconds: (_duration.inMilliseconds * ratio).round(),
                ));
              }
            },
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Colors.transparent,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white70),
              minHeight: 3,
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
                  icon: const Icon(Icons.skip_previous, size: 24, color: Colors.white70),
                  onPressed: _skipToPrevious,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),

                const SizedBox(width: 8),

                // Play/Pause
                IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                    size: 36,
                    color: Colors.white,
                  ),
                  onPressed: AudioPlayerService.togglePlayPause,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),

                const SizedBox(width: 8),

                // Skip next
                IconButton(
                  icon: const Icon(Icons.skip_next, size: 24, color: Colors.white70),
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
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
              child: Text('no results found',
                style: TextStyle(color: Colors.white54)),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
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
                    child: const Icon(Icons.music_note, size: 18, color: Colors.white24),
                  ),
                  title: Text(
                    song.title,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    song.artist ?? 'Unknown Artist',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    song.formattedDuration,
                    style: const TextStyle(fontSize: 11, color: Colors.white38),
                  ),
                  onTap: () {
                    // Access parent state to play the song
                    final shell = context.findAncestorStateOfType<_DuskTuneShellState>();
                    shell?.playSong(song);
                  },
                );
              },
              childCount: _results.length,
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
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
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      color: Colors.black.withValues(alpha: 0.85 * (1 - (shrinkOffset / 28).clamp(0, 1))),
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
