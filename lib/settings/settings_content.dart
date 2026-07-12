/// Settings panel for DuskTune — music folder management, album art toggle,
/// bright album art, and data clearing.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import '../services/app_settings.dart';
import '../services/music_scanner.dart' as desktop_scanner;

/// Returns true if running on a desktop platform (Windows, macOS, Linux).
bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Callback type for operations that affect the app's global state.
typedef RescanCallback = Future<int> Function();
typedef ToggleCallback = void Function(bool);
typedef BrightAlbumArtToggle = Future<void> Function(bool);

/// Settings panel widget. Handles music folder management (desktop), album art
/// toggle, bright album art, and data clearing.
class SettingsContent extends StatefulWidget {
  final RescanCallback? onRescanLibrary;
  final ToggleCallback? onToggleAlbumArt;
  final BrightAlbumArtToggle? onToggleBrightAlbumArt;

  const SettingsContent({
    super.key,
    this.onRescanLibrary,
    this.onToggleAlbumArt,
    this.onToggleBrightAlbumArt,
  });

  @override
  State<SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<SettingsContent> {
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

    // SMB URLs are passed through directly — mpv plays them natively.
    // Don't run local accessibility checks on network paths.
    final isSmbUrl = trimmed.startsWith('smb://');
    final normalized = desktop_scanner.normalizePath(trimmed);

    if (!isSmbUrl && !await desktop_scanner.isFolderAccessible(normalized)) {
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
    final songCount = await widget.onRescanLibrary?.call() ?? 0;

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
    final songCount = await widget.onRescanLibrary?.call() ?? 0;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed: $removed — $songCount songs remaining'),
        ),
      );
    }
  }

  /// Pick a folder via native dialog (desktop only).
  Future<void> _pickFolder() async {
    try {
      String? path;
      if (Platform.isWindows) {
        // Use cscript.exe (console host) so stdout is captured reliably.
        final tmp = Directory.systemTemp.path.replaceAll(r'\', '/');
        final vbsPath = '$tmp/dusktune_pick_folder.vbs';
        const vbs = 'Set objFolder = CreateObject("Shell.Application").BrowseForFolder(0, "Select music folder", 0)\n'
            'If Not objFolder Is Nothing Then\n'
            '    WScript.Echo objFolder.Self.Path\n'
            'End If';
        File(vbsPath).writeAsStringSync(vbs);
        final result = await Process.run('cscript.exe', [vbsPath, '//nologo']);
        path = (result.stdout as String).trim();
        try { File(vbsPath).deleteSync(); } catch (_) {}
      } else if (Platform.isMacOS) {
        // Use AppleScript to show a native folder picker dialog.
        final result = await Process.run(
          'osascript', ['-e',
            'set chosenFolder to (choose folder with prompt "Select music folder") as alias\n'
            'return POSIX path of chosenFolder'],
        );
        path = (result.stdout as String).trim();
      } else if (Platform.isLinux) {
        // Try zenity first, fall back to kdialog.
        var result = await Process.run('zenity', ['--file-selection', '--directory']);
        if (result.exitCode == 0) {
          path = (result.stdout as String).trim();
        } else {
          result = await Process.run('kdialog', ['--getexistingdirectory']);
          if (result.exitCode == 0) {
            path = (result.stdout as String).trim();
          }
        }
      }

      if (path != null && path.isNotEmpty && mounted) {
        setState(() => _addPathController.text = path!);
      }
    } catch (e) {
      debugPrint('Folder picker error: $e');
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
                      final songCount = await widget.onRescanLibrary?.call() ?? 0;
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
                            widget.onToggleAlbumArt?.call(!enabled);
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

                  // --- Album art brightness toggle (Android only) ---
                  const SizedBox(height: 24),
                  FutureBuilder<bool>(
                    future: AppSettings.loadBrightAlbumArt(),
                    builder: (context, snapshot) {
                      final enabled = snapshot.data ?? false;
                      return InkWell(
                        onTap: () async {
                          final newState = !enabled;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(newState ? 'Album art brightness enabled' : 'Album art brightness disabled'),
                            ),
                          );
                          await widget.onToggleBrightAlbumArt?.call(newState);
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
                                Icons.brightness_high,
                                color: enabled ? Colors.blueGrey[300] : Colors.white54,
                                size: 22,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Album Art Brightness',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: enabled ? Colors.blueGrey[300] : Colors.white70,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Change default album art for light environments',
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

                  const SizedBox(height: 24),

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
                        if (_isDesktop) ...[
                          ElevatedButton.icon(
                            onPressed: _pickFolder,
                            icon: const Icon(Icons.folder_open, size: 18),
                            label: const Text('Browse'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
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
                        return MusicFolderTile(
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
                               widget.onToggleAlbumArt?.call(!enabled);
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

                    const SizedBox(height: 32),

                    // Info
                    Text(
                      'Supported formats: MP3, FLAC, WAV, M4A, OGG, AAC, WMA, Opus\n\n'
                      'SMB/network playback is supported — enter an SMB URL directly\n'
                      '(e.g. smb://server/share/music-folder) or a local folder path.\n'
                      'mpv plays SMB URLs natively, no manual mounting required.\n\n'
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

/// Tile widget for a single music folder entry in the settings panel.
class MusicFolderTile extends StatefulWidget {
  final int index;
  final String folder;
  final VoidCallback onRemove;

  const MusicFolderTile({
    required this.index,
    required this.folder,
    required this.onRemove,
  });

  @override
  State<MusicFolderTile> createState() => _MusicFolderTileState();
}

class _MusicFolderTileState extends State<MusicFolderTile> {
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
