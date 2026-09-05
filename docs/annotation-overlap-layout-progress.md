# Nested annotations and bilingual layout

- 2026-09-05: Confirmed EPUB hit testing prioritized redraw order, not the
  specificity of the annotation. Prefer the smallest painted annotation at the
  tapped point; the surrounding sentence remains accessible outside its nested
  notes. Added restoration-order and redraw geometry regressions.
  Both regressions passed; rebuilt the reader bundle (existing webpack
  top-level-await compatibility warnings remain).
- Next: observe internal document layout changes even when the paginated body
  keeps the same size; refresh annotation geometry after translation arrives.
- No annotation protocol or note-format changes.
