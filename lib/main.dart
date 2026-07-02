import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'models/song.dart';
import 'services/catalog_repository.dart';
import 'services/phira_export_service.dart';
import 'services/resource_update_service.dart';
import 'theme/my_theme.dart';

void main() {
  runApp(const PhigrosLibraryApp());
}

class PhigrosLibraryApp extends StatelessWidget {
  const PhigrosLibraryApp({super.key, this.repository});

  final CatalogRepository? repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phigros Library',
      debugShowCheckedModeBanner: false,
      theme: MyTheme.dark(),
      home: LibraryHome(repository: repository),
    );
  }
}

class LibraryHome extends StatefulWidget {
  const LibraryHome({super.key, this.repository});

  final CatalogRepository? repository;

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  late final _repository = widget.repository ?? CatalogRepository();
  final _player = AudioPlayer();
  late final _exporter = PhiraExportService(_repository);
  late final _updater = ResourceUpdateService(
    libraryRoot: _repository.libraryRoot,
  );
  late Future<SongCatalog> _catalog;
  Song? _selected;
  String _filter = '';
  PlayerState _playerState = PlayerState.stopped;
  bool _updating = false;
  ResourceUpdateEvent? _updateEvent;

  @override
  void initState() {
    super.initState();
    _catalog = _repository.load();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _playerState = state);
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SongCatalog>(
      future: _catalog,
      builder: (context, snapshot) {
        final catalog = snapshot.data;
        final songs = _filteredSongs(catalog?.songs ?? const []);
        final selected = _selected ?? (songs.isEmpty ? null : songs.first);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Phigros Library'),
            actions: [
              IconButton(
                tooltip: 'Check latest APK',
                onPressed: _updating ? null : () => _showUpdateSheet(catalog),
                icon: const Icon(Icons.sync),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    catalog == null
                        ? 'Loading'
                        : '${catalog.songs.length} songs',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  child: _updating
                      ? _UpdateStatusBanner(event: _updateEvent)
                      : const SizedBox.shrink(),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (snapshot.hasError) {
                        return _ErrorState(message: snapshot.error.toString());
                      }

                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      if (catalog == null || catalog.songs.isEmpty) {
                        return const _EmptyState();
                      }

                      final list = SongListPane(
                        songs: songs,
                        selected: selected,
                        onSelect: (song) => setState(() => _selected = song),
                        onFilterChanged: (value) =>
                            setState(() => _filter = value),
                      );
                      final details = AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: SongDetailsPane(
                          key: ValueKey(selected?.id),
                          song: selected,
                          repository: _repository,
                          playerState: _playerState,
                          onTogglePlay: selected == null
                              ? null
                              : () => _togglePlay(selected),
                          onExportPhira: selected == null
                              ? null
                              : () => _exportPhiraPackage(selected),
                        ),
                      );

                      if (constraints.maxWidth < 860) {
                        return Column(
                          children: [
                            SizedBox(height: 360, child: list),
                            const Divider(height: 1),
                            Expanded(child: details),
                          ],
                        );
                      }

                      return Row(
                        children: [
                          SizedBox(width: 390, child: list),
                          const VerticalDivider(width: 1),
                          Expanded(child: details),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Song> _filteredSongs(List<Song> songs) {
    final keyword = _filter.trim().toLowerCase();
    if (keyword.isEmpty) {
      return songs;
    }

    return songs.where((song) {
      return song.title.toLowerCase().contains(keyword) ||
          song.id.toLowerCase().contains(keyword) ||
          song.composer.toLowerCase().contains(keyword);
    }).toList();
  }

  Future<void> _togglePlay(Song song) async {
    if (_playerState == PlayerState.playing) {
      await _player.pause();
      return;
    }

    final music = _repository.resolveFile(song.musicPath);
    if (music == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Music file is not available.')),
        );
      }
      return;
    }

    await _player.play(DeviceFileSource(music.path));
  }

  Future<void> _exportPhiraPackage(Song song) async {
    try {
      final result = _exporter.exportSong(song);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Exported ${result.exported} package(s), skipped ${result.skipped}.',
            ),
          ),
        );
      }
    } on Object catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _showUpdateSheet(SongCatalog? catalog) async {
    setState(() => _updating = true);
    ApkRelease? release;
    Object? error;
    try {
      release = await _updater.resolveLatest();
    } on Object catch (caught) {
      error = caught;
    } finally {
      if (mounted) {
        setState(() => _updating = false);
      }
    }

    if (mounted) {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) {
          return _UpdateSheet(
            catalog: catalog,
            release: release,
            error: error,
            canUpdate: _updater.canUpdate,
            updating: _updating,
            onCatalogOnlyUpdate: () => _runUpdate(catalogOnly: true),
            onFullUpdate: () => _runUpdate(catalogOnly: false),
          );
        },
      );
    }
  }

  Future<void> _runUpdate({required bool catalogOnly}) async {
    Navigator.of(context).pop();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _updating = true;
      _updateEvent = const ResourceUpdateEvent(
        stage: ResourceUpdateStage.resolving,
        message: 'Preparing update',
      );
    });
    try {
      var success = false;
      var output = '';
      await for (final event in _updater.updateLibraryStream(
        catalogOnly: catalogOnly,
      )) {
        if (mounted) {
          setState(() => _updateEvent = event);
        }
        output = event.output;
        success = event.stage == ResourceUpdateStage.complete;
        if (event.stage == ResourceUpdateStage.failed) {
          break;
        }
      }

      if (!success) {
        messenger
            .showSnackBar(SnackBar(content: Text('Update failed: $output')));
        return;
      }
      setState(() {
        _catalog = _repository.load();
        _selected = null;
      });
      messenger.showSnackBar(const SnackBar(content: Text('Library updated.')));
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) {
        setState(() {
          _updating = false;
          _updateEvent = null;
        });
      }
    }
  }
}

class SongListPane extends StatelessWidget {
  const SongListPane({
    required this.songs,
    required this.selected,
    required this.onSelect,
    required this.onFilterChanged,
    super.key,
  });

  final List<Song> songs;
  final Song? selected;
  final ValueChanged<Song> onSelect;
  final ValueChanged<String> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SearchBar(
            leading: const Icon(Icons.search),
            hintText: 'Search song, id, composer',
            onChanged: onFilterChanged,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index];
              final active = song.id == selected?.id;

              return ListTile(
                selected: active,
                title: Text(
                  song.title.isEmpty ? song.id : song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  song.composer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(
                  song.levels.map((level) => level.code).join('/'),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                onTap: () => onSelect(song),
              );
            },
          ),
        ),
      ],
    );
  }
}

class SongDetailsPane extends StatelessWidget {
  const SongDetailsPane({
    required this.song,
    required this.repository,
    required this.playerState,
    required this.onTogglePlay,
    required this.onExportPhira,
    super.key,
  });

  final Song? song;
  final CatalogRepository repository;
  final PlayerState playerState;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onExportPhira;

  @override
  Widget build(BuildContext context) {
    if (song == null) {
      return const _EmptyState();
    }

    final art = repository.resolveFile(song!.illustrationPath);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: art == null
                  ? const Center(child: Icon(Icons.image_not_supported))
                  : Image.file(art, fit: BoxFit.cover),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(song!.title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 6),
        Text(song!.id, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: onTogglePlay,
              icon: Icon(
                playerState == PlayerState.playing
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
              label: Text(
                playerState == PlayerState.playing ? 'Pause' : 'Play',
              ),
            ),
            OutlinedButton.icon(
              onPressed: onExportPhira,
              icon: const Icon(Icons.archive),
              label: const Text('Export Phira'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _InfoGrid(song: song!),
        const SizedBox(height: 24),
        Text('Levels', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final level in song!.levels) _LevelTile(level: level),
      ],
    );
  }
}

class _InfoGrid extends StatelessWidget {
  const _InfoGrid({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _InfoChip(label: 'Composer', value: song.composer),
        _InfoChip(label: 'Illustrator', value: song.illustrator),
        _InfoChip(label: 'Charts', value: song.levels.length.toString()),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 160),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _LevelTile extends StatelessWidget {
  const _LevelTile({required this.level});

  final ChartLevel level;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(child: Text(level.code)),
      title: Text('Lv.${level.difficulty.toStringAsFixed(1)}'),
      subtitle: Text(level.charter),
      trailing: Icon(
        level.chartPath == null ? Icons.error_outline : Icons.check_circle,
      ),
    );
  }
}

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({
    required this.catalog,
    required this.release,
    required this.error,
    required this.canUpdate,
    required this.updating,
    required this.onCatalogOnlyUpdate,
    required this.onFullUpdate,
  });

  final SongCatalog? catalog;
  final ApkRelease? release;
  final Object? error;
  final bool canUpdate;
  final bool updating;
  final VoidCallback onCatalogOnlyUpdate;
  final VoidCallback onFullUpdate;

  @override
  Widget build(BuildContext context) {
    final generatedAt = catalog?.generatedAt;
    final localVersion = catalog?.apkVersionName == null
        ? 'unknown APK'
        : '${catalog!.apkVersionName} (${catalog!.apkVersionCode ?? 0})';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Resource update',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _InfoChip(
              label: 'Local catalog',
              value: generatedAt == null
                  ? '${catalog?.songs.length ?? 0} songs, $localVersion'
                  : '${catalog?.songs.length ?? 0} songs, $localVersion, ${generatedAt.toLocal()}',
            ),
            const SizedBox(height: 12),
            if (release != null)
              _InfoChip(
                label: 'Latest APK',
                value:
                    '${release!.versionName} (${release!.versionCode}), ${release!.sizeLabel}',
              )
            else
              _InfoChip(
                label: 'Latest APK',
                value: error == null ? 'Checking failed.' : error.toString(),
              ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed:
                      canUpdate && !updating ? onCatalogOnlyUpdate : null,
                  icon: const Icon(Icons.library_music),
                  label: const Text('Update catalog'),
                ),
                OutlinedButton.icon(
                  onPressed: canUpdate && !updating ? onFullUpdate : null,
                  icon: const Icon(Icons.download),
                  label: const Text('Download and extract'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateStatusBanner extends StatelessWidget {
  const _UpdateStatusBanner({required this.event});

  final ResourceUpdateEvent? event;

  @override
  Widget build(BuildContext context) {
    final progress = event?.progress;
    final message = event?.message ?? 'Updating library';
    final stage = event?.stage ?? ResourceUpdateStage.resolving;

    return Container(
      key: const ValueKey('update-status'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_stageIcon(stage), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _stageLabel(stage),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (progress != null)
                Text(
                  '${(progress * 100).clamp(0, 100).toStringAsFixed(1)}%',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  static String _stageLabel(ResourceUpdateStage stage) {
    return switch (stage) {
      ResourceUpdateStage.resolving => 'Checking source',
      ResourceUpdateStage.downloading => 'Downloading APK',
      ResourceUpdateStage.extractingMetadata => 'Reading song metadata',
      ResourceUpdateStage.extractingAssets => 'Extracting resources',
      ResourceUpdateStage.writingCatalog => 'Writing catalog',
      ResourceUpdateStage.complete => 'Update complete',
      ResourceUpdateStage.failed => 'Update failed',
    };
  }

  static IconData _stageIcon(ResourceUpdateStage stage) {
    return switch (stage) {
      ResourceUpdateStage.resolving => Icons.travel_explore,
      ResourceUpdateStage.downloading => Icons.download,
      ResourceUpdateStage.extractingMetadata => Icons.library_music,
      ResourceUpdateStage.extractingAssets => Icons.inventory_2,
      ResourceUpdateStage.writingCatalog => Icons.save,
      ResourceUpdateStage.complete => Icons.check_circle,
      ResourceUpdateStage.failed => Icons.error,
    };
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          'No songs found. Run tools/phigros_updater.py and pass PHIGROS_LIBRARY.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}
