import 'package:anx_reader/models/full_text_translation_cache.dart';

class TranslationCacheMergeResult {
  const TranslationCacheMergeResult({
    required this.entries,
    required this.hasIdentityConflict,
  });

  final List<TranslationCacheEntry> entries;
  final bool hasIdentityConflict;
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
