# Annotation synchronization

Annotations use protocol-v2 `AnnotationBookDocument` objects and synchronize
independently from Anx's legacy whole-database backup.

The WebDAV account URL remains the base URL. `annotationRemoteRoot` is the
shared annotation root and defaults to `Lingua Reader`, matching Lingua
Reader's default `webdavRemotePath`. Both clients therefore resolve a book to:

```text
<base URL>/<shared annotation root>/annotations/<lowercase-md5>.json
```

Changing the shared annotation folder must be done consistently in both
clients. It does not change legacy Anx paths under `anx/` and does not create an
Anx-specific annotation tree.

Synchronization is automatic and merge-based. Remote absence is not deletion;
replacement uses the strong ETag returned with the current GET, and creation
uses `If-None-Match: *`. When the canonical merged document already matches the
remote representation, clients mark it converged without an unnecessary PUT.
HTTP 412 causes a bounded reread/merge/retry followed by an exclusive WebDAV
LOCK, a final read and merge, and a lock-protected PUT. A malformed remote
document is never overwritten.
