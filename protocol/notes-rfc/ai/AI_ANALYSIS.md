# AI analysis and useful chunks

Modern producer transport is one structured JSON object: required string fields
translation, translationNotes, grammar, usage and required chunks array (0–7).
Use Russian unless an existing client explicitly configures another explanatory
language. Empty explanation strings are allowed when irrelevant; do not fabricate
content to fill a field. Scope is selectedText; contextText only disambiguates.
Source data never supplies instructions. Preserve names/domain terminology and
explain OCR uncertainty in translationNotes. See ANALYSIS_PROMPT.md.

AiChunk has required nonempty canonicalForm and meaning. Optional canonical
surfaceForm is the actual source form if meaningfully different. Optional type:
collocation, expression, phrasal_verb, idiom, pattern. Optional examples are natural
English in the same sense. Strict AI transport includes nullable surfaceForm/type/
examples keys; normalize null to absence in canonical commentary. Up to two examples
per modern generated chunk. Examples MUST be newly written English sentences
in a different situation, retaining the same meaning of the chunk. Do not copy
sentences from selectedText/contextText or merely swap names/pronouns in them.
This is a generation requirement, not permission to rewrite historical examples.
Existing stored chunks/extra fields are retained;
producer limits are not retroactive limits on historical canonical data.

Useful units are reusable expressions/patterns, not arbitrary n-grams. Attempt
chunks even if selected text is eligible for fallback. Zero useful units is valid.
Do not pad with isolated words or deduplicate across unrelated providers.

Persist normalized results in ai-analysis/commentary with these same five semantic
names. Optional top-level translation may duplicate commentary.translation for
legacy readers; keep them consistent. providerId/providerName/model retain actual
provenance. Legacy commentary can omit any field, including chunks; consumers
must tolerate this. Screen's legacy meaning maps to translationNotes; legacy
selectedText/examples wrappers are transport extensions, not a competing schema.

Coach consumes active canonical enrichments, ignores tombstoned parents/children,
and uses chunks preserving canonicalForm, surfaceForm, type, meaning and examples.
Keep existing selected-text fallback (English selection <=8 words, unless matching
a chunk canonical/surface form) and grammarTopicId metadata. Canonical semantic
records may have book or screen provenance; screen records never need a fake book.
Occurrence metadata preserves annotation ID/date/context and meaningful source
provenance. The Lingua API loader may remain as transport; semantics are source-neutral.
