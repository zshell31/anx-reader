# AnnotationBookDocument v2 canonical protocol

This document is normative for the M4A Dart/TypeScript interoperability
boundary. Shared annotation bytes use `schemaVersion: 2`. A v2 decoder must
reject any other version after the explicitly supported v1 migration.

## Shared and local state

- The book identity is `fingerprintAlgorithm: "md5"` plus a lowercase,
  exactly 32-character hexadecimal fingerprint.
- Annotation `motivation` is semantic and is exactly `selection` or
  `bookmark`.
- `presentation` is renderer-local. It is forbidden in shared v2 annotations.
- V1 migration removes `presentation`. Lingua preserves its value only in a
  local sidecar keyed by annotation ID; Anx discards it without assigning any
  semantic meaning. An absent v1 motivation becomes `selection`; an existing
  valid `selection` or `bookmark` motivation is retained.
- Unknown JSON object fields and unknown selector objects are retained. Their
  nested object keys are canonicalized, while their array order is retained.
- A known optional timestamp is either absent or a canonical string. JSON
  `null` is not equivalent to absence for a known timestamp and is invalid.
  Null-valued unknown fields are retained.

## Canonical values and bytes

- Every protocol timestamp is UTC in exactly
  `YYYY-MM-DDTHH:mm:ss.sssZ` form and must denote a real instant whose
  round-trip representation is identical.
- Canonical JSON recursively sorts every object key by ordinal UTF-16 code
  unit, with no locale-dependent comparison. JSON array order is not sorted by
  the JSON encoder.
- Protocol-owned arrays are normalized before encoding: annotations by `id`,
  enrichments by `id`, and AI messages by integer `sequence` then `id`.
  Selectors, `contextSnapshot.enrichmentIds`, and unknown arrays retain their
  supplied order.
- Shared JSON is compact: there is no insignificant whitespace. String
  escaping and Unicode behavior are fixed by the conformance corpus.
- Entity IDs are non-empty strings and are unique within their containing
  protocol-owned array.

## Immutable identity

An entity with a distinct ID is an independent addition. Two values with the
same ID must have byte-equivalent canonical values for all immutable identity
fields below or the merge fails with the corresponding identity-collision
outcome.

| Entity | Immutable identity fields |
| --- | --- |
| annotation | `id`, `createdAt` |
| material enrichment | `id`, `createdAt`, `kind` |
| AI thread | `id`, `createdAt`, `kind`, `contextSnapshot` |
| AI message | `id`, `createdAt`, `role`, `sequence` |

`contextSnapshot` identity includes recursively canonicalized unknown fields
and retains array order, including the order of `enrichmentIds`.

## Merge

- Distinct IDs are unioned.
- For the same valid identity, the greater canonical `updatedAt` wins the
  mutable payload. Equal timestamps use the lexicographically greater
  canonical JSON payload after excluding independently merged child arrays and
  `deletedAt`.
- Document/book unknown fields use the lexicographically greater canonical
  document envelope after excluding `annotations`; book identity fields are
  normalized first.
- Child arrays merge independently: annotation enrichments by enrichment ID
  and AI-thread messages by message ID.
- Tombstones are sticky. If either side has `deletedAt`, the result has the
  lexicographically greatest valid tombstone timestamp regardless of a later
  payload edit. This applies to annotations, material enrichments, personal
  notes, AI threads, and AI messages.
- For valid non-collision inputs merge is idempotent, commutative, and
  associative.

## Conformance corpus

`fixtures/annotation_book_document_v2.json` is copied byte-for-byte into both
repositories. Its 33 cases declare either exact canonical JSON/value output or
one stable semantic error code. Both runners can emit a canonical result report;
the reports must compare byte-for-byte, in addition to each suite checking the
declared fixture expectation.
