# Repository instructions

## Android device verification

- For on-device verification, only the debug package (`com.anxcye.anx_reader.dev`) may be uninstalled. Never uninstall the release package (`com.anxcye.anx_reader`), because doing so deletes the user's application data.
- Build a release APK only for the connected device ABI (for example, `--target-platform android-arm64 --split-per-abi`) so the APK does not include unused architectures, including native libraries bundled by plugins.
- Keep release symbols out of the APK by passing `--split-debug-info` with a temporary output directory outside the repository. Do not use `--obfuscate` unless explicitly requested.

## Cross-client compatibility

- When changing the shared annotation protocol or note format, inspect the effect on Lingua Reader at `/home/zshell/projects/obsidian/reader` and run the relevant cross-client/protocol tests there. The same rule applies in reverse when a change originates in Lingua Reader.
- If compatibility requires code changes in both ANX Reader and Lingua Reader, explain the required cross-repository changes and ask the user for approval before modifying the other repository. After approval, update and verify both clients.
- Protocol and note-format changes must also account for the runtime API exposed by Lingua Reader and its English Coach consumer at `/home/zshell/projects/obsidian/listening-coach`. Inspect those contracts and ask the user before making required changes outside this repository.

## Notes RFC

This repository participates in the shared Notes RFC.

Normative repository: `/home/zshell/projects/obsidian/notes_rfc` (no Git remote
configured yet). Role: **producer/consumer + AI + reference Study Note Editor**. Adoption is pinned in `protocol/NOTES_RFC`.

Before changing canonical annotations, selectors, enrichments, AI analysis/prompts,
useful chunks, providers, editor/selection/deletion behavior, Markdown projection
or canonical consumption, read the Notes RFC first. Shared changes MUST be
coordinated across all affected repositories; inspect all four and document any
unaffected repository. This task already authorizes coordinated edits. Canonical
JSON is authoritative; Markdown is presentation only. Local protocol documents
are pointers or non-normative implementation/history notes, never competing owners.
