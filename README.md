# Photos Library Sort Helper (macOS)

Photos Library Sort Helper is a personal/hobby macOS app built for my own Apple Photos cleanup workflow. It is being shared publicly because it may be useful to other people, but outside usefulness is incidental. No warranty, support commitment, stability guarantee, or roadmap promise is implied beyond the actual license.

## What It Does

- Connects to your Apple Photos library using PhotoKit.
- Scans either all photos or a specific album.
- Lets you optionally constrain the scan to a date range.
- Finds candidate groups using capture-time proximity plus Apple Vision feature-print similarity.
- Shows one group at a time so you can review what to keep and what to discard.
- Defaults to **keep everything** until you explicitly change a decision.
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
3. When macOS asks for Photos access, click **Allow**.
4. Choose scan settings on the left.
5. Click **Scan for Similar Photos**.
6. Review each group and toggle Keep/Discard by clicking cards.
7. If you want to save the highlighted item for later editing, use **Send Highlighted to Files to Edit**.
8. If you want to review marked discards in Photos, click **Open Summary and Commit**, review the summary, then click **Queue to "Files to Manually Delete"**.

## Build A Standalone App

To build a double-clickable universal app bundle in `dist/`:

```bash
cd /path/to/repo
./scripts/build_app.sh
```

This creates `dist/Photos Library Sort Helper.app`.

## Local Data And Storage

- Review session state is stored locally at:
  - `~/Library/Application Support/com.jkfisher.photoslibrarysorthelper/review-session-v1.json`
- Scan preferences and learned best-shot weights are stored locally in the app's macOS defaults domain.
- If you are upgrading from the old `Photo Sort Helper` identity, the app migrates the previous local session and preference data into the new bundle identifier.
- The app may request iCloud-backed assets through PhotoKit when thumbnails, previews, or videos are needed, but it does not upload your library data to any third-party service.

## Suggested First Run

- Use an album first so the scan scope stays small.
- Keep the default settings the first time through, especially `Max time gap: 8 seconds`.
- Confirm the grouping behavior looks right before scanning larger ranges.

## Notes

- Large scans can take time, especially with iCloud photos that need download.
- Similarity threshold is fixed at `12.0` for consistent grouping.
- If results are too broad or too narrow, adjust `Max time gap`.
- Current project status and the latest durable rollback anchor are summarized in `docs/WHERE_WE_STAND.md`.
