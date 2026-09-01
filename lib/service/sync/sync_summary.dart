import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';

class SharedSyncSummary {
  final AnnotationSyncStatus status;
  final int activeDocumentCount;
  final int pendingDocumentCount;
  final int failedDocumentCount;
  final int discoveredDocumentCount;
  final DateTime? lastCompletedAt;

  const SharedSyncSummary({
    required this.status,
    required this.activeDocumentCount,
    required this.pendingDocumentCount,
    required this.failedDocumentCount,
    required this.discoveredDocumentCount,
    required this.lastCompletedAt,
  });
}
