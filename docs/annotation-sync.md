# Annotation synchronization

Annotations use protocol-v2 `AnnotationBookDocument` objects and participate
in the same automatic, directionless shared-state runtime as the library,
reading state/activity, organization records, and Anx presentation metadata.
No SQLite database is uploaded or downloaded.

The WebDAV account URL remains the base URL. `annotationRemoteRoot` is the
shared annotation root and defaults to `Lingua Reader`, matching Lingua
Reader's default `webdavRemotePath`. Both clients therefore resolve a book to:

```text
<base URL>/<shared annotation root>/annotations/<lowercase-md5>.json
```

Changing the shared root must be done consistently in both clients. New Anx
domain documents are stored below `<shared root>/shared/v1/`; the existing
annotation path above remains compatible with Lingua Reader. Immutable book
assets and the independent translation cache retain their Anx paths outside
the configurable shared root.

Synchronization is automatic and merge-based. Remote absence is not deletion;
replacement uses the strong ETag returned with the current GET, and creation
uses `If-None-Match: *`. When the canonical merged document already matches the
remote representation, clients mark it converged without an unnecessary PUT.
HTTP 412 causes a bounded reread/merge/retry followed by an exclusive WebDAV
LOCK, a final read and merge, and a lock-protected PUT. A malformed remote
document is never overwritten.

Startup, resume, connectivity restoration, book open, local mutation, and
manual **Sync now** trigger synchronization. Lifecycle-wide runs are
coalesced, and `PROPFIND` collection discovery allows remote-only books and
their documents to reach a fresh device. Status diagnostics cover every shared
domain and expose counts only; document IDs, paths, credentials, and content
are not logged.
