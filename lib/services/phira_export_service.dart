import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../models/song.dart';
import 'catalog_repository.dart';

class PhiraExportResult {
  const PhiraExportResult({
    required this.exported,
    required this.skipped,
    required this.outputDirectory,
    required this.files,
  });

  final int exported;
  final int skipped;
  final Directory outputDirectory;
  final List<File> files;
}

class PhiraExportService {
  const PhiraExportService(this.repository);

  final CatalogRepository repository;

  PhiraExportResult exportSong(Song song) {
    if (!repository.hasLibraryRoot) {
      throw StateError('PHIGROS_LIBRARY is required for export.');
    }

    var exported = 0;
    var skipped = 0;
    final files = <File>[];
    final outputDirectory = Directory(p.join(repository.libraryRoot, 'phira'));

    for (final level in song.levels) {
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

      final levelDirectory = Directory(p.join(outputDirectory.path, level.code))
        ..createSync(recursive: true);
      final bytes = ZipEncoder().encode(archive);
      if (bytes == null) {
        skipped += 1;
        continue;
      }
      final outputFile = File(
        p.join(levelDirectory.path, '${song.id}-${level.code}.pez'),
      )..writeAsBytesSync(bytes);
      files.add(outputFile);
      exported += 1;
    }

    return PhiraExportResult(
      exported: exported,
      skipped: skipped,
      outputDirectory: outputDirectory,
      files: files,
    );
  }
}
