import 'dart:convert';

import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeExecutor implements WebDavRequestExecutor {
  final List<(String, Uri, Map<String, String>, List<int>?)> calls = [];
  final List<Object> outcomes;

  FakeExecutor(this.outcomes);

  @override
  Future<Response<List<int>>> execute(String method, Uri uri,
      {Map<String, String> headers = const {}, List<int>? body}) async {
    calls.add((method, uri, headers, body));
    final outcome = outcomes.removeAt(0);
    if (outcome is Response<List<int>>) return outcome;
    throw outcome;
  }
}

Response<List<int>> response(int? status,
        {String? etag,
        String? lockToken,
        String? timeout,
        String? body = ''}) =>
    Response(
        requestOptions: RequestOptions(),
        statusCode: status,
        data: body == null ? null : utf8.encode(body),
        headers: Headers.fromMap({
          if (etag != null) 'etag': [etag],
          if (lockToken != null) 'lock-token': [lockToken],
          if (timeout != null) 'timeout': [timeout],
        }));

ConditionalWebDavTransport transport(FakeExecutor executor,
        {String remoteRoot = 'shared'}) =>
    ConditionalWebDavTransport(
        baseUri: Uri.parse('https://dav.test/base'),
        remoteRoot: remoteRoot,
        executor: executor);

void main() {
  group('collection discovery', () {
    test('PROPFIND returns validated direct children only', () async {
      const xml = '''<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/base/shared/annotations/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response><D:href>/base/shared/annotations/abc.json</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>
  </D:response>
  <D:response><D:href>/base/shared/annotations/books/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response><D:href>/base/shared/annotations/books/nested.json</D:href></D:response>
  <D:response><D:href>/outside/secret.json</D:href></D:response>
</D:multistatus>''';
      final fake = FakeExecutor([response(207, body: xml)]);

      final entries = await transport(fake).list(['annotations']);

      expect(fake.calls.single.$1, 'PROPFIND');
      expect(fake.calls.single.$3['Depth'], '1');
      expect(entries.map((entry) => (entry.name, entry.isCollection)),
          [('abc.json', false), ('books', true)]);
    });

    test('missing collection is empty and malformed XML fails safely',
        () async {
      expect(await transport(FakeExecutor([response(404)])).list(['missing']),
          isEmpty);
      await expectLater(
          transport(FakeExecutor([response(207, body: '<broken>')]))
              .list(['broken']),
          throwsA(isA<WebDavTransportException>()));
    });
  });

  group('GET', () {
    test('returns body and strong ETag from the same 200 response', () async {
      final fake = FakeExecutor([response(200, etag: '"v1"', body: '{"a":1}')]);
      final object = await transport(fake).get(['annotations', 'book.json']);

      expect(utf8.decode(object!.body), '{"a":1}');
      expect(object.etag, '"v1"');
      expect(fake.calls.map((call) => call.$1), ['GET']);
    });

    test('maps 404 to an absent object', () async {
      final fake = FakeExecutor([response(404)]);
      expect(await transport(fake).get(['book.json']), isNull);
    });

    test('rejects weak or missing ETags', () async {
      for (final etag in <String?>['W/"v1"', null]) {
        final fake = FakeExecutor([response(200, etag: etag, body: '{}')]);
        await expectLater(transport(fake).get(['book.json']),
            throwsA(isA<WebDavTransportException>()));
      }
    });

    test('maps malformed and failed responses to transport errors', () async {
      for (final outcome in <Object>[
        response(null),
        response(200, etag: '"v1"', body: null),
        StateError('socket failed'),
      ]) {
        final fake = FakeExecutor([outcome]);
        await expectLater(transport(fake).get(['book.json']),
            throwsA(isA<WebDavTransportException>()));
      }
    });
  });

  group('conditional writes', () {
    test('create uses If-None-Match star', () async {
      final fake = FakeExecutor([response(405), response(201, etag: '"v1"')]);
      final result = await transport(fake, remoteRoot: '')
          .create(['annotations', 'book.json'], utf8.encode('{}'));

      expect(fake.calls.map((call) => call.$1), ['MKCOL', 'PUT']);
      expect(fake.calls.last.$3['If-None-Match'], '*');
      expect(fake.calls.last.$3, isNot(contains('If-Match')));
      expect(result.etag, '"v1"');
    });

    test('replace uses the supplied strong If-Match ETag', () async {
      final fake = FakeExecutor([response(405), response(204, etag: '"v2"')]);
      final result = await transport(fake, remoteRoot: '')
          .replace(['annotations', 'book.json'], utf8.encode('{}'), '"v1"');

      expect(fake.calls.last.$3['If-Match'], '"v1"');
      expect(fake.calls.last.$3, isNot(contains('If-None-Match')));
      expect(result.etag, '"v2"');
    });

    test('replacement rejects a missing or weak strong ETag', () async {
      for (final etag in ['', 'W/"v1"']) {
        final fake = FakeExecutor([]);
        expect(() => transport(fake).replace(['book.json'], [], etag),
            throwsA(isA<WebDavTransportException>()));
        expect(fake.calls, isEmpty);
      }
    });

    test('maps PUT 412 to typed precondition failure', () async {
      final fake = FakeExecutor([response(405), response(412)]);
      await expectLater(
          transport(fake, remoteRoot: '').replace(
              ['annotations', 'book.json'], utf8.encode('{}'), '"old"'),
          throwsA(isA<WebDavPreconditionFailed>()));
      expect(fake.calls.last.$3['If-Match'], '"old"');
    });

    test('never emits DELETE before or after PUT', () async {
      final fake = FakeExecutor([response(405), response(201)]);
      await transport(fake, remoteRoot: '')
          .create(['annotations', 'book.json'], []);
      expect(fake.calls.map((call) => call.$1), isNot(contains('DELETE')));
    });
  });

  group('exclusive create locks', () {
    test('LOCK requests a finite exclusive write lock on a missing object',
        () async {
      final fake = FakeExecutor([
        response(201,
            lockToken: '<opaquelocktoken:created>', timeout: 'Second-37')
      ]);

      final lock = await transport(fake, remoteRoot: '')
          .lock(['book.json'], timeout: const Duration(seconds: 45));

      expect(fake.calls.single.$1, 'LOCK');
      expect(fake.calls.single.$3['Depth'], '0');
      expect(fake.calls.single.$3['Timeout'], 'Second-45');
      expect(utf8.decode(fake.calls.single.$4!), contains('<D:exclusive/>'));
      expect(lock.token, '<opaquelocktoken:created>');
      expect(lock.timeout, const Duration(seconds: 37));
      expect(lock.created, isTrue);
    });

    test('LOCK 200 classifies the target as an existing representation',
        () async {
      final fake = FakeExecutor([
        response(200,
            lockToken: '<opaquelocktoken:existing>', timeout: 'Second-45')
      ]);

      final lock = await transport(fake, remoteRoot: '').lock(['book.json']);

      expect(lock.created, isFalse);
      expect(lock.token, '<opaquelocktoken:existing>');
    });

    test('validates Lock-Token syntax', () async {
      for (final token in <String?>[
        null,
        '',
        'opaquelocktoken:no-brackets',
        '<bad token>',
        '<one><two>'
      ]) {
        final fake = FakeExecutor([response(201, lockToken: token)]);
        await expectLater(transport(fake, remoteRoot: '').lock(['book.json']),
            throwsA(isA<WebDavInvalidLockToken>()));
      }
    });

    test('maps LOCK contention and unsupported responses distinctly', () async {
      await expectLater(
          transport(FakeExecutor([response(423)]), remoteRoot: '')
              .lock(['book.json']),
          throwsA(isA<WebDavLocked>()));
      for (final status in [405, 501]) {
        await expectLater(
            transport(FakeExecutor([response(status)]), remoteRoot: '')
                .lock(['book.json']),
            throwsA(isA<WebDavLockUnsupported>()));
      }
    });

    test('locked PUT uses only the WebDAV If lock-token condition', () async {
      final fake = FakeExecutor([response(201, etag: '"v1"')]);
      final lock = const WebDavLock(
          '<opaquelocktoken:write>', Duration(seconds: 45),
          created: true);

      final result = await transport(fake, remoteRoot: '')
          .putLocked(['book.json'], utf8.encode('{}'), lock);

      expect(fake.calls.single.$3['If'], '(<opaquelocktoken:write>)');
      expect(fake.calls.single.$3, isNot(contains('If-None-Match')));
      expect(fake.calls.single.$3, isNot(contains('If-Match')));
      expect(result.etag, '"v1"');
    });

    test('UNLOCK sends the validated token and reports cleanup failure',
        () async {
      final lock = const WebDavLock(
          '<opaquelocktoken:cleanup>', Duration(seconds: 45),
          created: true);
      final success = FakeExecutor([response(204)]);
      await transport(success, remoteRoot: '').unlock(['book.json'], lock);
      expect(success.calls.single.$1, 'UNLOCK');
      expect(success.calls.single.$3['Lock-Token'], lock.token);

      await expectLater(
          transport(FakeExecutor([response(409)]), remoteRoot: '')
              .unlock(['book.json'], lock),
          throwsA(isA<WebDavUnlockFailed>()));
    });

    test('lock-conditioned PUT failures are distinct and never use DELETE',
        () async {
      final fake = FakeExecutor([response(500)]);
      await expectLater(
          transport(fake, remoteRoot: '').putLocked(
              ['book.json'],
              [],
              const WebDavLock(
                  '<opaquelocktoken:failed>', Duration(seconds: 45),
                  created: true)),
          throwsA(isA<WebDavLockPutFailed>()));
      expect(fake.calls.map((call) => call.$1), isNot(contains('DELETE')));
    });
  });

  group('paths and collections', () {
    test('matches Lingua annotation root and lowercase MD5 convention', () {
      const upper = '0123456789ABCDEF0123456789ABCDEF';
      final uri = transport(FakeExecutor([]), remoteRoot: 'Lingua Reader')
          .objectUri(annotationDocumentRemotePath(upper));
      expect(uri.toString(),
          'https://dav.test/base/Lingua%20Reader/annotations/0123456789abcdef0123456789abcdef.json');
    });

    test('validates object path segments before requests', () async {
      for (final path in <List<String>>[
        [],
        [''],
        ['.'],
        ['..'],
        ['a/b'],
        [r'a\b'],
      ]) {
        final fake = FakeExecutor([]);
        expect(() => transport(fake).objectUri(path),
            throwsA(isA<WebDavTransportException>()));
      }
    });

    test('encodes safe path segments', () {
      final uri = transport(FakeExecutor([]))
          .objectUri(['annotations', 'book name.json']);
      expect(uri.toString(),
          'https://dav.test/base/shared/annotations/book%20name.json');
    });

    test('MKCOL accepts existing and redirect collection responses', () async {
      final fake = FakeExecutor([
        response(301),
        response(405),
        response(201),
      ]);
      await transport(fake, remoteRoot: '').create(['a', 'b', 'file.json'], []);
      expect(fake.calls.map((call) => call.$1), ['MKCOL', 'MKCOL', 'PUT']);
    });

    test('MKCOL failure is typed and prevents PUT', () async {
      final fake = FakeExecutor([response(500)]);
      await expectLater(
          transport(fake, remoteRoot: '').create(['a', 'file.json'], []),
          throwsA(isA<WebDavTransportException>()));
      expect(fake.calls.map((call) => call.$1), ['MKCOL']);
    });
  });
}
