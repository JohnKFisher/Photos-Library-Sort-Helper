# Graph Report - /Users/jkfisher/Documents/Coding/Projects/Photos Library Sort Helper  (2026-08-20)

## Corpus Check
- 69 files · ~50,974 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 697 nodes · 1713 edges · 51 communities (20 shown, 31 thin omitted)
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 143 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Review Workflow
- Folder Commit Models
- Photos Album Fetch
- Review UI Playback
- Folder Media Loading
- Media Preview
- Preferences and Versioning
- Review Errors
- Saved Review Session
- Project Governance
- Photo Permissions
- App Commands and Windows
- Scan Preferences
- UI Theme
- App Storage Paths
- Coding Identifiers
- Core Media Models
- Foundation Utilities
- Package Tests and Dependencies
- App Entry
- Build Script
- Diagnostics and Privacy
- Licensing and Distribution
- Swift Package
- Version Bump Script
- Notarization Script
- Project Profile Template
- AI Rules
- Cross Platform Rules
- Dependency and Asset Rules
- Local RTK Rules
- Long Running Work
- Media Export Rules
- Migration Safety
- Apple Platform Rules
- Tauri Rules
- Web Rules
- Windows Rules
- Project Philosophy
- Untrusted Input
- User Data Permissions
- App Icon Variant
- App Icon Variant
- App Icon Variant
- App Icon Variant
- App Icon Variant
- App Icon Variant
- App Icon Variant
- App Icon Variant
- App Icon Variant
- App Icon Variant

## God Nodes (most connected - your core abstractions)
1. `ReviewViewModel` - 155 edges
2. `ReviewGroup` - 54 edges
3. `PhotoLibraryService` - 39 edges
4. `ReviewItem` - 38 edges
5. `FolderLibraryService` - 34 edges
6. `CodingKeys` - 34 edges
7. `StoredReviewSession` - 26 edges
8. `FolderSelection` - 23 edges
9. `FolderCommitDestination` - 22 edges
10. `ReviewGroupDecisions` - 20 edges

## Surprising Connections (you probably didn't know these)
- `Release GitHub Actions workflow` --references--> `Public distribution readiness is partial`  [INFERRED]
  .github/workflows/release.yml → docs/WHERE_WE_STAND.md
- `CI release packaging distribution rules` --references--> `Release GitHub Actions workflow`  [INFERRED]
  docs/agent-rules/ci-release-distribution.md → .github/workflows/release.yml
- `Personal workflow contribution policy` --conceptually_related_to--> `Local-first conservative manual workflow`  [INFERRED]
  CONTRIBUTING.md → README.md
- `Documentation and status rules` --references--> `Photos Library Sort Helper README`  [EXTRACTED]
  docs/agent-rules/docs-readme-changelog.md → README.md
- `ReviewViewModel` --calls--> `FolderCommitService`  [INFERRED]
  Sources/PhotoSortHelper/ReviewViewModel.swift → Sources/PhotoSortHelper/FolderCommitService.swift

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Local-first safety-oriented review flow** — readme_local_first_conservative_manual_workflow, readme_no_automatic_deletion, status_photos_and_folder_source_modes [INFERRED 0.95]
- **Versioned packaged release artifact flow** — docs_decisions_info_plist_version_source_of_truth, github_workflows_build_workflow, github_workflows_release_workflow, status_build_app_dmg_packaging [EXTRACTED 1.00]
- **Project documentation governance** — agents_project_rules, docs_agent_rules_core_workflow, docs_agent_rules_docs_readme_changelog, docs_decisions_decision_log, docs_where_we_stand_status [INFERRED 0.85]

## Communities (51 total, 31 thin omitted)

### Community 0 - "Review Workflow"
Cohesion: 0.05
Nodes (21): CGPoint, Never, ObservableObject, ReviewGroup, ReviewViewModel, AVAsset, Bool, Double (+13 more)

### Community 1 - "Folder Commit Models"
Cohesion: 0.05
Nodes (65): CaseIterable, Codable, Hashable, Identifiable, KeyedDecodingContainer, Sendable, FolderCommitService, Bool (+57 more)

### Community 2 - "Photos Album Fetch"
Cohesion: 0.08
Nodes (38): MainActor, PHAssetCollection, PHCollection, PHCollectionList, PHFetchOptions, PHFetchResult, AlbumKind, smart (+30 more)

### Community 3 - "Review UI Playback"
Cohesion: 0.07
Nodes (38): AVKit, AVPlayerView, Context, DateIntervalFormatter, NavigationSplitViewVisibility, NSView, NSViewRepresentable, ScrollViewProxy (+30 more)

### Community 4 - "Folder Media Loading"
Cohesion: 0.11
Nodes (16): DateFormatter, NSWindow, FolderLibraryService, FolderScanListing, Bool, CGFloat, CGImage, Date (+8 more)

### Community 5 - "Media Preview"
Cohesion: 0.08
Nodes (25): AVPlayerItem, CGSize, PHCachingImageManager, PHImageRequestID, AVPlayer, ImageBox, PhotoRequestCancellationState, PlayerItemBox (+17 more)

### Community 6 - "Preferences and Versioning"
Cohesion: 0.10
Nodes (18): Data, ReleaseVersioning, Any, String, ScanPreferencesStore, StoredScanPreferences, Bool, Date (+10 more)

### Community 7 - "Review Errors"
Cohesion: 0.06
Nodes (31): Equatable, LocalizedError, ReviewError, albumNotFound, emptySourceFolder, missingAlbumSelection, missingSourceFolder, noReviewedItemsToCommit (+23 more)

### Community 8 - "Saved Review Session"
Cohesion: 0.08
Nodes (26): CodingKeys, autoplayPreviewVideos, currentGroupID, currentGroupIndex, currentHighlightedAssetID, currentHighlightedItemID, folderRecursiveScan, folderSelection (+18 more)

### Community 9 - "Project Governance"
Cohesion: 0.11
Nodes (24): Project rules router, CI release and distribution work is high leverage and high risk, AGENTS.md source-of-truth pointer, Personal workflow contribution policy, CI release packaging distribution rules, Context efficiency rules, Core workflow rules, Ask-first gate for material changes (+16 more)

### Community 10 - "Photo Permissions"
Cohesion: 0.19
Nodes (5): PhotoAuthorizationSupport, Bool, PHAuthorizationStatus, String, PHAuthorizationStatus

### Community 11 - "App Commands and Windows"
Cohesion: 0.13
Nodes (10): AppKit, Commands, Scene, AboutView, AppCommands, AppWindowID, about, MainWindowScene (+2 more)

### Community 12 - "Scan Preferences"
Cohesion: 0.12
Nodes (16): CodingKeys, autoplayPreviewVideos, folderRecursiveScan, folderSelection, includeVideos, maxAssetsToScan, maxTimeGapSeconds, moveKeptItemsToKeepFolder (+8 more)

### Community 13 - "UI Theme"
Cohesion: 0.39
Nodes (4): ColorScheme, Bool, Color, UITheme

### Community 14 - "App Storage Paths"
Cohesion: 0.42
Nodes (4): AppPaths, FileManager, String, URL

### Community 15 - "Coding Identifiers"
Cohesion: 0.18
Nodes (11): CodingKey, CodingKeys, assetIDs, endDate, id, itemIDs, kind, localIdentifier (+3 more)

### Community 16 - "Core Media Models"
Cohesion: 0.20
Nodes (8): AVFoundation, CoreGraphics, Darwin, ImageIO, EffectiveReviewState, discard, keep, UniformTypeIdentifiers

### Community 17 - "Foundation Utilities"
Cohesion: 0.25
Nodes (3): Foundation, AppMetadata, String

### Community 18 - "Package Tests and Dependencies"
Cohesion: 0.29
Nodes (4): Photos, PhotosLibrarySortHelper, Vision, XCTest

### Community 19 - "App Entry"
Cohesion: 0.50
Nodes (3): App, PhotosLibrarySortHelperApp, Scene

## Knowledge Gaps
- **140 isolated node(s):** `PackageDescription`, `about`, `CoreGraphics`, `Darwin`, `ImageIO` (+135 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **31 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ReviewViewModel` connect `Review Workflow` to `Folder Commit Models`, `Photos Album Fetch`, `Review UI Playback`, `Folder Media Loading`, `Media Preview`, `Preferences and Versioning`, `Photo Permissions`, `App Commands and Windows`, `App Storage Paths`, `Core Media Models`, `App Entry`?**
  _High betweenness centrality (0.378) - this node is a cross-community bridge._
- **Why does `PhotoLibraryService` connect `Photos Album Fetch` to `Review Workflow`, `Folder Commit Models`, `Photo Permissions`, `Media Preview`?**
  _High betweenness centrality (0.082) - this node is a cross-community bridge._
- **Why does `CodingKeys` connect `Saved Review Session` to `Review Workflow`, `Foundation Utilities`, `Folder Commit Models`, `Coding Identifiers`?**
  _High betweenness centrality (0.065) - this node is a cross-community bridge._
- **Are the 9 inferred relationships involving `ReviewViewModel` (e.g. with `PhotosLibrarySortHelperApp` and `FolderCommitService`) actually correct?**
  _`ReviewViewModel` has 9 INFERRED edges - model-reasoned connections that need verification._
- **Are the 7 inferred relationships involving `ReviewGroup` (e.g. with `.makeStoredReviewSession()` and `.prefetchNextGroupItems()`) actually correct?**
  _`ReviewGroup` has 7 INFERRED edges - model-reasoned connections that need verification._
- **Are the 5 inferred relationships involving `ReviewItem` (e.g. with `.testChangingSourceRequiresConfirmationAndClearsSessionState()` and `.testFolderCommitPlanAndExecutionPreserveRelativePaths()`) actually correct?**
  _`ReviewItem` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `about`, `CoreGraphics` to the rest of the system?**
  _140 weakly-connected nodes found - possible documentation gaps or missing edges._