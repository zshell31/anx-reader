import 'dart:convert';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeExecutor implements WebDavRequestExecutor {
  final List<(String, Uri, Map<String, String>)> calls = [];
  final List<Response<List<int>>> responses;
  FakeExecutor(this.responses);
  @override
  Future<Response<List<int>>> execute(String method, Uri uri,
      {Map<String, String> headers = const {}, List<int>? body}) async {
    calls.add((method, uri, headers));
    return responses.removeAt(0);
  }
}

Response<List<int>> response(int status, {String? etag, String body = ''}) =>
    Response(
        requestOptions: RequestOptions(),
        statusCode: status,
        data: utf8.encode(body),
        headers: Headers.fromMap({
          if (etag != null) 'etag': [etag]
        }));

void main() {
  test('GET returns body and strong ETag from one response', () async {
    final fake = FakeExecutor([response(200, etag: '"v1"', body: '{}')]);
    final transport = ConditionalWebDavTransport(
        baseUri: Uri.parse('https://dav.test/root'),
        remoteRoot: 'shared',
        executor: fake);
    final object = await transport.get(['annotations', 'book.json']);
    expect(utf8.decode(object!.body), '{}');
    expect(object.etag, '"v1"');
    expect(fake.calls.map((x) => x.$1), ['GET']);
  });
  test('conditional PUT is direct and maps 412', () async {
    final fake = FakeExecutor([response(405), response(412)]);
    final transport = ConditionalWebDavTransport(
        baseUri: Uri.parse('https://dav.test'), remoteRoot: '', executor: fake);
    await expectLater(
        transport
            .replace(['annotations', 'book.json'], utf8.encode('{}'), '"old"'),
        throwsA(isA<WebDavPreconditionFailed>()));
    expect(fake.calls.map((x) => x.$1), ['MKCOL', 'PUT']);
    expect(fake.calls.last.$3['If-Match'], '"old"');
    expect(fake.calls.any((x) => x.$1 == 'DELETE'), isFalse);
  });
  test('create uses If-None-Match star', () async {
    final fake = FakeExecutor([response(405), response(201)]);
    final transport = ConditionalWebDavTransport(
        baseUri: Uri.parse('https://dav.test'), remoteRoot: '', executor: fake);
    await transport.create(['annotations', 'book.json'], utf8.encode('{}'));
    expect(fake.calls.last.$3['If-None-Match'], '*');
  });
  test('rejects weak ETags and unsafe paths', () async {
    final transport = ConditionalWebDavTransport(
        baseUri: Uri.parse('https://dav.test'),
        remoteRoot: '',
        executor: FakeExecutor([response(200, etag: 'W/"v1"')]));
    await expectLater(
        transport.get(['book.json']), throwsA(isA<WebDavTransportException>()));
    expect(() => transport.objectUri(['..']),
        throwsA(isA<WebDavTransportException>()));
  });
}
