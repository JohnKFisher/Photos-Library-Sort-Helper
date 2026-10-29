# Photos Library Sort Helper — Project Instructions

Follow the global Codex instructions and conditional rules from the active `$CODEX_HOME`.

## Project purpose

Photos Library Sort Helper is a local-first macOS app for manually reviewing likely-similar media from either Apple Photos or ordinary filesystem folders.

The app assists organization and decision-making. It does not autonomously decide which media should survive.

## Core safety invariants

- Never automatically choose a "best" item or infer that similar media are duplicates that should be removed.
- Never automatically or permanently delete user media.
- Never silently move user files or change Photos organization.
- User review remains authoritative.
- Photos and Folder are equal first-class source modes.
- Preserve explicit review/commit boundaries before consequential changes.
- Do not add telemetry, analytics, cloud services, remote sync, or other transmission of user media without an explicit product decision.

## Photos mode

- Request Photos access only when an explicit user action actually requires Photos work; do not prompt merely because the app launched.
- Respect the limitations of PhotoKit's macOS library authorization model rather than pretending finer permission separation exists.
- Preserve conservative queue-based organization rather than introducing direct Photos deletion.
- PhotoKit/iCloud-backed assets may be slow to resolve; do not mistake expected retrieval latency for permission or data failure without evidence.

## Folder mode

- Folder writes are conservative and deferred until an explicit summary/commit step.
- Reviewed keeps remain in place by default.
- Queue actions may move files only to the established review destinations unless the user explicitly selects another supported behavior.
- Never follow symlinked directories or casually broaden a selected source tree.
- Preserve preview-before-commit behavior for filesystem changes.
- Direct permanent deletion is not part of the product.

## Review semantics

Both `Discard-first` and `Keep-first` are supported review modes. Do not collapse them into one assumed workflow.

Changing review mode during an active session must not silently reinterpret existing decisions.

In `Keep-first`, an untouched item being provisionally kept for review does not make it an explicit keep for downstream organization. Preserve the distinction between default review state and explicit user action.

Similarity grouping is a review aid, not an automated judgment. Changes to grouping logic should prioritize useful candidate groups without converting similarity confidence into destructive decisions.

## Product and platform direction

- Keep the product local-first, safety-oriented, and optimized for the owner's manual sorting workflow.
- Preserve the Mac-native multi-scene design: standard Settings, dedicated About window, toolbar/menu commands, inspector behavior, Finder integration, and normal desktop affordances.
- Keep AppKit interop narrow where practical rather than rebuilding system windowing behavior unnecessarily.
- `Media-Sort-Helper` is retired. Do not split new development back into the older app; this repository is the unified Photos + Folder product.

## Local state

Important scan preferences, review/session state, folder bookmarks, and related recoverable state should remain inspectable and locally stored. Preserve restoration/recovery behavior when changing persistence.

## Project documentation

Treat `docs/DECISIONS.md` as the durable decision record and `docs/WHERE_WE_STAND.md` as current implementation/status context.

When an approved decision is intentionally replaced, update or supersede it rather than leaving contradictory rules active.

The existing Info.plist-based version/build decision predates the current global `VERSION` + `BUILD_NUMBER` convention and should be superseded when this repository is retrofitted to that convention.