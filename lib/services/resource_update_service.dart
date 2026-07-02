import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

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
    this.resourceBundleUrl = const String.fromEnvironment(
      'PHIGROS_RESOURCE_BUNDLE',
      defaultValue:
          'https://github.com/Edward334/Phi_Res_Extract/releases/download/resources-latest/phigros-library.zip',
    ),
  });

  final String libraryRoot;
  final String scriptPath;
  final String pythonExecutable;
  final String resourceBundleUrl;

  bool get canUpdate => libraryRoot.trim().isNotEmpty;
  bool get usesResourceBundle => Platform.isAndroid;

  Future<ApkRelease> resolveLatest() async {
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

    if (usesResourceBundle) {
      yield* _downloadResourceBundleStream();
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

  Stream<ResourceUpdateEvent> _downloadResourceBundleStream() async* {
    final root = Directory(libraryRoot);
    final parent = root.parent;
    await parent.create(recursive: true);

    final zip = File(p.join(parent.path, 'phigros-library.zip'));
    final part = File('${zip.path}.part');
    final staging = Directory('${root.path}.staging');

    yield const ResourceUpdateEvent(
      stage: ResourceUpdateStage.resolving,
      message: '正在连接在线资源包',
    );

    final uri = Uri.parse(resourceBundleUrl);
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          '资源包下载失败：HTTP ${response.statusCode}',
          uri: uri,
        );
      }

      final total = response.contentLength;
      var downloaded = 0;
      final sink = part.openWrite();
      await for (final chunk in response) {
        downloaded += chunk.length;
        sink.add(chunk);
        yield ResourceUpdateEvent(
          stage: ResourceUpdateStage.downloading,
          message: total > 0
              ? '正在下载资源包 ${_formatBytes(downloaded)} / ${_formatBytes(total)}'
              : '正在下载资源包 ${_formatBytes(downloaded)}',
          progress: total > 0 ? downloaded / total : null,
        );
      }
      await sink.close();
      if (await zip.exists()) {
        await zip.delete();
      }
      await part.rename(zip.path);

      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      await staging.create(recursive: true);

      yield const ResourceUpdateEvent(
        stage: ResourceUpdateStage.extractingAssets,
        message: '正在解压资源包',
      );

      final input = InputFileStream(zip.path);
      final archive = ZipDecoder().decodeBuffer(input);
      final files = archive.files.where((file) => file.isFile).toList();
      var extracted = 0;
      for (final file in archive.files) {
        final name = _normalizedArchivePath(file.name);
        if (name == null) {
          continue;
        }
        final target = p.join(staging.path, name);

        if (!file.isFile) {
          await Directory(target).create(recursive: true);
          continue;
        }

        await Directory(p.dirname(target)).create(recursive: true);
        final output = OutputFileStream(target);
        file.writeContent(output);
        await output.close();
        file.clear();
        extracted += 1;
        yield ResourceUpdateEvent(
          stage: ResourceUpdateStage.extractingAssets,
          message: '正在解压资源 $extracted / ${files.length}',
          progress: files.isEmpty ? null : extracted / files.length,
        );
      }
      await input.close();
      await archive.clear();

      final catalog = File(p.join(staging.path, 'catalog', 'songs.json'));
      if (!await catalog.exists()) {
        throw const FileSystemException('资源包中缺少 catalog/songs.json');
      }

      yield const ResourceUpdateEvent(
        stage: ResourceUpdateStage.writingCatalog,
        message: '正在写入本地资源库',
        progress: 1,
      );

      if (await root.exists()) {
        await root.delete(recursive: true);
      }
      await staging.rename(root.path);

      yield const ResourceUpdateEvent(
        stage: ResourceUpdateStage.complete,
        message: '资源库已更新',
        progress: 1,
      );
    } on Object catch (error) {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      yield ResourceUpdateEvent(
        stage: ResourceUpdateStage.failed,
        message: error.toString(),
      );
    } finally {
      client.close(force: true);
    }
  }

  String? _normalizedArchivePath(String name) {
    final normalized = p.posix.normalize(name).replaceAll('\\', '/');
    if (normalized == '.' ||
        normalized.startsWith('/') ||
        normalized.startsWith('../') ||
        normalized.contains('/../')) {
      return null;
    }

    const rootPrefix = 'phigros_library/';
    if (normalized.startsWith(rootPrefix)) {
      return normalized.substring(rootPrefix.length);
    }
    return normalized;
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
