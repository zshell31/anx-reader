import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/organization_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';

typedef RemoteCollectionList = Future<List<WebDavCollectionEntry>> Function(
    List<String> path);

Set<String> remoteDocumentPullTargets({
  required Iterable<String> localIds,
  required Iterable<String> remoteIds,
  required bool remoteIndexAuthoritative,
}) =>
    remoteIndexAuthoritative ? remoteIds.toSet() : {...localIds, ...remoteIds};

class RemoteDocumentIndex {
  final Map<String, Set<String>> idsByDomain;
  final Map<String, Map<String, String>> strongEtagsByDomain;
  const RemoteDocumentIndex(
    this.idsByDomain, [
    this.strongEtagsByDomain = const {},
  ]);

  Set<String> ids(String domain) => idsByDomain[domain] ?? const {};
  Map<String, String> strongEtags(String domain) =>
      strongEtagsByDomain[domain] ?? const {};
  int get documentCount =>
      idsByDomain.values.fold(0, (total, ids) => total + ids.length);
}

/// Discovers portable document identities without reading document contents.
/// Invalid and unexpectedly nested WebDAV entries are ignored.
class RemoteDocumentDiscovery {
  final RemoteCollectionList list;
  const RemoteDocumentDiscovery(this.list);

  Future<RemoteDocumentIndex> discover() async {
    final result = <String, Set<String>>{};
    final strongEtags = <String, Map<String, String>>{};
    await Future.wait([
      _flat(result, strongEtags, annotationSyncDomain, const ['annotations'],
          _fingerprint),
      _flat(result, strongEtags, libraryCatalogDomain,
          const ['shared', 'v1', 'catalog', 'books'], _fingerprint),
      _flat(result, strongEtags, readingStateDomain,
          const ['shared', 'v1', 'reading-state'], _fingerprint),
      _flat(result, strongEtags, groupDomain, const ['shared', 'v1', 'groups'],
          _uuid),
      _flat(result, strongEtags, tagDomain, const ['shared', 'v1', 'tags'],
          _uuid),
      _flat(result, strongEtags, themeDomain, const ['shared', 'v1', 'themes'],
          _uuid),
      _nested(result, strongEtags, readingActivityDomain,
          const ['shared', 'v1', 'reading-activity'], _activityId),
      _nested(result, strongEtags, bookTagDomain,
          const ['shared', 'v1', 'book-tags'], _bookTagId),
    ]);
    return RemoteDocumentIndex(result, strongEtags);
  }

  Future<void> _flat(
    Map<String, Set<String>> result,
    Map<String, Map<String, String>> strongEtags,
    String domain,
    List<String> path,
    String? Function(String fileName) decode,
  ) async {
    final ids = result.putIfAbsent(domain, () => <String>{});
    for (final entry in await list(path)) {
      if (entry.isCollection) continue;
      final id = decode(entry.name);
      if (id != null) {
        ids.add(id);
        if (entry.strongEtag case final etag?) {
          strongEtags.putIfAbsent(domain, () => {})[id] = etag;
        }
      }
    }
  }

  Future<void> _nested(
    Map<String, Set<String>> result,
    Map<String, Map<String, String>> strongEtags,
    String domain,
    List<String> path,
    String? Function(String parent, String fileName) decode,
  ) async {
    final ids = result.putIfAbsent(domain, () => <String>{});
    final parents = (await list(path))
        .where(
            (entry) => entry.isCollection && _fingerprint(entry.name) != null)
        .toList(growable: false);
    await Future.wait(parents.map((parent) async {
      for (final entry in await list([...path, parent.name])) {
        if (entry.isCollection) continue;
        final id = decode(parent.name, entry.name);
        if (id != null) {
          ids.add(id);
          if (entry.strongEtag case final etag?) {
            strongEtags.putIfAbsent(domain, () => {})[id] = etag;
          }
        }
      }
    }));
  }

  static String? _fingerprint(String fileName) {
    final raw = fileName.endsWith('.json')
        ? fileName.substring(0, fileName.length - 5)
        : fileName;
    try {
      return canonicalMd5Fingerprint(raw);
    } on AnnotationProtocolException {
      return null;
    }
  }

  static String? _uuid(String fileName) {
    if (!fileName.endsWith('.json')) return null;
    final raw = fileName.substring(0, fileName.length - 5).toLowerCase();
    return _uuidPattern.hasMatch(raw) ? raw : null;
  }

  static String? _activityId(String fingerprint, String fileName) {
    if (!fileName.endsWith('.json')) return null;
    final day = fileName.substring(0, fileName.length - 5);
    try {
      return readingActivityDocumentId(fingerprint, day);
    } on FormatException {
      return null;
    }
  }

  static String? _bookTagId(String fingerprint, String fileName) {
    final tagId = _uuid(fileName);
    if (tagId == null) return null;
    return bookTagDocumentId(fingerprint, tagId);
  }
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
