import 'package:anx_reader/models/book_notes_state.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:flutter_test/flutter_test.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const timestamp = '2026-08-30T10:00:00.000Z';

void main() {
  test('canonical UUID is list and multiselect identity for same CFI', () {
    final annotations = const CanonicalAnnotationReadAdapter().read({
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
      },
      'annotations': [
        _annotation('first'),
        _annotation('second'),
      ],
    });
    final state = BookNotesState(
      book: AnnotationBookUiModel(
        fingerprint: fingerprint,
        title: 'Book',
        author: '',
        localBook: null,
        annotations: annotations,
      ),
      allAnnotations: annotations,
      visibleAnnotations: annotations,
      viewSortMode: const NotesSortMode(
        field: NotesSortField.cfi,
        direction: SortDirection.asc,
      ),
      exportSortMode: const NotesSortMode(
        field: NotesSortField.createdTime,
        direction: SortDirection.desc,
      ),
      showBookmarks: true,
      enabledTypeColors: const {},
      selectedAnnotationIds: const {'second'},
    );

    expect(state.allAnnotations, hasLength(2));
    expect(state.allAnnotations.map((item) => item.epubCfi).toSet(),
        {'epubcfi(/6/2!/4/2)'});
    expect(state.selectedAnnotations.single.ref.annotationId, 'second');
  });
}

Map<String, dynamic> _annotation(String id) => {
      'id': id,
      'motivation': 'selection',
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'target': {
        'selectedText': id,
        'selectors': [
          {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2!/4/2)'}
        ],
      },
      'enrichments': <Object>[],
    };
