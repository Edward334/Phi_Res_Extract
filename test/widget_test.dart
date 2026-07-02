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
      PhigrosLibraryApp(
        repository: CatalogRepository(libraryRoot: libraryRoot),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phigros Library'), findsOneWidget);
    expect(find.textContaining('No songs found'), findsOneWidget);
  });

  test('loads generated library when configured', () async {
    const libraryRoot = String.fromEnvironment('PHIGROS_LIBRARY');
    if (libraryRoot.isEmpty) {
      return;
    }

    final repository = CatalogRepository(libraryRoot: libraryRoot);
    final catalog = await repository.load();
    expect(catalog.songs.length, 308);
    expect(
      catalog.songs.any((song) => song.title == '70 Minutes Fighters'),
      isTrue,
    );
  });
}
