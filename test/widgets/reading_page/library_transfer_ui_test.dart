import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/sync_status.dart';
import 'package:anx_reader/providers/sync_status.dart';
import 'package:anx_reader/providers/library_transfer_progress.dart';
import 'package:anx_reader/service/sync/library_transfer_progress.dart';
import 'package:anx_reader/widgets/bookshelf/book_item.dart';
import 'package:anx_reader/widgets/bookshelf/sync_status_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Status extends SyncStatus {
  @override
  Future<SyncStatusModel> build() async => const SyncStatusModel(
      localOnly: [],
      remoteOnly: [],
      both: [],
      nonExistent: [],
      downloading: [],
      uploading: [],
      released: []);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'webdavStatus': true});
    await Prefs().initPrefs();
    await L10n.delegate.load(const Locale('en'));
  });
  testWidgets(
      'book card shows upload percent without overflowing; details show bytes',
      (tester) async {
    final book =
        Book.mock().copyWith(title: 'A long book title that takes two lines');
    final container = ProviderContainer(overrides: [
      syncStatusProvider.overrideWith(_Status.new),
      libraryTransfersProvider.overrideWith((ref) => Stream.value({
            book.fileFullPath:
                LibraryTransfer(book.fileFullPath, 500000, 1000000),
          })),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
            body: Column(children: [
          SizedBox(width: 130, height: 220, child: BookItem(book: book)),
          const Expanded(child: SyncStatusBottomSheet()),
        ])),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await container.read(libraryTransfersProvider.future);
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('488.28 KB / 976.56 KB'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
