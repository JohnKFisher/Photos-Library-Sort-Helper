---
type: "query"
date: "2026-08-21T01:38:36.954786+00:00"
question: "Hi. I want an option to scan an album/folder like I do now, but have it auto-stop after coming up with a settable (but default 100) number of groups."
contributor: "graphify"
outcome: "useful"
source_nodes: ["ReviewViewModel", "SimilarityScanner", "ScanSettings", "ScanResult", "StoredScanPreferences"]
---

# Q: Hi. I want an option to scan an album/folder like I do now, but have it auto-stop after coming up with a settable (but default 100) number of groups.

## Answer

Expanded from original query via graph vocab: [scan, scanner, similarity, group, groups, stop, cancel, album, folder, preferences]. The current flow is ReviewViewModel.requestScan to startScan to SimilarityScanner.scan. Both sources load all items before chronological cluster grouping, results publish only on successful completion, and stopScan cancellation discards partial groups. A group cap belongs in scanner grouping with exact truncation and an explicit capped result state; the main owner decision is whether limited scanning is the default behavior or an opt-in mode.

## Outcome

- Signal: useful

## Source Nodes

- ReviewViewModel
- SimilarityScanner
- ScanSettings
- ScanResult
- StoredScanPreferences