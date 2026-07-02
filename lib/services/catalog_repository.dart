import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';

class CatalogRepository {
  const CatalogRepository({
    this.libraryRoot = const String.fromEnvironment('PHIGROS_LIBRARY'),
  });

  final String libraryRoot;

  bool get hasLibraryRoot => libraryRoot.trim().isNotEmpty;

  static Future<CatalogRepository> createDefault() async {
    const configured = String.fromEnvironment('PHIGROS_LIBRARY');
    if (configured.trim().isNotEmpty) {
      return const CatalogRepository(libraryRoot: configured);
    }

    if (!kIsWeb && (Platform.isAndroid || Platform.isLinux)) {
      final support = await getApplicationSupportDirectory();
      return CatalogRepository(
        libraryRoot: p.join(support.path, 'phigros_library'),
      );
    }

    return const CatalogRepository();
  }

  Future<SongCatalog> load() async {
    if (hasLibraryRoot) {
      final file = File(p.join(libraryRoot, 'catalog', 'songs.json'));
      if (await file.exists()) {
        return SongCatalog.fromString(await file.readAsString());
      }
    }

    final bundled = await rootBundle.loadString('assets/catalog/songs.json');
    return SongCatalog.fromString(bundled);
  }

  File? resolveFile(String? relativePath) {
    if (!hasLibraryRoot || relativePath == null || relativePath.isEmpty) {
      return null;
    }

    final file = File(p.join(libraryRoot, relativePath));
    return file.existsSync() ? file : null;
  }
}
