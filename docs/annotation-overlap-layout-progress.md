# Nested annotations and bilingual layout

- 2026-09-05: Confirmed EPUB hit testing prioritized redraw order, not the
  specificity of the annotation. Prefer the smallest painted annotation at the
  tapped point; the surrounding sentence remains accessible outside its nested
  notes. Added restoration-order and redraw geometry regressions.
  Both regressions passed; rebuilt the reader bundle (existing webpack
  top-level-await compatibility warnings remain).
- 2026-09-05: Added document-content observation to the paginator. Translation
  insertion, text edits, display changes and late resource loads trigger a
  batched layout/overlay refresh even when body dimensions remain unchanged.
  Retiring a chapter disconnects observation and cancels pending work. Repeated
  translation reconciliation preserves existing text nodes; no-op style writes
  are ignored to prevent refresh loops. Added observer and translator regressions.
- Validation: all eight JavaScript test files pass; production bundle rebuilt.
  Existing webpack top-level-await compatibility warnings remain. No on-device
  verification was performed.
- No annotation protocol or note-format changes.
