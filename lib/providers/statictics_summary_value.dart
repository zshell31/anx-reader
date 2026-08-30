import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'statictics_summary_value.g.dart';

enum StatisticType {
  totalBooks,
  totalDates,
  totalNotes,
}

@riverpod
class StaticticsSummaryValue extends _$StaticticsSummaryValue {
  @override
  Future<int> build(StatisticType type) async {
    return _getStatistic(type);
  }

  Future<int> _getStatistic(StatisticType type) async {
    switch (type) {
      case StatisticType.totalBooks:
        return await readingTimeDao.selectTotalNumberOfBook();
      case StatisticType.totalDates:
        return await readingTimeDao.selectTotalNumberOfDate();
      case StatisticType.totalNotes:
        final books = await canonicalAnnotationCatalog.readAll();
        return books.fold<int>(
            0, (count, book) => count + book.annotations.length);
    }
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = AsyncValue.data(await _getStatistic(type));
  }
}
