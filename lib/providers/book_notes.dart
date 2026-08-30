import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/models/book_notes_state.dart';
import 'package:anx_reader/providers/bookmark.dart';
import 'package:anx_reader/providers/notes_statistics.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'book_notes.g.dart';

@riverpod
class BookNotesController extends _$BookNotesController {
  NotesSortMode _viewSortFromPrefs() {
    final prefs = Prefs();
    return NotesSortMode(
      field: prefs.notesViewSortFieldPref,
      direction: prefs.notesViewSortDirectionPref,
    );
  }

  NotesSortMode _exportSortFromPrefs() {
    final prefs = Prefs();
    return NotesSortMode(
      field: prefs.notesExportSortFieldPref,
      direction: prefs.notesExportSortDirectionPref,
    );
  }

  void _persistViewSort(NotesSortMode mode) {
    final prefs = Prefs();
    prefs.notesViewSortFieldPref = mode.field;
    prefs.notesViewSortDirectionPref = mode.direction;
  }

  void _persistExportSort(NotesSortMode mode) {
    final prefs = Prefs();
    prefs.notesExportSortFieldPref = mode.field;
    prefs.notesExportSortDirectionPref = mode.direction;
  }

  @override
  Future<BookNotesState> build(String fingerprint) async {
    ref.listen(canonicalAnnotationBooksProvider, (previous, next) {
      if (previous?.hasValue == true && next.hasValue) refresh();
    });
    final annotationBook =
        await canonicalAnnotationCatalog.readBook(fingerprint);
    if (annotationBook == null) {
      throw StateError('Canonical annotation document was not found');
    }
    return _createState(
      book: annotationBook,
      annotations: annotationBook.annotations,
    );
  }

  Future<void> refresh() async {
    final current = state.valueOrNull;
    try {
      final annotationBook =
          await canonicalAnnotationCatalog.readBook(fingerprint);
      if (annotationBook == null) {
        throw StateError('Canonical annotation document was not found');
      }
      state = AsyncValue.data(
        _createState(
          book: annotationBook,
          annotations: annotationBook.annotations,
          previous: current,
        ),
      );
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  void toggleSelection(AnnotationUiModel annotation) {
    final current = state.valueOrNull;
    if (current == null) return;
    final id = annotation.ref.annotationId;
    final updatedSelection = Set<String>.from(current.selectedAnnotationIds);
    if (updatedSelection.contains(id)) {
      updatedSelection.remove(id);
    } else {
      updatedSelection.add(id);
    }
    _emit(
      current.copyWith(
        selectedAnnotationIds: updatedSelection,
      ),
    );
  }

  void clearSelection() {
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.selectedAnnotationIds.isEmpty) return;
    _emit(
      current.copyWith(
        selectedAnnotationIds: {},
      ),
    );
  }

  void selectAllVisible() {
    final current = state.valueOrNull;
    if (current == null) return;
    final ids = current.visibleAnnotations
        .map((annotation) => annotation.ref.annotationId)
        .toSet();
    _emit(
      current.copyWith(selectedAnnotationIds: ids),
    );
  }

  void toggleShowBookmarks() {
    final current = state.valueOrNull;
    if (current == null) return;
    final next = current.copyWith(showBookmarks: !current.showBookmarks);
    _emit(
      next.copyWith(
        visibleAnnotations: _filterAndSort(
          next.allAnnotations,
          next.enabledTypeColors,
          next.showBookmarks,
          next.viewSortMode,
        ),
      ),
    );
  }

  void toggleTypeColors(String type) {
    final current = state.valueOrNull;
    if (current == null) return;
    final updated = Set<String>.from(current.enabledTypeColors);
    for (final color in notesColors) {
      final key = _filterKey(type, color);
      if (updated.contains(key)) {
        updated.remove(key);
      } else {
        updated.add(key);
      }
    }
    _emit(
      _recomputeVisible(
        current.copyWith(enabledTypeColors: updated),
      ),
    );
  }

  void toggleTypeColor(String type, String color) {
    final current = state.valueOrNull;
    if (current == null) return;
    final updated = Set<String>.from(current.enabledTypeColors);
    final key = _filterKey(type, color);
    if (updated.contains(key)) {
      updated.remove(key);
    } else {
      updated.add(key);
    }
    _emit(
      _recomputeVisible(
        current.copyWith(enabledTypeColors: updated),
      ),
    );
  }

  void resetFilters() {
    final current = state.valueOrNull;
    if (current == null) return;
    final defaults = NoteFilterDefaults.initialTypeColorSelection();
    _emit(
      _recomputeVisible(
        current.copyWith(
          enabledTypeColors: defaults,
          showBookmarks: true,
        ),
      ),
    );
  }

  void toggleViewSort(NotesSortField field) {
    final current = state.valueOrNull;
    if (current == null) return;
    final newMode = current.viewSortMode.field == field
        ? current.viewSortMode.toggleDirection()
        : current.viewSortMode.copyWith(field: field).toggleDirection();
    _persistViewSort(newMode);
    _emit(
      current.copyWith(
        viewSortMode: newMode,
        visibleAnnotations: _filterAndSort(
          current.allAnnotations,
          current.enabledTypeColors,
          current.showBookmarks,
          newMode,
        ),
      ),
    );
  }

  void setExportSortField(NotesSortField field) {
    final current = state.valueOrNull;
    if (current == null) return;
    final newMode = current.exportSortMode.copyWith(field: field);
    _persistExportSort(newMode);
    _emit(
      current.copyWith(exportSortMode: newMode),
    );
  }

  void toggleExportSortDirection() {
    final current = state.valueOrNull;
    if (current == null) return;
    final updated = current.exportSortMode.toggleDirection();
    _persistExportSort(updated);
    _emit(
      current.copyWith(
        exportSortMode: updated,
      ),
    );
  }

  Future<void> updateAnnotation(
    AnnotationRef ref, {
    String? personalNote,
    String? type,
    String? color,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (personalNote != null) {
      await annotationRepository.setPersonalNote(ref, personalNote);
    }
    if (type != null && color != null) {
      await annotationRepository.updatePresentation(ref, type, color);
    }
    await refresh();
  }

  Future<void> deleteAnnotations(
      Iterable<AnnotationUiModel> annotations) async {
    final current = state.valueOrNull;
    for (final annotation in annotations) {
      await annotationRepository.tombstoneAnnotation(annotation.ref);
    }

    final localBook = current?.book.localBook;
    if (localBook != null) {
      ref.read(BookmarkProvider(localBook.id).notifier).refreshBookmarks();
    }

    await refresh();
  }

  List<AnnotationUiModel> annotationsForExport({
    required bool selectedOnly,
    List<AnnotationUiModel>? custom,
  }) {
    final current = state.valueOrNull;
    if (current == null) {
      return const [];
    }
    final baseList = custom ??
        (selectedOnly ? current.selectedAnnotations : current.allAnnotations);
    return _sortAnnotations(baseList, current.exportSortMode);
  }

  BookNotesState _recomputeVisible(BookNotesState state) {
    return state.copyWith(
      visibleAnnotations: _filterAndSort(
        state.allAnnotations,
        state.enabledTypeColors,
        state.showBookmarks,
        state.viewSortMode,
      ),
    );
  }

  BookNotesState _createState({
    required AnnotationBookUiModel book,
    required List<AnnotationUiModel> annotations,
    BookNotesState? previous,
  }) {
    final enabledTypeColors = previous?.enabledTypeColors ??
        NoteFilterDefaults.initialTypeColorSelection();
    final showBookmarks = previous?.showBookmarks ?? true;
    final viewSort = previous?.viewSortMode ?? _viewSortFromPrefs();
    final exportSort = previous?.exportSortMode ?? _exportSortFromPrefs();
    final validSelection = (previous?.selectedAnnotationIds ?? {})
        .where((id) =>
            annotations.any((annotation) => annotation.ref.annotationId == id))
        .toSet();
    return BookNotesState(
      book: book,
      allAnnotations: annotations,
      visibleAnnotations: _filterAndSort(
        annotations,
        enabledTypeColors,
        showBookmarks,
        viewSort,
      ),
      viewSortMode: viewSort,
      exportSortMode: exportSort,
      showBookmarks: showBookmarks,
      enabledTypeColors: enabledTypeColors,
      selectedAnnotationIds: validSelection,
    );
  }

  void _emit(BookNotesState newState) {
    state = AsyncValue.data(newState);
  }
}

String _filterKey(String type, String color) => '$type#${color.toUpperCase()}';

List<AnnotationUiModel> _filterAndSort(
  List<AnnotationUiModel> annotations,
  Set<String> enabledTypeColors,
  bool showBookmarks,
  NotesSortMode sortMode,
) {
  final filtered = <AnnotationUiModel>[];
  for (final annotation in annotations) {
    if (annotation.motivation == AnnotationMotivation.bookmark) {
      if (showBookmarks) {
        filtered.add(annotation);
      }
      continue;
    }
    final prefs = Prefs();
    final presentation = annotation.effectivePresentation(
      defaultStyle: prefs.annotationType,
      defaultColor: prefs.annotationColor,
    );
    final style = presentation.style.name;
    final color = presentation.color;
    final key = _filterKey(style, color);
    if (enabledTypeColors.contains(key)) {
      filtered.add(annotation);
    }
  }

  return _sortAnnotations(filtered, sortMode);
}

List<AnnotationUiModel> _sortAnnotations(
    List<AnnotationUiModel> annotations, NotesSortMode mode) {
  final sorted = List<AnnotationUiModel>.from(annotations);
  sorted.sort((a, b) {
    int comparison;
    if (mode.field == NotesSortField.createdTime) {
      comparison = _compareDate(a.createdAt, b.createdAt);
    } else {
      comparison = _compareCfi(a.epubCfi ?? '', b.epubCfi ?? '');
    }

    if (mode.direction == SortDirection.asc) {
      return comparison;
    }
    return -comparison;
  });
  return sorted;
}

int _compareDate(DateTime? a, DateTime? b) {
  final aTime = a ?? DateTime.fromMillisecondsSinceEpoch(0);
  final bTime = b ?? DateTime.fromMillisecondsSinceEpoch(0);
  return aTime.compareTo(bTime);
}

int _compareCfi(String a, String b) {
  List<String> replace(String str) {
    return str
        .replaceAll('epubcfi(/', '')
        .replaceAll(')', '')
        .replaceAll(',', '')
        .split('/');
  }

  final componentsA = replace(a);
  final componentsB = replace(b);

  for (int i = 0; i < componentsA.length && i < componentsB.length; i++) {
    final compA = componentsA[i];
    final compB = componentsB[i];

    if (compA.isEmpty || compB.isEmpty) {
      continue;
    }
    if (compA != compB) {
      if (compA.contains(':') && compB.contains(':')) {
        final locA = int.tryParse(compA.split(':')[1]) ?? 0;
        final locB = int.tryParse(compB.split(':')[1]) ?? 0;
        return locA.compareTo(locB);
      } else {
        final numA = int.tryParse(compA.replaceAll('!', '')) ?? 0;
        final numB = int.tryParse(compB.replaceAll('!', '')) ?? 0;
        return numA.compareTo(numB);
      }
    }
  }

  return componentsA.length.compareTo(componentsB.length);
}
