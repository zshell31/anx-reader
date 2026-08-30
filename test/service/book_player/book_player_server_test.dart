import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contentTypeForFoliateAsset', () {
    test('serves JavaScript modules with an executable MIME type', () {
      expect(
        contentTypeForFoliateAsset('/foliate-js/src/book.js'),
        'application/javascript',
      );
      expect(
        contentTypeForFoliateAsset('/foliate-js/src/selection-session.mjs'),
        'application/javascript',
      );
    });

    test('preserves reader asset MIME mappings and binary fallback', () {
      expect(contentTypeForFoliateAsset('/foliate-js/index.html'), 'text/html');
      expect(contentTypeForFoliateAsset('/foliate-js/app.css'), 'text/css');
      expect(
        contentTypeForFoliateAsset('/foliate-js/data.json'),
        'application/json',
      );
      expect(
        contentTypeForFoliateAsset('/foliate-js/font.woff2'),
        'application/octet-stream',
      );
    });
  });
}
