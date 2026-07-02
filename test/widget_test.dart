import 'package:flutter_test/flutter_test.dart';
import 'package:phigros_library/main.dart';
import 'package:phigros_library/services/catalog_repository.dart';

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
}
