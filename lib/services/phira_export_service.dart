import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../models/song.dart';
import 'catalog_repository.dart';

class PhiraExportResult {
  const PhiraExportResult({
    required this.exported,
    required this.skipped,
    this.outputDirectory,
    required this.files,
    required this.packages,
  });

  final int exported;
  final int skipped;
  final Directory? outputDirectory;
  final List<File> files;
  final List<PhiraExportPackage> packages;
}

class PhiraExportPackage {
  const PhiraExportPackage({
    required this.levelCode,
    required this.fileName,
    required this.bytes,
  });

  final String levelCode;
  final String fileName;
  final Uint8List bytes;
}

class PhiraExportService {
  const PhiraExportService(this.repository);

  final CatalogRepository repository;

  Directory get defaultOutputDirectory {
    return Directory(p.join(repository.libraryRoot, 'phira'));
  }

  PhiraExportResult exportSong(
    Song song, {
    required Set<String> levels,
    Directory? outputDirectory,
  }) {
    if (!repository.hasLibraryRoot) {
      throw StateError('PHIGROS_LIBRARY is required for export.');
    }

    var exported = 0;
    var skipped = 0;
    final files = <File>[];
    final packages = <PhiraExportPackage>[];

    for (final level in song.levels) {
      if (!levels.contains(level.code)) {
        continue;
      }
      final chart = repository.resolveFile(level.chartPath);
      final music = repository.resolveFile(song.musicPath);
      final image = repository.resolveFile(song.illustrationPath);
      if (chart == null || music == null || image == null) {
        skipped += 1;
        continue;
      }
      final musicExtension =
          song.musicPath == null ? '.ogg' : p.extension(song.musicPath!);
      final musicName =
          '${song.id}${musicExtension.isEmpty ? '.ogg' : musicExtension}';

      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'info.txt',
            [
              '#',
              'Name: ${song.title}',
              'Song: $musicName',
              'Picture: ${song.id}.png',
              'Chart: ${song.id}.json',
              'Level: ${level.code} Lv.${level.difficulty}',
              'Composer: ${song.composer}',
              'Illustrator: ${song.illustrator}',
              'Charter: ${level.charter}',
            ].join('\n'),
          ),
        )
        ..addFile(
          ArchiveFile(
            '${song.id}.json',
            chart.lengthSync(),
            chart.readAsBytesSync(),
          ),
        )
        ..addFile(
          ArchiveFile(
            '${song.id}.png',
            image.lengthSync(),
            image.readAsBytesSync(),
          ),
        )
        ..addFile(
          ArchiveFile(musicName, music.lengthSync(), music.readAsBytesSync()),
        );

      final bytes = ZipEncoder().encode(archive);
      if (bytes == null) {
        skipped += 1;
        continue;
      }
      final package = PhiraExportPackage(
        levelCode: level.code,
        fileName: '${_safeFileName(song.id)}-${level.code}.pez',
        bytes: Uint8List.fromList(bytes),
      );
      packages.add(package);
      if (outputDirectory != null) {
        outputDirectory.createSync(recursive: true);
        final outputFile = File(p.join(outputDirectory.path, package.fileName))
          ..writeAsBytesSync(package.bytes);
        files.add(outputFile);
      }
      exported += 1;
    }

    return PhiraExportResult(
      exported: exported,
      skipped: skipped,
      outputDirectory: outputDirectory,
      files: files,
      packages: packages,
    );
  }

  static String _safeFileName(String value) {
    return value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
