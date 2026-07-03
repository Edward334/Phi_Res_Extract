import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../models/song.dart';
import 'apk_addressables_reader.dart';
import 'unity_fs_reader.dart';

enum ResourceUpdateStage {
  resolving,
  downloading,
  extractingMetadata,
  extractingAssets,
  writingCatalog,
  complete,
  failed,
}

class ResourceUpdateEvent {
  const ResourceUpdateEvent({
    required this.stage,
    required this.message,
    this.progress,
    this.output = '',
  });

  final ResourceUpdateStage stage;
  final String message;
  final double? progress;
  final String output;
}

class ApkRelease {
  const ApkRelease({
    required this.versionName,
    required this.versionCode,
    required this.updateDate,
    required this.size,
    required this.url,
  });

  final String versionName;
  final int versionCode;
  final String updateDate;
  final int size;
  final String url;

  String get sizeLabel {
    if (size <= 0) {
      return 'unknown size';
    }
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  factory ApkRelease.fromUpdaterJson(Map<String, dynamic> json) {
    if (!json.containsKey('metadata')) {
      return ApkRelease(
        versionName: json['versionName'] as String? ?? 'unknown',
        versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
        updateDate: json['updateDate'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        url: json['url'] as String? ?? '',
      );
    }

    final app =
        json['metadata']?['app']?['data'] as Map<String, dynamic>? ?? {};
    final apk =
        json['metadata']?['apk']?['data']?['apk'] as Map<String, dynamic>? ??
            {};

    return ApkRelease(
      versionName: apk['version_name'] as String? ?? 'unknown',
      versionCode: (apk['version_code'] as num?)?.toInt() ?? 0,
      updateDate: app['update_date'] as String? ?? '',
      size: (apk['size'] as num?)?.toInt() ?? 0,
      url: json['url'] as String? ?? apk['download'] as String? ?? '',
    );
  }
}

class ResourceUpdateResult {
  const ResourceUpdateResult({required this.exitCode, required this.output});

  final int exitCode;
  final String output;

  bool get success => exitCode == 0;
}

class ResourceUpdateService {
  ResourceUpdateService({
    required this.libraryRoot,
    this.scriptPath = const String.fromEnvironment(
      'PHIGROS_UPDATER',
      defaultValue: 'tools/phigros_updater.py',
    ),
    this.pythonExecutable = const String.fromEnvironment(
      'PYTHON',
      defaultValue: 'python',
    ),
    this.apkMetadataUrl = const String.fromEnvironment(
      'PHIGROS_APK_METADATA',
      defaultValue:
          'https://github.com/Edward334/Phi_Res_Extract/releases/download/apk-latest/taptap-apk.json',
    ),
  });

  final String libraryRoot;
  final String scriptPath;
  final String pythonExecutable;
  final String apkMetadataUrl;
  final _addressablesReader = const ApkAddressablesReader();
  final _unityFsReader = const UnityFsReader();
  final _serializedReader = const UnitySerializedFileReader();

  bool get canUpdate => libraryRoot.trim().isNotEmpty;
  bool get usesRemoteApkMetadata => Platform.isAndroid;

  Future<ApkRelease> resolveLatest() async {
    if (usesRemoteApkMetadata) {
      return _resolveLatestFromMetadata();
    }

    final result = await Process.run(
        pythonExecutable,
        [
          scriptPath,
          'resolve-apk',
        ],
        workingDirectory: _workingDirectory);
    if (result.exitCode != 0) {
      throw ProcessException(
        pythonExecutable,
        [scriptPath, 'resolve-apk'],
        '${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }

    return ApkRelease.fromUpdaterJson(
      jsonDecode(result.stdout.toString()) as Map<String, dynamic>,
    );
  }

  Future<ResourceUpdateResult> updateLibrary({bool catalogOnly = false}) async {
    ResourceUpdateResult? result;
    await for (final event in updateLibraryStream(catalogOnly: catalogOnly)) {
      if (event.stage == ResourceUpdateStage.complete) {
        result = ResourceUpdateResult(exitCode: 0, output: event.output);
      } else if (event.stage == ResourceUpdateStage.failed) {
        result = ResourceUpdateResult(exitCode: 1, output: event.output);
      }
    }
    return result ?? const ResourceUpdateResult(exitCode: 1, output: '');
  }

  Stream<ResourceUpdateEvent> updateLibraryStream({
    bool catalogOnly = false,
  }) async* {
    if (!canUpdate) {
      throw StateError('PHIGROS_LIBRARY is required before updating.');
    }

    if (usesRemoteApkMetadata) {
      yield* _downloadApkStream();
      return;
    }

    final args = [
      scriptPath,
      'update',
      '--out',
      libraryRoot,
      if (catalogOnly) '--catalog-only',
    ];

    yield const ResourceUpdateEvent(
      stage: ResourceUpdateStage.resolving,
      message: 'Starting updater',
    );

    final process = await Process.start(
      pythonExecutable,
      args,
      workingDirectory: _workingDirectory,
      environment: {'PYTHONUNBUFFERED': '1'},
    );
    final output = StringBuffer();

    await for (final line in process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      output.writeln(line);
      yield _eventFromLine(line, output.toString());
    }

    final stderr = await process.stderr.transform(utf8.decoder).join();
    if (stderr.trim().isNotEmpty) {
      output.writeln(stderr.trim());
    }

    final exitCode = await process.exitCode;
    if (exitCode == 0) {
      yield ResourceUpdateEvent(
        stage: ResourceUpdateStage.complete,
        message: 'Library updated',
        progress: 1,
        output: output.toString(),
      );
    } else {
      yield ResourceUpdateEvent(
        stage: ResourceUpdateStage.failed,
        message: 'Update failed',
        output: output.toString(),
      );
    }
  }

  Future<ApkRelease> _resolveLatestFromMetadata() async {
    final uri = Uri.parse(apkMetadataUrl);
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'APK 下载信息获取失败：HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      final source = await response.transform(utf8.decoder).join();
      return ApkRelease.fromUpdaterJson(
        jsonDecode(source) as Map<String, dynamic>,
      );
    } finally {
      client.close(force: true);
    }
  }

  Stream<ResourceUpdateEvent> _downloadApkStream() async* {
    final root = Directory(libraryRoot);
    final apkDir = Directory(p.join(root.path, 'apk'));
    await apkDir.create(recursive: true);

    final apk = File(p.join(apkDir.path, 'phigros_latest.apk'));
    final part = File('${apk.path}.part');
    final metadataFile = File(p.join(apkDir.path, 'taptap-apk.json'));

    yield const ResourceUpdateEvent(
      stage: ResourceUpdateStage.resolving,
      message: '正在获取 APK 下载地址',
    );

    final client = HttpClient();
    try {
      final release = await _resolveLatestFromMetadata();
      await metadataFile.writeAsString(
        jsonEncode({
          'url': release.url,
          'versionName': release.versionName,
          'versionCode': release.versionCode,
          'updateDate': release.updateDate,
          'size': release.size,
        }),
        encoding: utf8,
      );

      if (release.url.isEmpty) {
        throw const FormatException('APK 下载地址为空');
      }

      final uri = Uri.parse(release.url);
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'APK 下载失败：HTTP ${response.statusCode}',
          uri: uri,
        );
      }

      final total = release.size > 0 ? release.size : response.contentLength;
      var downloaded = 0;
      final sink = part.openWrite();
      await for (final chunk in response) {
        downloaded += chunk.length;
        sink.add(chunk);
        yield ResourceUpdateEvent(
          stage: ResourceUpdateStage.downloading,
          message: total > 0
              ? '正在下载 APK ${_formatBytes(downloaded)} / ${_formatBytes(total)}'
              : '正在下载 APK ${_formatBytes(downloaded)}',
          progress: total > 0 ? downloaded / total : null,
        );
      }
      await sink.close();
      if (await apk.exists()) {
        await apk.delete();
      }
      await part.rename(apk.path);

      yield const ResourceUpdateEvent(
        stage: ResourceUpdateStage.extractingMetadata,
        message: '正在端内解析 Addressables 目录',
        progress: 1,
      );

      final assets = await _addressablesReader.readTrackAssets(apk);
      final catalogDir = Directory(p.join(root.path, 'catalog'));
      await catalogDir.create(recursive: true);
      await File(p.join(catalogDir.path, 'addressables.json')).writeAsString(
        jsonEncode({
          'generatedAt': DateTime.now().toUtc().toIso8601String(),
          'apk': {
            'versionName': release.versionName,
            'versionCode': release.versionCode,
            'size': release.size,
          },
          'assets': assets.map((asset) => asset.toJson()).toList(),
        }),
        encoding: utf8,
      );

      final chartAssets = assets.where(_isChartAsset).toList();
      if (chartAssets.isEmpty) {
        throw const FormatException('Addressables 中没有找到谱面资源');
      }

      yield ResourceUpdateEvent(
        stage: ResourceUpdateStage.extractingAssets,
        message: '正在端内解压谱面 0 / ${chartAssets.length}',
        progress: 0,
      );

      final chartsBySong = <String, Map<String, String>>{};
      final assetsByBundle = <String, List<AddressableAsset>>{};
      for (final asset in chartAssets) {
        assetsByBundle.putIfAbsent(asset.bundle, () => []).add(asset);
      }

      var processed = 0;
      var extracted = 0;
      final input = InputFileStream(apk.path);
      try {
        final archive = ZipDecoder().decodeBuffer(input);
        try {
          final archiveFiles = {
            for (final file in archive.files)
              if (file.isFile) file.name: file,
          };

          for (final entry in assetsByBundle.entries) {
            final bundleFile = archiveFiles['assets/aa/Android/${entry.key}'];
            if (bundleFile != null) {
              final bundleContent = bundleFile.content;
              final bundleBytes = bundleContent is Uint8List
                  ? bundleContent
                  : Uint8List.fromList(bundleContent as List<int>);
              final textAssets = <String, UnityTextAsset>{};
              for (final file in _unityFsReader.readFiles(bundleBytes)) {
                for (final text
                    in _serializedReader.readTextAssets(file.data)) {
                  textAssets[text.name] = text;
                }
              }

              for (final asset in entry.value) {
                final level = _chartLevel(asset.key);
                final trackId = _chartTrackId(asset.key);
                if (level == null || trackId == null) {
                  continue;
                }
                final text = textAssets['Chart_$level'];
                if (text == null) {
                  continue;
                }

                final chartDir = Directory(p.join(root.path, 'chart', trackId));
                await chartDir.create(recursive: true);
                final relativePath =
                    p.posix.join('chart', trackId, '$level.json');
                await File(p.join(root.path, relativePath)).writeAsBytes(
                  text.bytes,
                  flush: false,
                );
                final songId = trackId.endsWith('.0')
                    ? trackId.substring(0, trackId.length - 2)
                    : trackId;
                chartsBySong.putIfAbsent(
                    songId, () => <String, String>{})[level] = relativePath;
                extracted += 1;
              }
              bundleFile.clear();
            }

            processed += entry.value.length;
            yield ResourceUpdateEvent(
              stage: ResourceUpdateStage.extractingAssets,
              message: '正在端内解压谱面 $processed / ${chartAssets.length}',
              progress: processed / chartAssets.length,
            );
          }
        } finally {
          await archive.clear();
        }
      } finally {
        await input.close();
      }

      if (extracted == 0) {
        throw const FormatException('未能从 Unity bundle 中解出谱面');
      }

      yield const ResourceUpdateEvent(
        stage: ResourceUpdateStage.writingCatalog,
        message: '正在写入曲目目录',
        progress: 1,
      );

      final generatedAt = DateTime.now().toUtc().toIso8601String();
      final songs = [
        for (final entry in chartsBySong.entries)
          {
            'id': entry.key,
            'title': entry.key,
            'composer': '',
            'illustrator': '',
            'charters': const <String>[],
            'difficulties': const <double>[],
            'illustrationPath': null,
            'musicPath': null,
            'chartPaths': {
              for (final level in chartLevels)
                if (entry.value[level] case final path?) level: path,
            },
          },
      ]..sort((left, right) =>
          (left['title'] as String).compareTo(right['title'] as String));

      await File(p.join(catalogDir.path, 'songs.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 1,
          'generatedAt': generatedAt,
          'source': 'Android APK Addressables and TextAsset chart bundles',
          'apkVersionName': release.versionName,
          'apkVersionCode': release.versionCode,
          'songs': songs,
        }),
        encoding: utf8,
      );

      yield ResourceUpdateEvent(
        stage: ResourceUpdateStage.complete,
        message: '已完成 APK 下载、Addressables 目录解析和 $extracted 个谱面解压；曲绘和音频解析后续接入。',
        progress: 1,
      );
    } on Object catch (error) {
      yield ResourceUpdateEvent(
        stage: ResourceUpdateStage.failed,
        message: error.toString(),
      );
    } finally {
      client.close(force: true);
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  static bool _isChartAsset(AddressableAsset asset) {
    return _chartLevel(asset.key) != null;
  }

  static String? _chartTrackId(String key) {
    final index = key.indexOf('/Chart_');
    if (index <= 0) {
      return null;
    }
    return key.substring(0, index);
  }

  static String? _chartLevel(String key) {
    final match = RegExp(r'/Chart_(EZ|HD|IN|AT)\.json$').firstMatch(key);
    return match?.group(1);
  }

  ResourceUpdateEvent _eventFromLine(String line, String output) {
    final downloadMatch = RegExp(
      r'downloaded\s+(\d+)/(\d+)\s+bytes\s+\(([\d.]+)%\)',
    ).firstMatch(line);
    if (downloadMatch != null) {
      return ResourceUpdateEvent(
        stage: ResourceUpdateStage.downloading,
        message: line,
        progress: (double.tryParse(downloadMatch.group(3) ?? '') ?? 0) / 100,
        output: output,
      );
    }

    final assetMatch = RegExp(
      r'assets extracted\s+(\d+)/(\d+)\s+\(([\d.]+)%\)',
    ).firstMatch(line);
    if (assetMatch != null) {
      return ResourceUpdateEvent(
        stage: ResourceUpdateStage.extractingAssets,
        message: line,
        progress: (double.tryParse(assetMatch.group(3) ?? '') ?? 0) / 100,
        output: output,
      );
    }

    if (line.contains('fetching latest TapTap APK metadata')) {
      return ResourceUpdateEvent(
        stage: ResourceUpdateStage.resolving,
        message: line,
        output: output,
      );
    }
    if (line.contains('extracting GameInformation')) {
      return ResourceUpdateEvent(
        stage: ResourceUpdateStage.extractingMetadata,
        message: line,
        output: output,
      );
    }
    if (line.contains('extracting charts')) {
      return ResourceUpdateEvent(
        stage: ResourceUpdateStage.extractingAssets,
        message: line,
        output: output,
      );
    }
    if (line.contains('wrote')) {
      return ResourceUpdateEvent(
        stage: ResourceUpdateStage.writingCatalog,
        message: line,
        output: output,
      );
    }

    return ResourceUpdateEvent(
      stage: ResourceUpdateStage.resolving,
      message: line,
      output: output,
    );
  }

  String? get _workingDirectory {
    final script = File(scriptPath);
    if (script.isAbsolute) {
      return script.parent.path;
    }

    if (File(scriptPath).existsSync()) {
      return Directory.current.path;
    }

    return null;
  }
}
