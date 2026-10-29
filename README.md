# Photos Library Sort Helper

Photos Library Sort Helper is a local-first Mac, iPhone, and iPad app for manually reviewing media from Apple Photos. The Mac app also reviews regular folders. Review groups help organize the work, but the app does not auto-pick winners, auto-delete media, or silently move files.

This is a Sidelark Labs / John Kenneth Fisher project. More Sidelark Labs projects live at [sidelarklabs.com](https://sidelarklabs.com).

## Safety

- No automatic deletion.
- No direct destructive delete action.
- No hidden telemetry, analytics, ads, or background sync.
- Photos access is requested only when Photos work starts.
- Folder writes happen only after an explicit commit review.
- Marked discards are queued into review destinations instead of being deleted.

## Requirements

- Mac: macOS 26 or later.
- iPhone/iPad: iOS/iPadOS 27 or later. The iOS app works with Photos and does not include Folder mode.
- Xcode for local builds.
- User-granted Photos permission for Photos Library review.
- Read/write access to any folder-mode source you intentionally select.

## Keyboard Commands

When the review pane is active:

- `Left Arrow` / `Right Arrow`: move to the previous or next group.
- `Up Arrow` / `Down Arrow`: highlight the previous or next item.
- `` ` ``: toggle the highlighted item between keep and discard.
- `E`: queue the highlighted item for edit.

The Review menu also includes command-key shortcuts for scanning, stopping a scan, group navigation, item navigation, keep/discard actions, edit queueing, and opening the summary.

## Project Notes

- Current status and known limitations are tracked in [docs/WHERE_WE_STAND.md](docs/WHERE_WE_STAND.md).
- Durable project decisions are tracked in [docs/DECISIONS.md](docs/DECISIONS.md).
- Agent instructions begin in [AGENTS.md](AGENTS.md).
- The approved multiplatform design and implementation status are in [docs/planning/multiplatform-phase-1/README.md](docs/planning/multiplatform-phase-1/README.md) and [docs/WHERE_WE_STAND.md](docs/WHERE_WE_STAND.md).
