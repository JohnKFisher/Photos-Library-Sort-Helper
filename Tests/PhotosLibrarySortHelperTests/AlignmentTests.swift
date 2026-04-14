import Foundation
import Photos
import XCTest
@testable import PhotosLibrarySortHelper

final class AlignmentTests: XCTestCase {
    func testReleaseVersioningIncrementsPatchAndBuild() {
        let incremented = ReleaseVersioning.incrementedReleaseVersion(
            marketingVersion: "2.1.0",
            build: "7"
        )

        XCTAssertEqual(incremented?.marketingVersion, "2.1.1")
        XCTAssertEqual(incremented?.build, "8")
    }

    func testReleaseVersioningRejectsInvalidMarketingVersion() {
        XCTAssertNil(ReleaseVersioning.incrementedReleaseVersion(marketingVersion: "2.1", build: "7"))
        XCTAssertNil(ReleaseVersioning.incrementedReleaseVersion(marketingVersion: "2.1.x", build: "7"))
    }

    func testVersionInfoReadsFromInfoPlistDictionary() throws {
        let plistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])

        let versionInfo = ReleaseVersioning.versionInfo(from: plist)

        XCTAssertEqual(versionInfo?.marketingVersion, "2.5.0")
        XCTAssertEqual(versionInfo?.build, "2")
    }

    func testScanPreferencesStoreMigratesDefaultsIntoInspectableFile() throws {
        let suiteName = "PhotosLibrarySortHelperTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bundleIdentifier = "com.jkfisher.photoslibrarysorthelper.tests.\(UUID().uuidString)"
        let store = ScanPreferencesStore(
            bundleIdentifier: bundleIdentifier,
            fileManager: .default,
            defaults: defaults
        )

        let legacyPreferences = """
        {
          "useDateRange": true,
          "rangeStartDate": "2026-03-01T00:00:00Z",
          "rangeEndDate": "2026-03-31T00:00:00Z",
          "includeVideos": true,
          "autoplayPreviewVideos": true,
          "maxTimeGapSeconds": 11,
          "maxAssetsToScan": 1500
        }
        """

        defaults.set(Data(legacyPreferences.utf8), forKey: ScanPreferencesStore.currentDefaultsKey)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.reviewMode, .discardFirst)
        XCTAssertEqual(loaded.selectedSourceKind, .photos)
        XCTAssertTrue(loaded.useDateRange)
        XCTAssertTrue(loaded.includeVideos)
        XCTAssertTrue(loaded.autoplayPreviewVideos)
        XCTAssertEqual(loaded.maxTimeGapSeconds, 11)
        XCTAssertEqual(loaded.maxAssetsToScan, 1500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
    }

    func testScanPreferencesStorePersistsRecentFolders() throws {
        let bundleIdentifier = "com.jkfisher.photoslibrarysorthelper.tests.\(UUID().uuidString)"
        let store = ScanPreferencesStore(bundleIdentifier: bundleIdentifier)
        defer {
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }

        let preferences = StoredScanPreferences(
            reviewMode: .keepFirst,
            selectedSourceKind: .folder,
            sourceMode: .allPhotos,
            selectedAlbumID: nil,
            folderSelection: FolderSelection(resolvedPath: "/tmp/source"),
            recentFolders: [
                FolderSelection(resolvedPath: "/tmp/source"),
                FolderSelection(resolvedPath: "/tmp/archive")
            ],
            folderRecursiveScan: true,
            moveKeptItemsToKeepFolder: true,
            useDateRange: false,
            rangeStartDate: Date(timeIntervalSince1970: 100),
            rangeEndDate: Date(timeIntervalSince1970: 200),
            includeVideos: true,
            autoplayPreviewVideos: false,
            maxTimeGapSeconds: 9,
            maxAssetsToScan: 500
        )

        store.save(preferences)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.reviewMode, .keepFirst)
        XCTAssertEqual(loaded.recentFolders.map(\.resolvedPath), ["/tmp/source", "/tmp/archive"])
        XCTAssertEqual(loaded.folderSelection?.resolvedPath, "/tmp/source")
        XCTAssertTrue(loaded.moveKeptItemsToKeepFolder)
    }

    func testStoredReviewSessionDecodesLegacyPhotosSession() throws {
        let groupID = UUID()
        let itemID = "asset-1"
        let legacyJSON: [String: Any] = [
            "groups": [
                [
                    "id": groupID.uuidString,
                    "assetIDs": [itemID],
                    "startDate": "2026-03-20T00:00:00Z",
                    "endDate": "2026-03-20T00:00:00Z"
                ]
            ],
            "currentGroupIndex": 0,
            "currentGroupID": groupID.uuidString,
            "currentHighlightedAssetID": itemID,
            "keepSelectionsByGroup": [groupID.uuidString: [itemID]],
            "highlightedAssetByGroup": [groupID.uuidString: itemID],
            "reviewedGroupIDs": [groupID.uuidString],
            "scannedAssetCount": 1,
            "temporalClusterCount": 1,
            "sourceMode": "allPhotos",
            "useDateRange": false,
            "rangeStartDate": "2026-03-20T00:00:00Z",
            "rangeEndDate": "2026-03-20T00:00:00Z",
            "includeVideos": false,
            "autoplayPreviewVideos": false,
            "maxTimeGapSeconds": 8,
            "similarityDistanceThreshold": 12,
            "autoPickBestShot": true
        ]

        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON, options: [.prettyPrinted])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StoredReviewSession.self, from: legacyData)

        XCTAssertEqual(decoded.selectedSourceKind, .photos)
        XCTAssertEqual(decoded.reviewMode, .discardFirst)
        XCTAssertEqual(decoded.groups.count, 1)
        XCTAssertEqual(decoded.groups[0].itemIDs, [itemID])
        XCTAssertEqual(decoded.currentHighlightedItemID, itemID)
        XCTAssertEqual(decoded.reviewDecisionsByGroup[groupID]?.explicitKeepIDs, Set([itemID]))
        XCTAssertEqual(decoded.reviewDecisionsByGroup[groupID]?.explicitDiscardIDs, Set<String>())
    }

    func testFolderScanRecursesAndSkipsHiddenUnsupportedPackagesAndSymlinks() async throws {
        let root = try makeTemporaryDirectory()
        let symlinkSource = root.deletingLastPathComponent().appendingPathComponent("linked-source", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: symlinkSource)
        }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let packageURL = root.appendingPathComponent("Example.app", isDirectory: true)
        let hiddenFile = root.appendingPathComponent(".secret.jpg")
        let imageURL = nested.appendingPathComponent("photo.jpg")
        let videoURL = root.appendingPathComponent("clip.mov")
        let textURL = root.appendingPathComponent("notes.txt")
        let symlinkURL = root.appendingPathComponent("linked-alias", isDirectory: true)

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: symlinkSource, withIntermediateDirectories: true)
        try Data().write(to: hiddenFile)
        try Data().write(to: imageURL)
        try Data().write(to: videoURL)
        try Data().write(to: textURL)
        try Data().write(to: packageURL.appendingPathComponent("inside.jpg"))
        try Data().write(to: symlinkSource.appendingPathComponent("outside.jpg"))
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkSource)

        let service = FolderLibraryService()
        let listing = try await service.loadReviewItems(
            selection: FolderSelection(resolvedPath: root.path),
            recursive: true,
            includeVideos: true
        )

        XCTAssertEqual(Set(listing.items.map(\.displayName)), ["clip.mov", "photo.jpg"])
        XCTAssertEqual(listing.skippedHiddenCount, 1)
        XCTAssertEqual(listing.skippedUnsupportedCount, 1)
        XCTAssertEqual(listing.skippedPackageCount, 1)
        XCTAssertEqual(listing.skippedSymlinkDirectoryCount, 1)
    }

    func testFolderCommitPlanAndExecutionPreserveRelativePaths() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let discardURL = nested.appendingPathComponent("discard.jpg")
        let editURL = root.appendingPathComponent("edit.mov")
        try Data("discard".utf8).write(to: discardURL)
        try Data("edit".utf8).write(to: editURL)

        let discardItem = ReviewItem(
            id: discardURL.path,
            source: .file(path: discardURL.path, relativePath: "nested/discard.jpg"),
            displayName: "discard.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 7,
            badgeLabels: ["IMAGE", "JPG"],
            detailLabel: nil
        )
        let editItem = ReviewItem(
            id: editURL.path,
            source: .file(path: editURL.path, relativePath: "edit.mov"),
            displayName: "edit.mov",
            mediaKind: .video,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 4,
            badgeLabels: ["VIDEO", "MOV"],
            detailLabel: nil
        )

        let group = ReviewGroup(itemIDs: [discardItem.id, editItem.id], startDate: nil, endDate: nil)
        let service = FolderCommitService()
        let plan = service.buildCommitPlan(
            itemLookup: [discardItem.id: discardItem, editItem.id: editItem],
            groups: [group],
            reviewedGroupIDs: [group.id],
            reviewMode: .discardFirst,
            reviewDecisionsByGroup: [group.id: ReviewGroupDecisions(explicitKeepIDs: [editItem.id])],
            queuedForEditItemIDs: [editItem.id],
            moveKeptItemsToKeepFolder: false
        )

        XCTAssertEqual(plan.manualDeleteCount, 1)
        XCTAssertEqual(plan.editQueueCount, 1)
        XCTAssertEqual(plan.keepCount, 0)
        XCTAssertEqual(plan.manualDeleteSamples, ["nested/discard.jpg"])
        XCTAssertEqual(plan.editQueueSamples, ["edit.mov"])

        let result = try await service.execute(plan: plan, sourceFolderURL: root)
        let destinationPaths = service.destinationPaths(for: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: discardURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: editURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationPaths.manualDeleteQueueURL.appendingPathComponent("nested/discard.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationPaths.editQueueURL.appendingPathComponent("edit.mov").path))
        XCTAssertEqual(result.totalMovedCount, 2)
        XCTAssertFalse(result.hasIssues)
    }

    func testKeepFirstFolderCommitMovesOnlyExplicitDecisions() {
        let keepItem = ReviewItem(
            id: "keep",
            source: .file(path: "/tmp/keep.jpg", relativePath: "keep.jpg"),
            displayName: "keep.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 10,
            badgeLabels: ["IMAGE"],
            detailLabel: nil
        )
        let implicitKeepItem = ReviewItem(
            id: "implicit",
            source: .file(path: "/tmp/implicit.jpg", relativePath: "implicit.jpg"),
            displayName: "implicit.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 10,
            badgeLabels: ["IMAGE"],
            detailLabel: nil
        )
        let discardItem = ReviewItem(
            id: "discard",
            source: .file(path: "/tmp/discard.jpg", relativePath: "discard.jpg"),
            displayName: "discard.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 10,
            badgeLabels: ["IMAGE"],
            detailLabel: nil
        )
        let editItem = ReviewItem(
            id: "edit",
            source: .file(path: "/tmp/edit.jpg", relativePath: "edit.jpg"),
            displayName: "edit.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 10,
            badgeLabels: ["IMAGE"],
            detailLabel: nil
        )

        let group = ReviewGroup(itemIDs: [keepItem.id, implicitKeepItem.id, discardItem.id, editItem.id], startDate: nil, endDate: nil)
        let service = FolderCommitService()
        let plan = service.buildCommitPlan(
            itemLookup: [
                keepItem.id: keepItem,
                implicitKeepItem.id: implicitKeepItem,
                discardItem.id: discardItem,
                editItem.id: editItem
            ],
            groups: [group],
            reviewedGroupIDs: [group.id],
            reviewMode: .keepFirst,
            reviewDecisionsByGroup: [
                group.id: ReviewGroupDecisions(
                    explicitKeepIDs: [keepItem.id, editItem.id],
                    explicitDiscardIDs: [discardItem.id]
                )
            ],
            queuedForEditItemIDs: [editItem.id],
            moveKeptItemsToKeepFolder: true
        )

        XCTAssertEqual(plan.keepCount, 1)
        XCTAssertEqual(plan.manualDeleteCount, 1)
        XCTAssertEqual(plan.editQueueCount, 1)
        XCTAssertEqual(plan.totalMoveCount, 3)
        XCTAssertEqual(plan.keepSamples, ["keep.jpg"])
        XCTAssertEqual(plan.manualDeleteSamples, ["discard.jpg"])
        XCTAssertEqual(plan.editQueueSamples, ["edit.jpg"])
    }

    func testPhotoAuthorizationSupportMessagesMatchStagedFlow() {
        XCTAssertFalse(PhotoAuthorizationSupport.canAccessLibrary(.notDetermined))
        XCTAssertTrue(PhotoAuthorizationSupport.scanActionMessage(for: .notDetermined).contains("start scanning"))
        XCTAssertTrue(PhotoAuthorizationSupport.queueActionMessage(for: .notDetermined).contains("before queueing"))
        XCTAssertTrue(PhotoAuthorizationSupport.accessDescription(for: .limited).contains("Limited access"))
    }

    @MainActor
    func testQueueHighlightedPhotoForEditingStaysLocalUntilCommit() {
        let viewModel = ReviewViewModel()
        let item = ReviewItem(
            id: "photo-1",
            source: .photoAsset(localIdentifier: "photo-1"),
            displayName: "photo-1.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 10,
            badgeLabels: ["IMAGE"],
            detailLabel: nil
        )
        let group = ReviewGroup(itemIDs: [item.id], startDate: nil, endDate: nil)

        viewModel.selectedSourceKind = .photos
        viewModel.groups = [group]
        viewModel.currentGroupIndex = 0
        viewModel.highlightedItemByGroup = [group.id: item.id]
        viewModel.reviewedGroupIDs = [group.id]

        viewModel.queueHighlightedAssetForEditingInCurrentGroup()

        XCTAssertTrue(viewModel.isQueuedForEdit(assetID: item.id))
        XCTAssertEqual(viewModel.reviewStatusLabel(assetID: item.id, in: group), "EDIT")
        XCTAssertEqual(viewModel.reviewStateDescription(assetID: item.id, in: group), "Queued for edit")
        XCTAssertEqual(viewModel.editQueueCountTotal, 1)
        XCTAssertEqual(viewModel.editQueueMessage, "Selected item will queue to \"Files to Edit\" when you commit.")

        viewModel.queueHighlightedAssetForEditingInCurrentGroup()

        XCTAssertFalse(viewModel.isQueuedForEdit(assetID: item.id))
        XCTAssertEqual(viewModel.reviewStatusLabel(assetID: item.id, in: group), "KEEP")
        XCTAssertEqual(viewModel.editQueueCountTotal, 0)
        XCTAssertEqual(viewModel.editQueueMessage, "Removed selected item from the Photos edit queue.")
    }

    @MainActor
    func testPhotoQueuePlanSeparatesEditItemsFromKeepAndDiscard() {
        let viewModel = ReviewViewModel()
        let keepItem = ReviewItem(
            id: "keep",
            source: .photoAsset(localIdentifier: "keep"),
            displayName: "keep.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 10,
            badgeLabels: ["IMAGE"],
            detailLabel: nil
        )
        let discardItem = ReviewItem(
            id: "discard",
            source: .photoAsset(localIdentifier: "discard"),
            displayName: "discard.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 10,
            badgeLabels: ["IMAGE"],
            detailLabel: nil
        )
        let editItem = ReviewItem(
            id: "edit",
            source: .photoAsset(localIdentifier: "edit"),
            displayName: "edit.jpg",
            mediaKind: .image,
            primaryDate: nil,
            fallbackDate: nil,
            byteSize: 10,
            badgeLabels: ["IMAGE"],
            detailLabel: nil
        )
        let group = ReviewGroup(itemIDs: [keepItem.id, discardItem.id, editItem.id], startDate: nil, endDate: nil)

        viewModel.selectedSourceKind = .photos
        viewModel.groups = [group]
        viewModel.reviewedGroupIDs = [group.id]
        viewModel.reviewDecisionsByGroup = [
            group.id: ReviewGroupDecisions(
                explicitKeepIDs: [keepItem.id, editItem.id],
                explicitDiscardIDs: [discardItem.id]
            )
        ]
        viewModel.queuedForEditItemIDs = [editItem.id]

        let plan = viewModel.photoQueuePlan()

        XCTAssertEqual(plan.keepIDs, [keepItem.id])
        XCTAssertEqual(plan.discardIDs, [discardItem.id])
        XCTAssertEqual(plan.editIDs, [editItem.id])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return source
    }
}
