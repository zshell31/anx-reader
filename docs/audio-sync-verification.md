# Audio availability checks (2026-09-10)

Implementation note, not a Notes RFC amendment.

ANX Reader and Lingua Reader no longer recompute SHA-256 for existing immutable
audio during local availability/read checks. They still check length, and verify
SHA-256 before accepting generated or downloaded bytes. Same-length local edits
are intentionally not detected by routine synchronization.

Both clients now persist remote-presence receipts scoped to URL, account,
remote root, asset reference, digest and length. Existing local audio with a
matching receipt causes no remote request. Missing local files still go through
download/verification; failed transfers never establish a new receipt. New
endpoints and new metadata require a new check. The first run seeds receipts;
subsequent runs reuse them. External remote deletion while a valid local copy
and receipt remain is intentionally not polled for.

ANX reading-activity sync now makes one attempt per pass on HTTP 423, retains
dirty work, and retries in the background after 1, 5, then 15 minutes. Persistent
locks remain eligible at the longest interval even after the normal retry budget
has been exhausted. This avoids startup retry bursts; it does not remove a
server-side lock or claim the pending document has converged.

Cross-repository review:

- ANX Reader: local availability checks use existence and length without reading
  file contents. Download and generation integrity checks remain.
- Lingua Reader: local reads retain length validation without hashing. Incoming
  bytes are still verified in `persist`; canonical descriptors are unchanged.
- English Coach: inspected canonical audio descriptor contract; unaffected,
  because canonical audio metadata and storage contracts do not change.
- Screen Translator: inspected audio generation and note persistence; unaffected,
  because generation-time verification and shared descriptors do not change.
- Notes RFC: no schema, merge, Markdown, or transport-contract changes; no version
  or adoption-pin update is needed.

Validation: ANX audio, coordinator, reading activity, runtime boundary, and
protocol fixture tests (105 passed); Lingua audio and protocol fixture tests
(40 passed). Tests cover restart persistence, endpoint isolation, missing-file
download, failed upload, and pending locked work recovering after unlock.
Downloaded same-length invalid audio remains rejected in both clients.
Device timing after the hash-only change still showed 6.29–6.76 seconds in the
audio phase.

Device verification with persistent receipts: first launch took 8.634 seconds
(audio 7.092 seconds, trustedRemote=0); second launch took 2.400 seconds
(audio 0.296 seconds, trustedRemote=91). The server still returns HTTP 423 for
one reading-activity document; each launch makes one write attempt and schedules
the next retry for 15 minutes, retaining pending=1/failed=1.

Samsung SM-M315F verification: first launch took 21.977 seconds and downloaded
26 missing audio files; second launch took 2.153 seconds (audio 0.713 seconds,
trustedRemote=91). Both completed with pending=0/failed=0. After the user opened
and closed a book, read-only WebDAV lockdiscovery found no locks in any of the
three reading-activity folders or their 14 documents. The previously affected
book had a nonempty September 10 document updated at 13:48:02 local time.
The old empty September 9 file had been separately unlocked and deleted at the
user's explicit request; these code changes do not automatically clear locks.
