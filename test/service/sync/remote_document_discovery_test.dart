import 'package:anx_reader/service/sync/remote_document_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful discovery pulls only documents present remotely', () {
    expect(
      remoteDocumentPullTargets(
        localIds: const {'local-only', 'shared'},
        remoteIds: const {'remote-only', 'shared'},
        remoteIndexAuthoritative: true,
      ),
      unorderedEquals(const {'remote-only', 'shared'}),
    );
  });

  test('failed discovery conservatively retains locally known targets', () {
    expect(
      remoteDocumentPullTargets(
        localIds: const {'local-only', 'shared'},
        remoteIds: const {'remote-only', 'shared'},
        remoteIndexAuthoritative: false,
      ),
      unorderedEquals(const {'local-only', 'remote-only', 'shared'}),
    );
  });
}
