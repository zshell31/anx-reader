import 'dart:convert';

import 'package:anx_reader/models/full_text_translation_cache.dart';

class TranslationCacheMergeResult {
  const TranslationCacheMergeResult({
    required this.entries,
    required this.hasIdentityConflict,
  });

  final List<TranslationCacheEntry> entries;
  final bool hasIdentityConflict;
}

class TranslationCacheDeduplicationResult {
  const TranslationCacheDeduplicationResult({
    required this.entries,
    required this.tombstonedCount,
  });

  final List<TranslationCacheEntry> entries;
  final int tombstonedCount;
}

/// Retires provider-specific copies of the same reusable AI request.
///
/// The earliest result remains active. Losers become tombstones rather than
/// disappearing, so a device that has not synced yet cannot resurrect them.
TranslationCacheDeduplicationResult deduplicateReusableAiEntries(
  Iterable<TranslationCacheEntry> entries,
  DateTime now,
) {
  final source = entries.toList(growable: false);
  final groups = <String, List<TranslationCacheEntry>>{};
  for (final entry in source) {
    if (entry.deletedAt != null || entry.translationService != 'ai') continue;
    final key = jsonEncode(entry.reusableIdentity);
    groups.putIfAbsent(key, () => <TranslationCacheEntry>[]).add(entry);
  }

  final replacements = <String, TranslationCacheEntry>{};
  var tombstonedCount = 0;
  for (final group in groups.values.where((group) => group.length > 1)) {
    group.sort((left, right) {
      final created = left.createdAt.compareTo(right.createdAt);
      return created != 0
          ? created
          : left.requestKey.compareTo(right.requestKey);
    });
    for (final duplicate in group.skip(1)) {
      final deletionTime = now.isAfter(duplicate.updatedAt)
          ? now
          : duplicate.updatedAt.add(const Duration(microseconds: 1));
      replacements[duplicate.requestKey] = duplicate.tombstone(deletionTime);
      tombstonedCount++;
    }
  }

  return TranslationCacheDeduplicationResult(
    entries: <TranslationCacheEntry>[
      for (final entry in source) replacements[entry.requestKey] ?? entry,
    ],
    tombstonedCount: tombstonedCount,
  );
}

TranslationCacheMergeResult mergeTranslationCacheEntries(
  Iterable<TranslationCacheEntry> local,
  Iterable<TranslationCacheEntry> remote,
) {
  final localByKey = <String, TranslationCacheEntry>{
    for (final entry in local) entry.requestKey: entry,
  };
  final remoteByKey = <String, TranslationCacheEntry>{
    for (final entry in remote) entry.requestKey: entry,
  };
  final keys = <String>{...localByKey.keys, ...remoteByKey.keys}.toList()
    ..sort();
  final merged = <TranslationCacheEntry>[];
  var hasIdentityConflict = false;

  for (final key in keys) {
    final localEntry = localByKey[key];
    final remoteEntry = remoteByKey[key];
    if (localEntry == null) {
      merged.add(remoteEntry!);
      continue;
    }
    if (remoteEntry == null) {
      merged.add(localEntry);
      continue;
    }
    if (!localEntry.hasSameIdentity(remoteEntry)) {
      // The caller must not upload this merged document. Keeping both original
      // documents in place avoids destroying either side of a collision.
      hasIdentityConflict = true;
      merged.add(localEntry);
      continue;
    }
    final timeComparison =
        localEntry.updatedAt.compareTo(remoteEntry.updatedAt);
    if (timeComparison > 0) {
      merged.add(localEntry);
    } else if (timeComparison < 0) {
      merged.add(remoteEntry);
    } else {
      // Deterministic across devices, independent of map/list iteration order.
      merged.add(
          localEntry.canonicalState().compareTo(remoteEntry.canonicalState()) >=
                  0
              ? localEntry
              : remoteEntry);
    }
  }
  return TranslationCacheMergeResult(
    entries: merged,
    hasIdentityConflict: hasIdentityConflict,
  );
}
