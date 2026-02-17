# PhotoSortHelper (macOS)

A safety-first macOS app to help you review bursts/near-duplicate photos in Apple Photos.

## What It Does

- Connects to your Apple Photos library using PhotoKit.
- Lets you scan either:
  - all photos, or
  - a specific album.
- Lets you set a start date.
- Finds candidate groups by:
  - photos taken close together in time, and
  - visual similarity (Apple Vision feature prints).
- Shows one group at a time so you can decide what to keep.
- Defaults to **keep everything** until you explicitly mark photos to discard.
- Only changes your library if you click delete and confirm.

## Safety Guarantees in This App

- No automatic deletion.
- No file-level writes to your Photos library package.
- Deletion uses Apple Photos API (`PHAssetChangeRequest.deleteAssets`) only after explicit confirmation.
- Deleted photos go to **Recently Deleted** first (recoverable in Photos for about 30 days in most setups).

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
7. If you want to remove marked photos, click **Move Marked Photos to Recently Deleted** and confirm.

## Suggested First Run

- Use an album first (small scope).
- Keep default settings except:
  - `Max time gap`: 8 seconds
  - `Similarity threshold`: 12.0
- Confirm results look right before scanning larger ranges.

## Notes

- Large scans can take time, especially with iCloud photos that need download.
- If results are too broad, lower similarity threshold (stricter) or lower time gap.
- If results are too narrow, raise threshold or raise time gap.
