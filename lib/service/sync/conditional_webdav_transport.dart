import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

class WebDavTransportException implements Exception {
  final String message;
  final int? status;
  const WebDavTransportException(this.message, {this.status});
  @override
  String toString() => 'WebDavTransportException'
      '${status == null ? '' : '(HTTP $status)'}: $message';
}

class WebDavPreconditionFailed extends WebDavTransportException {
  const WebDavPreconditionFailed()
      : super('remote object changed', status: 412);
}

class WebDavLocked extends WebDavTransportException {
  const WebDavLocked() : super('remote object is locked', status: 423);
}

class WebDavLockUnsupported extends WebDavTransportException {
  const WebDavLockUnsupported(int? status)
      : super('exclusive WebDAV LOCK is unsupported', status: status);
}

class WebDavInvalidLockToken extends WebDavTransportException {
  const WebDavInvalidLockToken()
      : super('LOCK response has a missing or invalid Lock-Token');
}

class WebDavUnlockFailed extends WebDavTransportException {
  const WebDavUnlockFailed(int? status)
      : super('UNLOCK cleanup failed', status: status);
}

class WebDavLockPutFailed extends WebDavTransportException {
  const WebDavLockPutFailed(int? status)
      : super('lock-conditioned PUT failed', status: status);
}

class WebDavObject {
  final Uint8List body;
  final String etag;
  const WebDavObject(this.body, this.etag);
}

class WebDavWriteResult {
  final String? etag;
  const WebDavWriteResult(this.etag);
}

class WebDavLock {
  final String token;
  final Duration? timeout;
  final bool created;
  const WebDavLock(this.token, this.timeout, {required this.created});
}

class WebDavCollectionEntry {
  final String name;
  final bool isCollection;
  const WebDavCollectionEntry(this.name, {required this.isCollection});
}

abstract interface class AnnotationWebDavTransport {
  Future<WebDavObject?> get(List<String> path);
  Future<WebDavWriteResult> create(List<String> path, List<int> body);
  Future<WebDavWriteResult> replace(
      List<String> path, List<int> body, String strongEtag);
  Future<WebDavLock> lock(List<String> path,
      {Duration timeout = const Duration(seconds: 45)});
  Future<WebDavWriteResult> putLocked(
      List<String> path, List<int> body, WebDavLock lock);
  Future<void> unlock(List<String> path, WebDavLock lock);
}

List<String> annotationDocumentRemotePath(String fingerprint) => [
      'annotations',
      '${canonicalMd5Fingerprint(fingerprint)}.json',
    ];

abstract interface class WebDavRequestExecutor {
  Future<Response<List<int>>> execute(String method, Uri uri,
      {Map<String, String> headers = const {}, List<int>? body});
}

class DioWebDavRequestExecutor implements WebDavRequestExecutor {
  final Dio dio;
  DioWebDavRequestExecutor(this.dio);
  @override
  Future<Response<List<int>>> execute(String method, Uri uri,
          {Map<String, String> headers = const {}, List<int>? body}) =>
      dio.requestUri<List<int>>(uri,
          data: body,
          options: Options(
              method: method,
              headers: headers,
              responseType: ResponseType.bytes,
              validateStatus: (_) => true));
}

class ConditionalWebDavTransport implements AnnotationWebDavTransport {
  final Uri baseUri;
  final String remoteRoot;
  final WebDavRequestExecutor executor;
  final String? username;
  final String? password;
  ConditionalWebDavTransport(
      {required this.baseUri,
      required this.remoteRoot,
      required this.executor,
      this.username,
      this.password});

  Map<String, String> get _headers => {
        if (username != null)
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}',
      };

  Uri objectUri(List<String> segments) {
    if (segments.isEmpty) {
      throw const WebDavTransportException('WebDAV object path is empty');
    }
    final all = [
      ...remoteRoot.split('/').where((x) => x.isNotEmpty),
      ...segments
    ];
    if (all.any((x) => !_safeSegment(x))) {
      throw const WebDavTransportException('unsafe WebDAV path segment');
    }
    return baseUri.replace(pathSegments: [
      ...baseUri.pathSegments.where((x) => x.isNotEmpty),
      ...all
    ]);
  }

  bool _safeSegment(String value) =>
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains(r'\');

  @override
  Future<WebDavObject?> get(List<String> path) async {
    final response = await _execute('GET', objectUri(path), headers: _headers);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200 || response.data == null) {
      throw WebDavTransportException('GET failed', status: response.statusCode);
    }
    final etag = _strongEtag(response.headers.value('etag'));
    return WebDavObject(Uint8List.fromList(response.data!), etag);
  }

  /// Lists direct children only. A missing collection is treated as empty.
  Future<List<WebDavCollectionEntry>> list(List<String> path) async {
    final collectionUri = objectUri(path);
    final response = await _execute('PROPFIND', collectionUri,
        headers: {
          ..._headers,
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        body: utf8.encode(_propfindBody),
        sensitive: true);
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 207 || response.data == null) {
      throw WebDavTransportException('PROPFIND failed',
          status: response.statusCode);
    }
    try {
      final document = XmlDocument.parse(utf8.decode(response.data!));
      final parentSegments = collectionUri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList(growable: false);
      final entries = <String, WebDavCollectionEntry>{};
      for (final item in document.descendants.whereType<XmlElement>().where(
            (element) => element.name.local == 'response',
          )) {
        final hrefs = item.descendants.whereType<XmlElement>().where(
              (element) => element.name.local == 'href',
            );
        if (hrefs.isEmpty) continue;
        final href = hrefs.first.innerText.trim();
        if (href.isEmpty) continue;
        final childSegments = Uri.parse(href)
            .pathSegments
            .where((segment) => segment.isNotEmpty)
            .toList(growable: false);
        if (childSegments.length != parentSegments.length + 1) continue;
        var sameParent = true;
        for (var index = 0; index < parentSegments.length; index++) {
          if (childSegments[index] != parentSegments[index]) {
            sameParent = false;
            break;
          }
        }
        if (!sameParent) continue;
        final name = childSegments.last;
        if (!_safeSegment(name)) continue;
        final isCollection = item.descendants
            .whereType<XmlElement>()
            .any((element) => element.name.local == 'collection');
        entries[name] = WebDavCollectionEntry(name, isCollection: isCollection);
      }
      final result = entries.values.toList()
        ..sort((left, right) => left.name.compareTo(right.name));
      return result;
    } on XmlParserException {
      throw const WebDavTransportException('invalid PROPFIND response');
    } on FormatException {
      throw const WebDavTransportException('invalid PROPFIND response');
    }
  }

  @override
  Future<WebDavWriteResult> create(List<String> path, List<int> body) =>
      _put(path, body, {'If-None-Match': '*'});
  @override
  Future<WebDavWriteResult> replace(
          List<String> path, List<int> body, String strongEtag) =>
      _put(path, body, {'If-Match': _strongEtag(strongEtag)});

  @override
  Future<WebDavLock> lock(List<String> path,
      {Duration timeout = const Duration(seconds: 45)}) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
    final uri = objectUri(path);
    await _ensureCollections(path.sublist(0, path.length - 1));
    final response = await _execute('LOCK', uri,
        headers: {
          ..._headers,
          'Content-Type': 'application/xml; charset=utf-8',
          'Depth': '0',
          'Timeout': 'Second-${timeout.inSeconds}',
        },
        body: utf8.encode(_exclusiveWriteLockBody));
    if (response.statusCode == 423) throw const WebDavLocked();
    if (response.statusCode == 405 || response.statusCode == 501) {
      throw WebDavLockUnsupported(response.statusCode);
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw WebDavTransportException('LOCK failed',
          status: response.statusCode);
    }
    final token = _lockToken(response.headers.value('lock-token'));
    return WebDavLock(token, _lockTimeout(response.headers.value('timeout')),
        created: response.statusCode == 201);
  }

  @override
  Future<WebDavWriteResult> putLocked(
      List<String> path, List<int> body, WebDavLock lock) async {
    final response = await _execute('PUT', objectUri(path),
        body: body,
        headers: {
          ..._headers,
          'If': '(${lock.token})',
          'Content-Type': 'application/json; charset=utf-8',
        },
        sensitive: true);
    if (response.statusCode != 200 &&
        response.statusCode != 201 &&
        response.statusCode != 204) {
      throw WebDavLockPutFailed(response.statusCode);
    }
    final etag = response.headers.value('etag');
    return WebDavWriteResult(etag == null ? null : _strongEtag(etag));
  }

  @override
  Future<void> unlock(List<String> path, WebDavLock lock) async {
    final response = await _execute('UNLOCK', objectUri(path),
        headers: {
          ..._headers,
          'Lock-Token': lock.token,
        },
        sensitive: true);
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw WebDavUnlockFailed(response.statusCode);
    }
  }

  Future<WebDavWriteResult> _put(
      List<String> path, List<int> body, Map<String, String> condition) async {
    final uri = objectUri(path);
    await _ensureCollections(path.sublist(0, path.length - 1));
    final response = await _execute('PUT', uri, body: body, headers: {
      ..._headers,
      ...condition,
      'Content-Type': 'application/json; charset=utf-8'
    });
    if (response.statusCode == 412) throw const WebDavPreconditionFailed();
    if (response.statusCode != 200 &&
        response.statusCode != 201 &&
        response.statusCode != 204) {
      throw WebDavTransportException('PUT failed', status: response.statusCode);
    }
    final etag = response.headers.value('etag');
    return WebDavWriteResult(etag == null ? null : _strongEtag(etag));
  }

  Future<void> _ensureCollections(List<String> path) async {
    for (var index = 1; index <= path.length; index++) {
      final response = await _execute(
          'MKCOL', objectUri(path.take(index).toList()),
          headers: _headers);
      if (![200, 201, 204, 301, 405].contains(response.statusCode)) {
        throw WebDavTransportException('MKCOL failed',
            status: response.statusCode);
      }
    }
  }

  Future<Response<List<int>>> _execute(String method, Uri uri,
      {Map<String, String> headers = const {},
      List<int>? body,
      bool sensitive = false}) async {
    try {
      return await executor.execute(method, uri, headers: headers, body: body);
    } catch (error) {
      throw WebDavTransportException(sensitive
          ? '$method request failed'
          : '$method request failed: $error');
    }
  }

  String _strongEtag(String? value) {
    if (value == null || !RegExp(r'^"[^"\r\n]+"$').hasMatch(value)) {
      throw const WebDavTransportException('missing or invalid strong ETag');
    }
    return value;
  }

  String _lockToken(String? value) {
    final token = value?.trim();
    if (token == null || !RegExp(r'^<[^<>\s\r\n]+>$').hasMatch(token)) {
      throw const WebDavInvalidLockToken();
    }
    return token;
  }

  Duration? _lockTimeout(String? value) {
    final timeout = value?.trim();
    if (timeout == null || timeout.toLowerCase() == 'infinite') return null;
    final match =
        RegExp(r'^Second-(\d+)$', caseSensitive: false).firstMatch(timeout);
    final seconds = match == null ? null : int.tryParse(match.group(1)!);
    return seconds == null ? null : Duration(seconds: seconds);
  }
}

const _exclusiveWriteLockBody = '''<?xml version="1.0" encoding="utf-8"?>
<D:lockinfo xmlns:D="DAV:">
  <D:lockscope><D:exclusive/></D:lockscope>
  <D:locktype><D:write/></D:locktype>
</D:lockinfo>''';

const _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop><D:resourcetype/></D:prop>
</D:propfind>''';
