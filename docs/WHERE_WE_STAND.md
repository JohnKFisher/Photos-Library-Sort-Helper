# Photos Library Sort Helper — Where We Stand

## Current Version

- Source baseline: `2.1.0`
- Latest verified packaged app in `dist/`: `2.1.0` (Build `1`)
- Packaging and release workflows use the source-controlled version/build values from `Resources/Info.plist`.

## Overall Status

Photos Library Sort Helper is usable for personal review of similar photos inside Apple Photos. The app is local-first, safety-oriented, and intentionally conservative about writes.

## What Works Now

- Photo library authorization and album discovery.
- Late, explicit Photos permission prompting when the user starts a scan or queues album changes.
- Scanning all photos or a selected album.
- Optional date-range filtering.
- Similar-photo grouping using capture time and Vision feature prints.
- Group-by-group keep/discard review.
- Highlighted-item queueing into `Files to Edit`.
- Summary-confirmed queueing of marked discards into `Files to Manually Delete`.
- Local restoration of the last review session.
- Inspectable file-backed scan preferences in Application Support.
- Standalone app and DMG packaging through `./scripts/build_app.sh`.
- Build and release GitHub Actions workflows.
- Focused automated tests for alignment-critical helpers and persistence compatibility.

## What Is Partial

- Public distribution readiness: the app is signed ad hoc, but not notarized.
- Cross-machine validation: the universal package should still be runtime-checked on both Apple Silicon and Intel hardware.

## What Is Not Implemented Yet

- Direct deletion from Photos.
- Cloud services, telemetry, or remote sync.
- Signed/notarized distribution for broad public release.

## Known Limitations And Trust Warnings

- Large scans can take a while, especially when PhotoKit needs to fetch iCloud-backed items.
- On macOS, PhotoKit still exposes a single Photos authorization model, so true read-only versus write-only permission separation is not available.
- The app stores local review/session state and scan preferences so you can resume work later.
- The app is built for the owner's personal workflow first; outside fit and long-term stability are not guaranteed.
- A public GitHub release is appropriate for source sharing, but the packaged app should still be treated as hobby software.

## Setup And Runtime Requirements

- macOS 14 or later.
- Xcode toolchain installed for local builds.
- Photos permission granted by the user when they begin scanning or queue album changes.
- Access to the local Photos library and any needed iCloud-backed assets through PhotoKit.

## Important Operational Risks

- PhotoKit-backed scans can feel slow or stall temporarily when cloud-backed assets need downloading.
- The app relies on local Photos metadata and Apple frameworks, so behavior should be rechecked after major macOS upgrades.
- Notarization and broader distribution hardening are still outstanding.

## Recommended Next Priorities

1. Validate the universal app bundle on both Apple Silicon and Intel Macs.
2. Decide whether public app distribution is worth notarization/signing work.
3. Add issue templates or lightweight release notes polish if public sharing becomes a bigger goal.
4. Revisit whether any additional read-only safety messaging is needed around Photos' single permission model.

## Durable Anchor

- Most recent durable known-good anchor: `codex/checkpoint-20260402-142137`
- Commit: `adbc57c`
