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
      title: 'Phigros 资源库',
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
  CatalogRepository? _repository;
  final _player = AudioPlayer();
  PhiraExportService? _exporter;
  ResourceUpdateService? _updater;
  Future<SongCatalog>? _catalog;
  Song? _selected;
  String _filter = '';
  PlayerState _playerState = PlayerState.stopped;
  bool _updating = false;
  ResourceUpdateEvent? _updateEvent;

  @override
  void initState() {
    super.initState();
    _initializeLibrary();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _playerState = state);
      }
    });
  }

  Future<void> _initializeLibrary() async {
    final repository =
        widget.repository ?? await CatalogRepository.createDefault();
    if (!mounted) {
      return;
    }

    setState(() {
      _repository = repository;
      _exporter = PhiraExportService(repository);
      _updater = ResourceUpdateService(libraryRoot: repository.libraryRoot);
      _catalog = repository.load();
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    final catalogFuture = _catalog;
    if (repository == null || catalogFuture == null) {
      return const Scaffold(
        body: SafeArea(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return FutureBuilder<SongCatalog>(
      future: catalogFuture,
      builder: (context, snapshot) {
        final catalog = snapshot.data;
        final songs = _filteredSongs(catalog?.songs ?? const []);
        final selected = _selected ?? (songs.isEmpty ? null : songs.first);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Phigros 资源库'),
            actions: [
              IconButton(
                tooltip: '同步资源',
                onPressed: _updating ? null : () => _showUpdateSheet(catalog),
                icon: const Icon(Icons.sync),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    catalog == null ? '加载中' : '${catalog.songs.length} 首',
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
                        return _EmptyState(
                          onUpdate: _updating
                              ? null
                              : () => _showUpdateSheet(catalog),
                        );
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
                          repository: repository,
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

    final music = _repository?.resolveFile(song.musicPath);
    if (music == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('音乐文件不可用，请先下载完整资源。')),
        );
      }
      return;
    }

    await _player.play(DeviceFileSource(music.path));
  }

  Future<void> _exportPhiraPackage(Song song) async {
    try {
      final result = _exporter!.exportSong(song);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导出 ${result.exported} 个谱面，跳过 ${result.skipped} 个。',
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
    final updater = _updater;
    if (updater == null) {
      return;
    }

    setState(() => _updating = true);
    ApkRelease? release;
    Object? error;
    if (!updater.usesRemoteApkMetadata) {
      try {
        release = await updater.resolveLatest();
      } on Object catch (caught) {
        error = caught;
      } finally {
        if (mounted) {
          setState(() => _updating = false);
        }
      }
    } else if (mounted) {
      setState(() => _updating = false);
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
            canUpdate: updater.canUpdate,
            updating: _updating,
            usesRemoteApkMetadata: updater.usesRemoteApkMetadata,
            onCatalogOnlyUpdate: () => _runUpdate(catalogOnly: true),
            onFullUpdate: () => _runUpdate(catalogOnly: false),
          );
        },
      );
    }
  }

  Future<void> _runUpdate({required bool catalogOnly}) async {
    final repository = _repository;
    final updater = _updater;
    if (repository == null || updater == null) {
      return;
    }

    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _updating = true;
      _updateEvent = const ResourceUpdateEvent(
        stage: ResourceUpdateStage.resolving,
        message: '正在准备更新',
      );
    });
    try {
      var success = false;
      var output = '';
      await for (final event in updater.updateLibraryStream(
        catalogOnly: catalogOnly,
      )) {
        if (mounted) {
          setState(() => _updateEvent = event);
        }
        output = event.output.isEmpty ? event.message : event.output;
        success = event.stage == ResourceUpdateStage.complete;
        if (event.stage == ResourceUpdateStage.failed) {
          break;
        }
      }

      if (!success) {
        messenger.showSnackBar(SnackBar(content: Text('更新失败：$output')));
        return;
      }
      setState(() {
        _catalog = repository.load();
        _selected = null;
      });
      messenger.showSnackBar(const SnackBar(content: Text('资源库已更新。')));
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
            hintText: '搜索曲名、ID、曲师',
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
                playerState == PlayerState.playing ? '暂停' : '播放',
              ),
            ),
            OutlinedButton.icon(
              onPressed: onExportPhira,
              icon: const Icon(Icons.archive),
              label: const Text('导出 Phira'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _InfoGrid(song: song!),
        const SizedBox(height: 24),
        Text('难度', style: Theme.of(context).textTheme.titleMedium),
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
        _InfoChip(label: '曲师', value: song.composer),
        _InfoChip(label: '画师', value: song.illustrator),
        _InfoChip(label: '谱面数', value: song.levels.length.toString()),
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
    final difficulty = level.difficulty;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(child: Text(level.code)),
      title: Text(
          difficulty == null ? 'Lv.?' : 'Lv.${difficulty.toStringAsFixed(1)}'),
      subtitle: Text(level.charter.isEmpty ? '谱师未知' : level.charter),
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
    required this.usesRemoteApkMetadata,
    required this.onCatalogOnlyUpdate,
    required this.onFullUpdate,
  });

  final SongCatalog? catalog;
  final ApkRelease? release;
  final Object? error;
  final bool canUpdate;
  final bool updating;
  final bool usesRemoteApkMetadata;
  final VoidCallback onCatalogOnlyUpdate;
  final VoidCallback onFullUpdate;

  @override
  Widget build(BuildContext context) {
    final generatedAt = catalog?.generatedAt;
    final localVersion = catalog?.apkVersionName == null
        ? '未知 APK'
        : '${catalog!.apkVersionName} (${catalog!.apkVersionCode ?? 0})';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '资源同步',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _InfoChip(
              label: '本地目录',
              value: generatedAt == null
                  ? '${catalog?.songs.length ?? 0} 首，$localVersion'
                  : '${catalog?.songs.length ?? 0} 首，$localVersion，${generatedAt.toLocal()}',
            ),
            const SizedBox(height: 12),
            if (usesRemoteApkMetadata)
              const _InfoChip(
                label: 'APK 下载地址',
                value:
                    '由 GitHub Actions 只解析最新 APK 地址；应用运行时下载 APK，TapTap 和资源不会打包进应用。',
              )
            else if (release != null)
              _InfoChip(
                label: '最新 APK',
                value:
                    '${release!.versionName} (${release!.versionCode}), ${release!.sizeLabel}',
              )
            else
              _InfoChip(
                label: '最新 APK',
                value: error == null ? '检查失败。' : error.toString(),
              ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (!usesRemoteApkMetadata)
                  FilledButton.icon(
                    onPressed:
                        canUpdate && !updating ? onCatalogOnlyUpdate : null,
                    icon: const Icon(Icons.library_music),
                    label: const Text('仅更新目录'),
                  ),
                FilledButton.icon(
                  onPressed: canUpdate && !updating ? onFullUpdate : null,
                  icon: const Icon(Icons.download),
                  label: Text(usesRemoteApkMetadata ? '下载 APK' : '下载并解包'),
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
    final message = event?.message ?? '正在更新资源库';
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
      ResourceUpdateStage.resolving => '检查资源来源',
      ResourceUpdateStage.downloading => '下载 APK',
      ResourceUpdateStage.extractingMetadata => '读取曲目信息',
      ResourceUpdateStage.extractingAssets => '解压资源',
      ResourceUpdateStage.writingCatalog => '写入目录',
      ResourceUpdateStage.complete => '更新完成',
      ResourceUpdateStage.failed => '更新失败',
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
  const _EmptyState({this.onUpdate});

  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '本地还没有资源',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '点击下载 APK 后，应用会从轻量下载地址 JSON 获取官方 APK 地址；TapTap、APK 和资源都不会预打包进应用。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onUpdate,
              icon: const Icon(Icons.download),
              label: const Text('下载 APK'),
            ),
          ],
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
