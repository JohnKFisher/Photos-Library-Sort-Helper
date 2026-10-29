# Phase 2 Implementation Roadmap

The owner approved Phase 2 on 2026-10-29: Review Console is the multiplatform baseline, with Photo-First Triage's small in-thumbnail classification indicators; system SQLite stores local review state, the shared pending queue, and commit journal; cross-device conflict detection is best-effort and no separate synchronization service is added. Implementation is authorized against this roadmap.

**Implementation status (2026-10-29):** The shared core, local SQLite state and migration, Mac Photos workflow, and universal iPhone/iPad Photos app are implemented. The full local suite, iPhone/iPad simulators, and universal Mac package pass; Sol's final acceptance review found no remaining actionable implementation issues. Physical-device, real Photos library, and two-device acceptance remains open; see section 7 and [current status](../../WHERE_WE_STAND.md).

## 0. Owner approval and behavior baseline

**Status: complete.** The approved design decisions and indicator treatment are recorded in the prototype, comparison, and decision record. Vision refinement was removed; Live Photos remain image items and videos remain singletons.

- Apply the no-Vision source correction required by the assignment: remove the current feature-print refinement, preserve adjacent-gap grouping and videos-as-singletons, and document Live Photos as photo items.
- Preserve both review modes and the approved queue, conflict, and migration invariants during integration.
- Freeze representative current JSON session fixtures and expected decision behavior before schema changes. No real Photos library is used for fixtures.

## 1. Extract the shared domain and test its invariants

**Status: implemented and automated.** `PhotosSortCore` owns deterministic grouping, review decisions, group completion/skip, queue state, positions, and commit reconciliation. Boundary, transitive, unknown-date, stable-order, video, Live Photo, and persistence/recovery cases are covered by the Swift suite.

- Add a platform-neutral `PhotosSortCore` package target while retaining the existing macOS executable.
- Separate metadata values from `PHAsset`, `NSImage`, AppKit, URLs/bookmarks, and SwiftUI.
- Move the approved time-group function, group-completion/skip rules, frozen per-item classifications, scope position, and queue transitions into deterministic unit-testable code.
- Add tests for exact gap boundaries, transitive chains, unknown dates, equal timestamps, stable order, video singletons, Live Photo grouping, mode changes, explicit/default state, group revisits, and scope switching.
- Keep the production Mac UI and Folder behavior intact while extracting the core. After parity tests, adopt the assignment-required time-only Photos grouping without Vision.

## 2. Add local queue persistence and safe migration

**Status: implemented.** System SQLite stores per-device queue, positions, album bindings, migration receipts, and commit journal. The legacy shared Mac session JSON remains a read-only Photos migration source; Folder session writes now use a dedicated JSON path, and older Folder sessions copy forward with an atomic write/read-back check while preserving the original. Only validated explicit Photos choices are imported, repeated import is idempotent, and displayed legacy groups are not treated as completed. Persisted source preferences choose which active session can restore, so a retained Folder session or empty reset marker cannot override a newer Photos selection. Automated cases cover reopen, interrupted commit recovery, unsupported schema preservation, and the legacy Folder/Photos split. Disk-full behavior and malformed legacy-file handling are not simulated as device-level failures.

- Add a small system-SQLite repository for the shared per-device pending queue, scope positions, and commit journal; retain inspectable JSON preferences and import the existing `review-session-v2.json` without deleting or rewriting the source.
- Migrate only validated explicit decisions, edit marks, reviewed groups, mode, position, source scope, and scan checkpoint. Preserve the old file until the new state has reopened and passed equivalence checks.
- Make one item one current pending classification. Store why it is pending and whether it is an explicit mark or a default applied on completion.
- Add migration and recovery tests for old/new/malformed data, repeated import, interruption, disk-full/write error, process restart, and unsupported schema.

## 3. Implement album binding, reconciliation, and commit journal

**Status: implemented; real-library behavior remains unverified.** The Mac and iOS PhotoKit adapters bind destination roles by saved album identity, require explicit choices when a role cannot be resolved unambiguously, show a reviewed Commit All summary, add assets without removing them, and reconcile membership before clearing the matching queue revision. Pure reconciliation and interrupted-journal recovery are automated; PhotoKit execution, sync delays, and concurrent devices require a real Photos library.

- Resolve each destination album by stored identity before title; detect duplicates; block on ambiguous binding. On a fresh install with no exact expected title, ask whether to bind a renamed album or explicitly create the missing role because a cross-device rename cannot otherwise be recognized.
- Register for Photos changes and refresh status memberships on foreground, before commit, after commit, and when PhotoKit reports relevant changes.
- Build a reviewed Commit All summary from immutable pending decisions. Revalidate authorizations, albums, assets, and all three destination memberships.
- Apply target additions through one PhotoKit change transaction where supported; never remove or directly delete an asset.
- Reconcile after interruption by reading memberships. Remove only verified successes; retain failures and conflict/unavailable items with original intent.
- Add a conflict UI and recovery tests for app edits, Photos.app edits, duplicate/renamed/missing albums, partial sync, permission revocation, delayed iCloud updates, and two devices committing opposite decisions.

## 4. Build the progressive metadata index and media loading

**Status: implemented with device-scale validation open.** Both apps establish the complete deterministic metadata set before review and subtract destination membership plus local pending work. Thumbnails are requested lazily; selected/inspection media requests report PhotoKit progress and are cancellable. Current iOS scope preparation yields while enumerating, but an interrupted metadata pass is rerun rather than resumed from a persisted metadata frontier. Indexing latency, memory, thermal load, and iCloud behavior have not been measured on large libraries.

- Enumerate scope metadata, subtract the union of three album memberships and the device-local pending queue from new work, establish deterministic global oldest-first order, and checkpoint progress before presenting a complete frontier.
- Start review after the complete ordered metadata set and group boundaries are known. Then progressively prepare thumbnails and upcoming groups in bounded batches; request media only for visible and next-group items. Keep staged items available through a separate revisit route.
- Add cancellation and resumable state across app suspension/termination. Report iCloud image/video/Live Photo download progress with PhotoKit handlers.
- Measure indexing latency, memory, battery/thermal effects, thumbnail cache size, and iCloud network use on large local and optimized libraries. Tune with evidence, without changing completeness or grouping boundaries.
- Use the same scanner service on Mac and iOS after behavior parity; preserve a distinct Mac Folder scanner.

## 5. Integrate the Mac experience

**Status: implemented; universal package validation passed locally.** The existing Mac scenes, Settings/About, commands, Finder support, Photos mode, and Folder workflow remain. Photos group navigation now includes completion/skip, staged work and Commit All; inspection adds side-by-side comparison and explicit image, Live Photo, and video actions. The signed arm64/x86_64 app and DMG passed verification when staged outside the File Provider-backed repository directory.

- Keep standard Settings, About, commands, keyboard shortcuts, Finder integration, folder mode, and existing app identity.
- Add Continue Sorting, all-unsorted/album/date-range scope entry, shared pending count and Commit All access, group completion/skip, and review restoration to the existing shell.
- Add Mac side-by-side comparison and explicit full-resolution/Live Photo/video inspection actions.
- Update the Mac workflow so a successful Photos commit keeps the user in review and lands on the next eligible unsorted group.
- Regress Folder mode, both review modes, existing menu/key commands, permissions, app/DMG build, signing/notarization configuration, and legacy session restoration.

## 6. Build the universal iPhone/iPad app

**Status: implemented; simulator tests passed.** The native iOS/iPadOS 27 app uses the Review Console layout and Photo-First bottom-right markers across iPhone and iPad views. The markers preserve decision color and symbol and use solid, outlined, or dashed treatments for explicit, implicit, and staged-default classifications; parent controls announce the full state. iPhone 18 Pro and iPad Pro 11-inch simulator UI suites each passed 2/2 launch/permission-timing tests. Simulator coverage does not exercise a Photos review with library data or substitute for device accessibility and layout review.

- Add an Xcode project with a universal iOS/iPadOS 27 target that references `PhotosSortCore`; keep iOS folder/FileProvider sorting out of scope.
- Implement the selected Review Console baseline natively, with iPhone portrait/landscape reflow, one-handed bottom actions, iPad split review, and platform-native photo/video/Live Photo viewers. Use Photo-First Triage's small bottom-right in-thumbnail status markers in Console photo navigation on all platforms. Preserve the Console's surrounding layout and controls. Keep color plus a compact symbol for Keep, Discard, and Edit; use outline/fill treatment for implicit, staged-default, and explicit states, with full state in accessibility labels.
- Require full Photos access for album-based unsorted review; explain this before requesting permission. Handle denied, restricted, limited, and revoked states without dropping local pending work.
- Support photo-group overview, enlarged inspection, zoom/pan, Previous/Next Photo, Previous/Next Group, Skip, per-photo Keep/Discard/Edit, iPhone A/B compare, and iPad side-by-side compare.
- Preserve the single per-device queue and local scope positions through app suspension, process termination, orientation changes, and successful commits.

## 7. Hardening and distribution readiness

**Status: local automated checks and independent acceptance review complete; owner/device acceptance remains.** The current automated suite has 51 Swift tests, two iPhone simulator UI tests, and two iPad simulator UI tests. The universal Mac app is ad-hoc signed at build 62 and its DMG passed verification. Sol reviewed the actual implementation diff, including migration preservation and source-preference restoration, and found no remaining actionable issues. Real-library, two-device, hardware, accessibility, performance, and thermal checks below remain open. Developer ID signing, notarization, TestFlight/App Store work has not started.

- Run core, Mac, and iOS UI/unit tests plus a dedicated regression review by a second engineer. Add automated migration, PhotoKit adapter, and commit-reconciliation coverage.
- Test on real Mac/iPhone/iPad hardware with two devices on one iCloud Photos library, delayed/offline sync, simultaneous edits, renamed/duplicate albums, limited/revoked access, large libraries, backdated imports, missing dates, Live Photos, HDR, long videos, and interruption at each commit phase.
- Verify VoiceOver, large Dynamic Type, contrast, reduced motion, keyboard, touch target size, and landscape/adaptive layouts.
- Recheck performance, memory, cancellation, thermal behavior, and iCloud download experience on the oldest supported devices.
- Only after local development and owner acceptance, prepare TestFlight/App Store metadata, privacy disclosures, signing, provisioning, screenshots, and distribution validation. No release work begins as part of this Phase 1.

## Coordinated execution shape

Keep one shared contract for grouping, decisions, IDs, queues, and commit outcomes. Core tests exercise deterministic commit outcomes with fake membership snapshots; the production PhotoKit adapter still needs real-library verification. Complete independent review of the actual implementation diff before declaring Phase 2 complete. Escalate only new consequential decisions or incompatibilities outside the approved scope.
