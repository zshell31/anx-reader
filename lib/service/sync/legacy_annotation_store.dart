import 'package:anx_reader/dao/base_dao.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';

/// Read-only migration input from the retired native annotation table.
///
/// The local integer [rowId] and [canonicalIdHint] are migration evidence only;
/// neither is exposed to current annotation UI, repository, or renderer code.
class LegacyAnnotationRow {
  final int? rowId;
  final int localBookId;
  final String selectedText;
  final String cfi;
  final String chapter;
  final String type;
  final String color;
  final double? bookmarkPercentage;
  final String? personalNote;
  final String? canonicalIdHint;
  final DateTime? createTime;
  final DateTime updateTime;

  const LegacyAnnotationRow({
    required this.rowId,
    required this.localBookId,
    required this.selectedText,
    required this.cfi,
    required this.chapter,
    required this.type,
    required this.color,
    this.bookmarkPercentage,
    required this.personalNote,
    required this.canonicalIdHint,
    required this.createTime,
    required this.updateTime,
  });

  factory LegacyAnnotationRow.fromDatabase(Map<String, Object?> row) {
    final created = DateTime.tryParse(row['create_time'] as String? ?? '');
    final updated = DateTime.tryParse(row['update_time'] as String? ?? '') ??
        created ??
        DateTime.utc(1970);
    return LegacyAnnotationRow(
      rowId: row['id'] as int?,
      localBookId: row['book_id'] as int,
      selectedText: row['content'] as String? ?? '',
      cfi: row['cfi'] as String? ?? '',
      chapter: row['chapter'] as String? ?? '',
      type: row['type'] as String? ?? '',
      color: row['color'] as String? ?? '',
      bookmarkPercentage: _legacyBookmarkPercentage(
        row['type'] as String? ?? '',
        row['color'],
      ),
      personalNote: row['reader_note'] as String?,
      canonicalIdHint: row['shared_annotation_id'] as String?,
      createTime: created,
      updateTime: updated,
    );
  }
}

double? _legacyBookmarkPercentage(String type, Object? rawValue) {
  if (type != 'bookmark') return null;
  final value = rawValue is num
      ? rawValue.toDouble()
      : double.tryParse(rawValue?.toString() ?? '');
  return value != null && value.isFinite && value >= 0 && value <= 1
      ? value
      : null;
}

abstract interface class LegacyAnnotationStore {
  Future<List<LegacyAnnotationRow>> readAnnotations();

  Future<Book?> readBook(int localBookId);
}

/// The sole runtime reader of the legacy `tb_notes` annotation table.
///
/// This adapter deliberately exposes no insert, update, delete, or binding API.
class DatabaseLegacyAnnotationStore extends BaseDao
    implements LegacyAnnotationStore {
  final BookDao books;

  DatabaseLegacyAnnotationStore({BookDao? books}) : books = books ?? BookDao();

  @override
  Future<List<LegacyAnnotationRow>> readAnnotations() => queryList(
        'tb_notes',
        columns: const [
          'id',
          'book_id',
          'content',
          'cfi',
          'chapter',
          'type',
          'color',
          'reader_note',
          'shared_annotation_id',
          'create_time',
          'update_time',
        ],
        mapper: LegacyAnnotationRow.fromDatabase,
        where: "type IN ('highlight', 'underline', 'bookmark')",
        orderBy: 'book_id, id',
      );

  @override
  Future<Book?> readBook(int localBookId) async {
    try {
      return await books.selectBookById(localBookId);
    } on StateError {
      return null;
    }
  }
}
