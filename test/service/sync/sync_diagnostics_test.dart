import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test('short sync identifiers preserve correlation without full identity', () {
    const full = '0123456789abcdef0123456789abcdef';
    expect(shortSyncId(full), '01234567…');
    expect(shortSyncId(full), isNot(contains(full)));
  });

  test('run diagnostics correlate INFO and DEBUG records', () async {
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = AnxLog.log.onRecord.listen(records.add);
    try {
      await runWithSyncDiagnostics('manual', (_) async {
        syncInfo('started trigger=manual auto=true wifiOnly=false');
        syncDebug('phase=discovery started');
        syncInfo('completed discovered=0 pending=0 failed=0 durationMs=1');
      });
      await Future<void>.delayed(Duration.zero);
    } finally {
      await subscription.cancel();
    }

    expect(records, hasLength(3));
    expect(records[0].level, Level.INFO);
    expect(records[1].level, Level.FINE);
    final runPrefixes = records
        .map((record) => RegExp(r'^sync run=\d+').stringMatch(record.message))
        .toSet();
    expect(runPrefixes, hasLength(1));
    expect(runPrefixes.single, isNotNull);
  });
}
