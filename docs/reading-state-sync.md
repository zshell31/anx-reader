# Reading state synchronization

Reading position is a portable per-book document keyed by the lowercase MD5
semantic book fingerprint. The payload contains the reader position,
percentage, and a deterministic `(modifiedAt UTC, device UUID)` mutation stamp.
The newer stamp wins; percentage is never merged by taking a maximum.

Opening a book or restoring a projection does not manufacture a mutation.
Only meaningful reader progress updates the canonical document and durable
outbox. Startup catalog discovery runs before reading-state discovery, allowing
a fresh device to learn fingerprints without copying `app_database.db`.

Remote creation uses `If-None-Match: *`; replacement uses a strong ETag and
`If-Match`. HTTP 412 causes reread, merge, and bounded retry. Pending mutations
survive restart in `shared_state.db`, which itself is never uploaded.

See [sync-architecture.md](sync-architecture.md) for lifecycle, ownership,
remote paths, conflict handling, and migration details.
