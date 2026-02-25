# PhotoSortHelper (macOS)

A safety-first macOS app to help you review bursts/near-duplicate photos in Apple Photos.

## What It Does

- Connects to your Apple Photos library using PhotoKit.
- Lets you scan either:
  - all photos, or
  - a specific album.
- Lets you set an optional date range.
- Finds candidate groups by:
  - photos taken close together in time, and
  - visual similarity (Apple Vision feature prints).
- Shows one group at a time so you can decide what to keep.
- Defaults to **keep everything** until you explicitly mark photos to discard.
- Only changes your library when you explicitly queue items into review albums.

## Safety Guarantees in This App

- No automatic deletion.
- No file-level writes to your Photos library package.
- No destructive delete operation from this app.
- Marked discards can be queued to **Files to Manually Delete** for final human review in Apple Photos.

## Install Prerequisites

1. Install **Xcode** from the Mac App Store.
2. Open Xcode once and accept the license.
3. In Terminal, run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Run The App

1. Open this folder in Xcode:

```bash
open /Users/jkfisher/Documents/PhotoSortHelper/Package.swift
```

2. In Xcode, click the Run button.
3. When macOS asks for Photos access, click **Allow**.
4. Choose scan settings on the left.
5. Click **Scan for Similar Photos**.
6. Review each group and toggle Keep/Discard by clicking cards.
7. If you want to review marked discards in Photos, click **Queue Marked for Manual Delete (Continue)**.

## Build A Standalone .app

To build a double-clickable app bundle in `dist/` (with proper Finder icon):

```bash
cd /Users/jkfisher/Documents/PhotoSortHelper
./scripts/build_app.sh
```

Then copy `dist/Photo Sort Helper.app` to `/Applications`.

## Suggested First Run

- Use an album first (small scope).
- Keep default settings except:
  - `Max time gap`: 8 seconds
- Confirm results look right before scanning larger ranges.

## Notes

- Large scans can take time, especially with iCloud photos that need download.
- Similarity threshold is fixed at `12.0` for consistent grouping.
- If results are too broad or too narrow, adjust `Max time gap`.
