/// Reusable shared-document convergence API.
///
/// Kept as a separate import boundary so new domains do not need to describe
/// their dependency as annotation synchronization. The compatibility facade
/// and annotation defaults remain in the original library.
export 'annotation_sync_coordinator.dart'
    show
        AnnotationLockRetryDelay,
        AnnotationRetryScheduler,
        AnnotationSyncStatus,
        MalformedRemoteAnnotationException,
        SharedDocumentChanged,
        SharedDocumentDecoder,
        SharedDocumentIdValidator,
        SharedDocumentMerger,
        SharedDocumentSyncCoordinator;
