# Large PDF synchronization, image-only pages and screen timeout

User log: run 1 completed in 76,708 ms. SHA-256 verification of the new
asset took 38,163 ms; its upload phase took approximately 35,865 ms.
The supplied PDF is 244,145,976 bytes. Page 5 (printed page 4, Scene),
including “These prompts are not there to control your story”, is a full-page
image without a text layer. Other pages contain native text. Copying is not
restricted. Confirmed with Poppler extraction, image listing and page rendering.

Implementation: Android streams SHA-256 through the platform cryptographic
provider on a background task queue; other platforms hash in an isolate.
Digest identities, verification receipts and transport semantics are unchanged.
Upload completion diagnostics include bytes and elapsed time.
Image-only page long presses explain the need for OCR. A separate keep-screen-on
preference overrides the timer; PDF/EPUB pointer activity renews the finite timer.
Leaving/resuming the app releases/reacquires the reading wakelock.

## Notes RFC compatibility inspection

Read normative README, editor/STUDY_NOTE_EDITOR.md and canonical/WEBDAV.md.
No schema, selector, annotation, merge, editor action or projection changes;
no normative RFC revision or adoption change is needed.

- ANX: only local empty-page feedback, file hashing implementation and screen
  preference change. No canonical writes from an unsuccessful selection.
- Lingua Reader: inspected src/annotations/types.ts and adoption/instructions;
  book MD5 identity and PDF/text quote selector contracts are unchanged.
- Screen Translator: inspected gnome-extension/study-selection.js and adoption/
  instructions; OCR selection and its canonical screen semantics are unaffected.
- English Coach: inspected src/integrations/canonical/contract.ts and adoption/
  instructions; canonical consumer fields and source discovery are unaffected.

OCR output is a separate book file/identity, not an in-place source replacement
or annotation migration. Existing source file and annotations are preserved.

## Validation

- 40 targeted tests passed: file hashing (5), asset synchronization and PDF
  selection (27), reading wakelock (2), library protocol/repository (6).
- Targeted analyzer: no errors; two pre-existing use_build_context_synchronously
  infos in the unrelated reading-page notes navigation handler.
- Release APK built for arm64-v8a only with split-debug-info in /tmp.
- OCR added to physical pages 1, 2, 4, 5, 7, 8, 9, 10, 11, 15, 23, 24 of 27.
  Existing text retained on the remaining 15 pages. Exact target phrase extracted
  from page 5. Pixel comparisons at 100 dpi matched on every OCR page.
  Original SHA-256 is unchanged and matches log asset 703c83b6... .
- User requested no debug installation. The in-flight debug install
  completed despite cancelling its adb process; the diagnostic package was then
  uninstalled and its absence verified. No debug app was launched and no device
  SHA benchmark is claimed.
- Release installation completed successfully with `adb install -r`; Android
  reports lastUpdateTime 2026-09-20 19:51:41, package com.anxcye.anx_reader,
  version 1.15.0+6325. Release data was not removed. Debug package is absent.
- Per user request, live UI and synchronization performance checks are left to
  the user. No OCR copy was imported into the application during verification.
- OCR output: `~/Books/Solo/SoloRPG Field Guide - Full pages OCR.pdf`, also copied
  to the phone's Download folder. Title: Solo RPG Field Guide (OCR).
  SHA-256: 1bd60cfb0f96a4fcbbd0b07c15fe1cc021c880428e189a756221a396a0d5dd70.

## Follow-up: import after picker and deletion refresh

Release log symbolization with the 6325 build's saved symbols identifies:

- `BookshelfPageState._importBook` line 100: `State.context` null-check after
  the originating bookshelf was disposed while Android's picker was open.
- `BookBottomSheet.build.handleDelete` line 61: `WidgetRef.read` after the
  bottom sheet had been popped. The database tombstone was already saved,
  explaining why restarting hid the deleted book.

The OCR source is present in `/sdcard/Books/` (plural), 243,829,116 bytes;
Android reports approximately 60 GB free. These observed crashes are lifecycle
errors, not missing text or damaged OCR.

Picker completion now targets the app navigator; the import dialog owns its
Consumer ref. Duplicate checking also retains the navigator instead of using
an obsolete context. Import cannot be dismissed/restarted midway through saving.
Metadata save completes before its caller refreshes the list. Deletion captures
the ProviderContainer before closing the sheet and invalidates the bookshelf
immediately after local persistence. File cleanup tolerates already-missing files.

Canonical membership, identities and annotation deletion semantics are unchanged;
the cross-client unaffected conclusions above still apply. Two widget regression
tests pass, including disposing the launching page before completing the picker.
User will perform live import/deletion verification; no debug installation.

Follow-up validation: release arm64 APK rebuilt successfully (39.4 MB), symbols
stored in `/tmp/anx-import-symbols`. Targeted analysis reports no errors and three
pre-existing context-after-await infos in drag/drop and book replacement handlers.
Follow-up release installed with `adb install -r` successfully; Android reports
lastUpdateTime 2026-09-20 21:03:40. Manual import/deletion verification remains
with the user as requested.

## Follow-up: import cost and visible upload progress

Fresh device log confirmed the optimized SHA-256 took 514 ms for the 243,829,116
byte OCR book. Upload took 101,330 ms; its old screen-dependent PNG cover was
22,636,781 bytes and took another 9,211 ms. Final status calculation took 189 ms.
The remaining local import performed MD5 twice using a whole-file Dart buffer.

- MD5 now uses Android MessageDigest on the existing background task queue;
  the portable implementation streams in an isolate. The canonical MD5 identity
  is unchanged. Duplicate-check results are reused only while staged file path,
  size, modification time and change time still match; changed files are hashed
  again. TXT retains its original-source fingerprint behavior.
- New PDF covers render independently of viewport/DPR, at most 1000 pixels on
  the long edge, without upscaling, and encode JPEG at quality 0.82. Large embedded
  covers also become bounded JPEGs. Existing imported covers are not rewritten.
- Local import completion has its own message and refreshes local availability.
  Immutable-asset uploads report transient per-file bytes and percent to the book
  card and sync detail sheet, including uploads outside the legacy sync helper.
  Failed/completed transfers clear active progress in finally. No canonical
  progress fields or wire-format changes; prior cross-client unaffected findings
  apply. A progress value of 100% means bytes sent; success still requires the
  upload operation to complete.

Validation: 27 Dart hashing/import/asset tests, one real book-card/sync-sheet
widget test, and three JS cover tests passed. Web bundle rebuilt; existing three
webpack top-level-await target warnings remain. No on-device timing claim for
this follow-up; the user requested manual device verification themselves.
Final targeted analyzer: no issues found. Release arm64 APK rebuilt successfully;
verified only arm64 native libraries and inclusion of the new cover module.
Debug symbols stored outside the repository in `/tmp/anx-import-speed-symbols`.
Release installed successfully with `adb install -r`; Android reports
lastUpdateTime 2026-09-20 21:22:02. User data preserved; no debug build installed.
