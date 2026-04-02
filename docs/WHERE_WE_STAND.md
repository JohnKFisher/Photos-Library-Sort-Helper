# Photos Library Sort Helper — Where We Stand

## Current Version

- Source baseline: `2.0.0`
- Latest verified packaged app in `dist/`: `2.0.1` (Build `2`)
- Packaging is configured to auto-increment patch/build numbers on subsequent app builds.

## Overall Status

Photos Library Sort Helper is usable for personal review of similar photos inside Apple Photos. The app is local-first, safety-oriented, and intentionally conservative about writes.

## What Works Now

- Photo library authorization and album discovery.
- Scanning all photos or a selected album.
- Optional date-range filtering.
- Similar-photo grouping using capture time and Vision feature prints.
- Group-by-group keep/discard review.
- Highlighted-item queueing into `Files to Edit`.
- Summary-confirmed queueing of marked discards into `Files to Manually Delete`.
- Local restoration of the last review session.
- Standalone app packaging through `./scripts/build_app.sh`.

## What Is Partial

- Public distribution readiness: the app is signed ad hoc, but not notarized.
- Public-repo polish: GitHub repo metadata, CI, and tests are still minimal or absent.
- Cross-machine validation: the package now targets universal app output, but runtime validation should still happen on both Apple Silicon and Intel hardware.

## What Is Not Implemented Yet

- Direct deletion from Photos.
- Cloud services, telemetry, or remote sync.
- Automated regression tests and CI pipelines.
- Signed/notarized distribution for broad public release.

## Known Limitations And Trust Warnings

- Large scans can take a while, especially when PhotoKit needs to fetch iCloud-backed items.
- The app stores local review/session state and scan preferences so you can resume work later.
- The app is built for the owner's personal workflow first; outside fit and long-term stability are not guaranteed.
- A public GitHub release is appropriate for source sharing, but the packaged app should still be treated as hobby software.

## Setup And Runtime Requirements

- macOS 14 or later.
- Xcode toolchain installed for local builds.
- Photos permission granted by the user.
- Access to the local Photos library and any needed iCloud-backed assets through PhotoKit.

## Important Operational Risks

- PhotoKit-backed scans can feel slow or stall temporarily when cloud-backed assets need downloading.
- The app relies on local Photos metadata and Apple frameworks, so behavior should be rechecked after major macOS upgrades.
- Notarization and broader distribution hardening are still outstanding.

## Recommended Next Priorities

1. Add basic automated tests around scan settings, session restore, and packaging behavior.
2. Add GitHub repo metadata such as issue templates, CI, and release notes structure.
3. Validate the universal app bundle on both Apple Silicon and Intel Macs.
4. Decide whether public app distribution is worth notarization/signing work.

## Durable Anchor

- Most recent durable known-good anchor: `codex/checkpoint-20260402-142137`
- Commit: `adbc57c`
