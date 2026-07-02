import 'dart:convert';
import 'dart:io';

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
  });

  final String libraryRoot;
  final String scriptPath;
  final String pythonExecutable;

  bool get canUpdate => libraryRoot.trim().isNotEmpty;

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
