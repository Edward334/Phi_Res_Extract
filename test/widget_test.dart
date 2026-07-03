import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phigros_library/main.dart';
import 'package:phigros_library/models/song.dart';
import 'package:phigros_library/services/catalog_repository.dart';
import 'package:phigros_library/services/unity_fs_reader.dart';

void main() {
  testWidgets('shows bundled empty catalog state', (tester) async {
    const libraryRoot = String.fromEnvironment('PHIGROS_LIBRARY');
    if (libraryRoot.isNotEmpty) {
      return;
    }

    await tester.pumpWidget(
      const PhigrosLibraryApp(
        repository: CatalogRepository(libraryRoot: libraryRoot),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phigros 资源库'), findsOneWidget);
    expect(find.textContaining('本地还没有资源'), findsOneWidget);
  });

  test('loads generated library when configured', () async {
    const libraryRoot = String.fromEnvironment('PHIGROS_LIBRARY');
    if (libraryRoot.isEmpty) {
      return;
    }

    const repository = CatalogRepository(libraryRoot: libraryRoot);
    final catalog = await repository.load();
    expect(catalog.songs.length, 308);
    expect(
      catalog.songs.any((song) => song.title == '70 Minutes Fighters'),
      isTrue,
    );
  });

  test('keeps zero difficulty hidden unless a chart exists', () {
    final song = Song(
      id: 'example',
      title: 'Example',
      composer: '',
      illustrator: '',
      charters: const ['ez', 'hd', 'in', ''],
      difficulties: const [1, 6.5, 12.6, 0],
      illustrationPath: null,
      musicPath: null,
      chartPaths: const {'EZ': 'chart/example.0/EZ.json'},
    );

    expect(song.levels.map((level) => level.code), ['EZ', 'HD', 'IN']);
    expect(song.levels.last.difficulty, 12.6);
  });

  test('encodes RGB24 textures as PNG', () {
    final texture = UnityTexture2D(
      name: 'pixel',
      width: 1,
      height: 1,
      format: 3,
      data: Uint8List.fromList([0xff, 0x00, 0x00]),
    );

    final png = const PngRgb24Encoder().encode(texture);
    expect(png.take(8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  });
}
