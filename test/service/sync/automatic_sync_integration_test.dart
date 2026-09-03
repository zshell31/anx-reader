import 'dart:async';

import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/organization_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';
import 'package:anx_reader/service/sync/remote_document_discovery.dart';
import 'package:anx_reader/service/sync/sync_run_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('overlapping lifecycle triggers coalesce with one follow-up pass',
      () async {
    final gate = SyncRunGate();
    final firstPass = Completer<void>();
    var runs = 0;
    Future<void> operation() async {
      runs++;
      if (runs == 1) await firstPass.future;
    }

    final first = gate.run(operation);
    final second = gate.run(operation);
    final third = gate.run(operation);
    expect(gate.isRunning, isTrue);
    firstPass.complete();

    await Future.wait([first, second, third]);
    expect(runs, 2);
    expect(gate.isRunning, isFalse);
  });

  test('passive trigger joins an active run without scheduling a follow-up',
      () async {
    final gate = SyncRunGate();
    final firstPass = Completer<void>();
    var runs = 0;
    Future<void> operation() async {
      runs++;
      await firstPass.future;
    }

    final first = gate.run(operation);
    final passive = gate.run(operation, queueFollowUp: false);
    firstPass.complete();

    await Future.wait([first, passive]);
    expect(runs, 1);
    expect(gate.isRunning, isFalse);
  });

  test('remote discovery maps flat and nested collections to domain IDs',
      () async {
    const fingerprint = '0123456789abcdef0123456789abcdef';
    const uuid = '123e4567-e89b-12d3-a456-426614174000';
    final entries = <String, List<WebDavCollectionEntry>>{
      'annotations': const [
        WebDavCollectionEntry('$fingerprint.json',
            isCollection: false, strongEtag: '"annotation-v1"'),
        WebDavCollectionEntry('not-a-book.json', isCollection: false),
      ],
      'shared/v1/catalog/books': const [
        WebDavCollectionEntry('$fingerprint.json', isCollection: false),
      ],
      'shared/v1/reading-state': const [],
      'shared/v1/groups': const [
        WebDavCollectionEntry('$uuid.json', isCollection: false),
      ],
      'shared/v1/tags': const [],
      'shared/v1/themes': const [],
      'shared/v1/reading-activity': const [
        WebDavCollectionEntry(fingerprint, isCollection: true),
      ],
      'shared/v1/reading-activity/$fingerprint': const [
        WebDavCollectionEntry('2026-09-01.json',
            isCollection: false, strongEtag: '"activity-v1"'),
      ],
      'shared/v1/book-tags': const [
        WebDavCollectionEntry(fingerprint, isCollection: true),
      ],
      'shared/v1/book-tags/$fingerprint': const [
        WebDavCollectionEntry('$uuid.json', isCollection: false),
      ],
    };
    final discovery = RemoteDocumentDiscovery(
      (path) async => entries[path.join('/')] ?? const [],
    );

    final result = await discovery.discover();

    expect(result.ids(annotationSyncDomain), {fingerprint});
    expect(result.ids(libraryCatalogDomain), {fingerprint});
    expect(result.ids(groupDomain), {uuid});
    expect(result.ids(readingActivityDomain), {'$fingerprint@2026-09-01'});
    expect(result.ids(bookTagDomain), {'$fingerprint@$uuid'});
    expect(result.strongEtags(annotationSyncDomain),
        {fingerprint: '"annotation-v1"'});
    expect(result.strongEtags(readingActivityDomain),
        {'$fingerprint@2026-09-01': '"activity-v1"'});
    expect(result.documentCount, 5);
  });
}
