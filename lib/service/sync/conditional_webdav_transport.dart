import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class WebDavTransportException implements Exception {
  final String message;
  final int? status;
  const WebDavTransportException(this.message, {this.status});
  @override
  String toString() => 'WebDavTransportException: $message';
}

class WebDavPreconditionFailed extends WebDavTransportException {
  const WebDavPreconditionFailed()
      : super('remote object changed', status: 412);
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

class ConditionalWebDavTransport {
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
    if (all.any((x) =>
        x.isEmpty ||
        x == '.' ||
        x == '..' ||
        x.contains('/') ||
        x.contains(r'\'))) {
      throw const WebDavTransportException('unsafe WebDAV path segment');
    }
    return baseUri.replace(pathSegments: [
      ...baseUri.pathSegments.where((x) => x.isNotEmpty),
      ...all
    ]);
  }

  Future<WebDavObject?> get(List<String> path) async {
    final response = await _execute('GET', objectUri(path), headers: _headers);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200 || response.data == null) {
      throw WebDavTransportException('GET failed', status: response.statusCode);
    }
    final etag = _strongEtag(response.headers.value('etag'));
    return WebDavObject(Uint8List.fromList(response.data!), etag);
  }

  Future<WebDavWriteResult> create(List<String> path, List<int> body) =>
      _put(path, body, {'If-None-Match': '*'});
  Future<WebDavWriteResult> replace(
          List<String> path, List<int> body, String strongEtag) =>
      _put(path, body, {'If-Match': _strongEtag(strongEtag)});

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
      {Map<String, String> headers = const {}, List<int>? body}) async {
    try {
      return await executor.execute(method, uri, headers: headers, body: body);
    } catch (error) {
      throw WebDavTransportException('$method request failed: $error');
    }
  }

  String _strongEtag(String? value) {
    if (value == null || !RegExp(r'^"[^"\r\n]+"$').hasMatch(value)) {
      throw const WebDavTransportException('missing or invalid strong ETag');
    }
    return value;
  }
}
