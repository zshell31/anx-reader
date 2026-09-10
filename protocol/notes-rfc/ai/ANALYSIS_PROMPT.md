# Shared analysis prompt

## A. Normative behavior

All three producers MUST implement AI_ANALYSIS.md and use the instruction in
[reference-prompt.txt](reference-prompt.txt). Vendor it and embed it at build time
if necessary; no shared runtime dependency is needed. API-specific wrapping,
JSON-quoting source input and explicit configured language overrides are allowed;
independently invented extraction semantics are not. Send source text as data,
separate from instructions where the API supports message roles. Tests inspect
the request and parse fixture responses without a live model.

## B. Reference wording

The companion plain-text file is the exact vendorable reference wording. Prompt
wording may evolve compatibly only when the normative behavior stays unchanged.
The output schema is ../schemas/ai-analysis.schema.json. Do not request a
Markdown document or replace chunks with a standalone examples section.
