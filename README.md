# Photos Library Sort Helper (macOS)

Photos Library Sort Helper is a personal/hobby macOS app built for my own Apple Photos cleanup workflow. It is being shared publicly because it may be useful to other people, but outside usefulness is incidental. No warranty, support commitment, stability guarantee, or roadmap promise is implied beyond the actual license.

## What It Does

- Connects to your Apple Photos library using PhotoKit.
- Scans either all photos or a specific album.
- Lets you optionally constrain the scan to a date range.
- Finds candidate groups using capture-time proximity plus Apple Vision feature-print similarity.
- Shows one group at a time so you can review what to keep and what to discard.
- Defaults to **discard-first manual review** unless you turn on best-shot suggestions.
- Can queue selected items into review albums in Photos:
  - `Files to Edit` for a highlighted item you want to revisit later.
  - `Files to Manually Delete` for marked discards you want to review in Photos before deleting anything yourself.

## Safety Guarantees

- No automatic deletion.
- No file-level writes into the Photos library package.
- No direct destructive delete action from this app.
- Album writes are explicit and user-initiated.
- Marked discards go to `Files to Manually Delete` for final human review in Photos.

## Distribution Caveats

- The packaged `.app` is currently code-signed ad hoc for local use, but it is **not notarized** for public macOS distribution yet.
- The build script produces a **universal** app bundle intended to run on both Apple Silicon and Intel Macs running macOS 14 or later.
- If macOS blocks the app on first launch, use normal platform UI:
  - In Finder, Control-click the app and choose **Open**.
  - If needed, open **System Settings > Privacy & Security** and use **Open Anyway** for the blocked app.

## Install Prerequisites

1. Install **Xcode** from the Mac App Store.
2. Open Xcode once and accept the license.
3. In Terminal, run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Run In Xcode

1. Open this folder in Xcode:

```bash
open Package.swift
```

2. In Xcode, click the Run button.

## Build A Standalone App

To build a double-clickable universal app bundle in `dist/`:

```bash
cd /path/to/repo
./scripts/build_app.sh
```

This creates `dist/Photos Library Sort Helper.app`.

## How To Use

1. Launch the app and grant Photos access when macOS asks.
2. Start with a small scope. An album is easiest for a first pass, or you can keep **All Photos** selected and turn on a narrow date range.
3. Keep `Max time gap` conservative at first. The default `8 seconds` is a good starting point.
4. Leave **Auto-detect best shot per group** off unless you specifically want to experiment with suggestions. The default workflow is manual and conservative.
5. Click **Scan for Similar Photos**.
6. Review one group at a time. In the default discard-first mode, a new group opens with nothing kept yet, so you explicitly choose what should survive.
7. If a highlighted item looks worth revisiting later, use **Send Highlighted to Files to Edit**.
8. When you are ready to queue discards for a final check in Photos, click **Open Summary and Commit**, review the summary, then click **Queue to "Files to Manually Delete"**.

![Discard-first review overview](docs/images/discard-first-overview.png)

_Default review state: the app surfaces a group for human triage first, then lets you queue marked discards into a manual-review album in Photos._

What success looks like: after a session, the app has not deleted anything. Instead, you end up with a curated set of items in Photos albums such as `Files to Edit` and `Files to Manually Delete`, where you can make the final call yourself.

## Review Modes

### Discard-first manual review (default)

- This is the normal workflow and the one the app is tuned around.
- With best-shot detection off, each group starts from a conservative posture: nothing is kept for you automatically.
- You decide what to keep, what to discard, and whether anything should be queued into Photos review albums.
- This means users should not expect automatic culling by default.

### Auto-detect best shot per group (optional)

- The app can score quality signals and suggest a likely keeper when you open a group.
- That mode exists, but it is off by default because, in my own use, it has not been consistently helpful enough to recommend as the standard workflow.
- If you turn it on, treat it as a suggestion layer, not as a trusted automatic cleanup pass. You can override any suggestion.

![Review mode controls](docs/images/review-modes-sidebar.png)

_The optional best-shot toggle is available in the scan settings, but the default mode remains discard-first manual review._

## Local Data And Storage

- Review session state is stored locally at:
  - `~/Library/Application Support/com.jkfisher.photoslibrarysorthelper/review-session-v1.json`
- Scan preferences and learned best-shot weights are stored locally in the app's macOS defaults domain.
- If you are upgrading from the old `Photo Sort Helper` identity, the app migrates the previous local session and preference data into the new bundle identifier.
- The app may request iCloud-backed assets through PhotoKit when thumbnails, previews, or videos are needed, but it does not upload your library data to any third-party service.

## Troubleshooting And Limits

- If macOS blocks the standalone app on first launch, use Finder **Open** or **System Settings > Privacy & Security > Open Anyway**. The app is ad-hoc signed, not notarized.
- If the app cannot see your library, check Photos permission in **System Settings > Privacy & Security > Photos**.
- Large scans can take a while, especially when PhotoKit needs to fetch iCloud-backed assets for thumbnails, previews, or videos.
- The app does not delete anything for you, does not sync to any remote service, and does not auto-cull your library in the background.
- Best-shot detection is available, but it is not the default because the discard-first manual workflow has been more reliable in practice.
- Similarity threshold is fixed at `12.0` for consistent grouping. If results feel too broad or too narrow, adjust `Max time gap`.
- Current project status and the latest durable rollback anchor are summarized in `docs/WHERE_WE_STAND.md`.
