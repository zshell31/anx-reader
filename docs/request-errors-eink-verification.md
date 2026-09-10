# Request errors and e-ink verification — 2026-09-10

Implementation/verification record, not a normative Notes contract.

The supplied Android log contains three annotation AI JSON parsing errors
(18:30:06, 18:53:04, 18:53:24) and one LDOCE 15-second timeout (19:09:45).
No API credentials or full user log are included here.

ANX now supplies the existing Notes RFC analysis schema in the analysis prompt
and uses strict Chat Completions response_format for the official OpenAI endpoint.
Other providers receive the schema in the prompt without assuming support for
OpenAI strict response_format. Follow-up chat retains its normal response format.
No JSON repair or changes to stored canonical commentary are introduced.

LDOCE waits up to 30 seconds per attempt, retries a timeout/client connection
failure once, and closes owned clients after each attempt. HTTP failures are not
retried; access-denied responses are reported separately. Live computer requests
initially returned HTTP 403 (both mobile and desktop user agents, also without
proxychains). A later identical mobile-header request returned HTTP 200 in 1.32s:
132130 bytes, parsed by the actual ANX parser into 2 entries, 25 senses and
82 examples for `take`. The cause of the transient denial is unknown. This does
not establish network availability from the phone or verify arbitrary headwords.

E-ink pending indicators in the Study Note Editor, shared buttons, loading overlay
and AI chat loading view use a static hourglass. Editor indeterminate loading bars
are omitted in e-ink mode while the provider heading/hourglass remain visible.
Normal-screen indicators retain animation. This does not throttle AI text streaming
elsewhere or disable every animation in the application.

## Cross-client review

Reviewed Notes RFC 2.3.0 AI_ANALYSIS and STUDY_NOTE_EDITOR, the pinned schema,
and all four application instructions/implementations:

- ANX: affected transport and pending UI implementation only.
- Lingua Reader: src/openai-request.ts already sends the RFC schema with strict
  structured output. No change needed to producer, canonical storage or runtime API.
- Screen Translator: backend/src/providers/openai.rs already uses structured
  output. No change needed to its screen producer/editor.
- English Coach: src/integrations/canonical/contract.ts consumes the same optional
  canonical commentary/chunk fields. No storage/consumer changes needed.

No shared semantics, canonical JSON shape, Markdown projection or schema changes;
RFC version and adoption pins remain unchanged.

## Validation

129 Flutter tests passed: annotation enrichment services, OpenAI compatibility,
Study Note Editor widget/controller tests and annotation protocol fixtures.
The request regression exercises the real LangChain OpenAI HTTP adapter against
a mock server response and compares the sent schema to the pinned RFC schema.
The e-ink widget regression keeps a provider pending and verifies the visible
hourglass and absence of continuously scheduled animation frames.
Timeout recovery, bounded retry and HTTP 403 handling have regression coverage.
No paid OpenAI request was performed. Release deployment is recorded below.

Targeted Dart analysis found no errors in changed code; it reports the existing
use_build_context_synchronously info in ai_chat_stream.dart. The custom_lint plugin
could not initialize (pub is not an AOT snapshot / dartaotruntime), including
when run outside the sandbox, so plugin lint verification remains unavailable.

## Release deployment

Built 1.15.0+6325 with Flutter 3.35.3 / Java 17 using --release --no-pub
--target-platform android-arm64 --split-per-abi and
--split-debug-info=/tmp/anx-6325-release-symbols. No obfuscation.
The signed APK is 39.4 MB and contains only arm64-v8a native libraries; no
.symbols files are packaged. apksigner verification passed.

Saved APK: /tmp/anx-reader-1.15.0-6325-arm64.apk
SHA256: da6276e79f76af4b09eee8e94fb2b73e2c956071cccaf81f0022ac0289addb77

Installed with adb install -r on R58R10T97EF. Android confirms versionCode=6325,
versionName=1.15.0, lastUpdateTime=2026-09-10 19:53:57. firstInstallTime remains
2026-09-02 20:43:03: this was an in-place update, with no uninstall or data clear.
MainActivity launch returned Status: ok, the app process remained running, and
the crash buffer was empty. This is a launch smoke check, not a live paid AI test.
The same verified ARM64 APK was subsequently installed with adb install -r on
LOMONOSOV3 (A3DE65C3). Android confirms versionCode=6325 and
lastUpdateTime=2026-09-10 20:00:19; firstInstallTime remains 2026-09-05 00:40:46.
MainActivity cold launch returned Status: ok (1185 ms), the process remained
running, and the crash buffer was empty. No uninstall or data clear was used.
