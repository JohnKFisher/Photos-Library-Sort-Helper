# Photos Library Sort Helper — Where We Stand

## Current Version

- Source baseline: `2.5.0`
- Latest verified packaged app in `dist/`: rebuilt after the preview-status color fix and 2.5.0 version bump
- Packaging and release workflows still use the source-controlled version/build values from `Resources/Info.plist`

## Overall Status

Photos Library Sort Helper is now the single surviving app for both Apple Photos review and folder-based review. It is local-first, safety-oriented, and still intentionally conservative about writes.

## What Works Now

- Two equal source modes: `Photos Library` and `Folder`
- Two persisted manual review modes: `Discard-first` and `Keep-first`
- Mac-native app shell with a standard Settings window, dedicated About window, toolbar actions, inspector, and expanded menus
- Late, explicit Photos permission prompting only when Photos work actually starts
- Photos scanning across all photos or a selected album
- Folder scanning across a selected root folder with recursive traversal
- Similar-media grouping using capture-time proximity plus Vision feature-print similarity
- Hidden-file, unsupported-file, package, and symlinked-directory skipping in folder mode
- Group-by-group keep/discard review with one shared review UI, including session reset confirmation if the review mode changes mid-session
- Photos queueing into `Files to Edit`, `Files to Manually Delete`, and `Fully Sorted`
- Folder commit preview plus sibling-folder commits into `Files to Edit` and `Files to Manually Delete`
- Optional folder-mode `Keep` destination for reviewed keeps
- Folder picker attached to the active window plus drag-and-drop folder selection
- Finder actions for opening the selected source folder, revealing queue destinations, and revealing the highlighted file-backed item
- Local restoration of the last review session
- Inspectable file-backed scan preferences, bookmark-backed folder selections, and recent folder history in Application Support
- Standalone app and DMG packaging through `./scripts/build_app.sh`
- Build and release GitHub Actions workflows, with release notes derived from committed history
- Focused automated tests covering versioning, preference migration, legacy session compatibility, folder scanning, and folder commit behavior

## What Is Partial

- Public distribution readiness: the app is signed ad hoc, but not notarized
- Cross-machine validation: the universal package should still be runtime-checked on both Apple Silicon and Intel hardware
- Folder bookmark recovery UX is better surfaced through menus and empty states, but still ultimately requires re-choosing the folder when the bookmark goes stale
- Keep-first wording/UX has automated coverage for persistence and commit planning, but still deserves a full interactive smoke pass on real review sessions

## What Is Not Implemented Yet

- Direct deletion from Photos
- Direct permanent deletion from folder mode
- Cloud services, telemetry, or remote sync
- Signed/notarized distribution for broad public release

## Known Limitations And Trust Warnings

- Large scans can take a while, especially when PhotoKit needs to fetch iCloud-backed items
- On macOS, PhotoKit still exposes a single Photos authorization model, so true read-only versus write-only permission separation is not available
- Folder mode is intentionally conservative: nothing moves until the summary commit step, and keeps remain in place by default
- In `Keep-first`, untouched items are kept for review only. They do not get queued to `Fully Sorted` or moved to `Keep` unless the user makes them explicit keeps.
- The app stores local review/session state and scan preferences so you can resume work later
- The app is built for the owner’s personal workflow first; outside fit and long-term stability are not guaranteed
- `Media-Sort-Helper` is retired and should not receive new work; this repo is now the replacement path

## Setup And Runtime Requirements

- macOS 15 or later
- Xcode toolchain installed for local builds
- Photos permission granted by the user when they begin Photos scanning or queue Photos album changes
- Access to the local Photos library and any needed iCloud-backed assets through PhotoKit
- Read/write access to any folder-mode source tree the user intentionally selects

## Important Operational Risks

- PhotoKit-backed scans can feel slow or stall temporarily when cloud-backed assets need downloading
- Folder-mode commits move real files, so the summary step must remain careful and user-reviewed
- The app relies on Apple media frameworks and local filesystem semantics, so behavior should be rechecked after major macOS upgrades
- Notarization and broader distribution hardening are still outstanding

## Recommended Next Priorities

1. Run an interactive smoke pass in both `Discard-first` and `Keep-first` on real Photos and folder datasets
2. Decide whether the new macOS 15 floor is acceptable for the owner’s real machines before shipping any wider
3. Consider Quick Look or richer metadata inspection if double-click/open-in-default-app is not enough for folder review
4. Decide whether public distribution is worth notarization/signing work

## Durable Anchor

- Most recent durable known-good anchor before the macOS-shell modernization pass: `b7671db`
