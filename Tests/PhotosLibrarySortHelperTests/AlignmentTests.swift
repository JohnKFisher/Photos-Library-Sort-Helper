import Foundation
import Combine
import Photos
import PhotosSortCore
import XCTest
@testable import PhotosLibrarySortHelper

private actor FolderScanTestGate {
    private var hasPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        hasPaused = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !hasPaused else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func resume() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

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
        let plist: [String: Any] = [
            "CFBundleShortVersionString": "2.5.1",
            "CFBundleVersion": "3"
        ]

        let versionInfo = ReleaseVersioning.versionInfo(from: plist)

        XCTAssertEqual(versionInfo?.marketingVersion, "2.5.1")
        XCTAssertEqual(versionInfo?.build, "3")
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

    func testFolderSessionWritesKeepLegacyPhotosSessionReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent(AppPaths.reviewSessionFileName)
        let folderURL = root.appendingPathComponent(AppPaths.folderReviewSessionFileName)
        let legacyData = try minimalSessionData(sourceKind: "photos")
        let folderData = try minimalSessionData(sourceKind: "folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyData.write(to: legacyURL)

        let store = ReviewSessionFileStore(legacyURL: legacyURL, folderURL: folderURL, fileManager: .default)
        try store.saveFolderData(folderData)
        let preferred = try XCTUnwrap(store.loadPreferred())

        XCTAssertEqual(preferred.url, folderURL)
        XCTAssertEqual(preferred.data, folderData)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
    }

    func testLegacyFolderSessionCopiesForwardAndRetainsOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent(AppPaths.reviewSessionFileName)
        let folderURL = root.appendingPathComponent(AppPaths.folderReviewSessionFileName)
        let legacyData = try minimalSessionData(sourceKind: "folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyData.write(to: legacyURL)

        let store = ReviewSessionFileStore(legacyURL: legacyURL, folderURL: folderURL, fileManager: .default)
        let legacy = try XCTUnwrap(store.loadPreferred())
        let copied = try store.copyForwardLegacyFolder(legacy)

        XCTAssertEqual(copied.url, folderURL)
        XCTAssertEqual(copied.data, legacyData)
        XCTAssertEqual(store.loadPreferred()?.url, folderURL)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
    }

    func testStoredPhotosPreferenceDoesNotRestoreFolderSessionOrResetMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent(AppPaths.reviewSessionFileName)
        let folderURL = root.appendingPathComponent(AppPaths.folderReviewSessionFileName)
        let legacyPhotosData = try minimalSessionData(sourceKind: "photos")
        let folderResetMarker = try minimalSessionData(sourceKind: "folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyPhotosData.write(to: legacyURL)
        try folderResetMarker.write(to: folderURL)

        let store = ReviewSessionFileStore(legacyURL: legacyURL, folderURL: folderURL, fileManager: .default)

        XCTAssertNil(store.loadPreferred(selectedSourceKind: .photos, hasStoredSourcePreference: true))
        XCTAssertEqual(store.loadLegacy()?.session.selectedSourceKind, .photos)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyPhotosData)
    }

    func testStoredFolderPreferenceRestoresDedicatedFolderSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent(AppPaths.reviewSessionFileName)
        let folderURL = root.appendingPathComponent(AppPaths.folderReviewSessionFileName)
        let legacyPhotosData = try minimalSessionData(sourceKind: "photos")
        let folderData = try minimalSessionData(sourceKind: "folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyPhotosData.write(to: legacyURL)
        try folderData.write(to: folderURL)

        let store = ReviewSessionFileStore(legacyURL: legacyURL, folderURL: folderURL, fileManager: .default)

        XCTAssertEqual(
            store.loadPreferred(selectedSourceKind: .folder, hasStoredSourcePreference: true)?.url,
            folderURL
        )
    }

    func testFolderSessionStoreRejectsPhotosData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent(AppPaths.reviewSessionFileName)
        let folderURL = root.appendingPathComponent(AppPaths.folderReviewSessionFileName)
        let store = ReviewSessionFileStore(legacyURL: legacyURL, folderURL: folderURL, fileManager: .default)

        XCTAssertThrowsError(try store.saveFolderData(minimalSessionData(sourceKind: "photos")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    private func minimalSessionData(sourceKind: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "groups": [],
            "selectedSourceKind": sourceKind
        ])
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

    func testFolderScanDoesNotPublishFilesAfterAncestorIsReplacedDuringMetadataRead() async throws {
        let source = try makeTemporaryDirectory()
        let parent = source.deletingLastPathComponent()
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let displaced = source.appendingPathComponent("nested-original", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("inside.jpg"))

        let gate = FolderScanTestGate()
        let service = FolderLibraryService(beforeMetadataRead: { await gate.pause() })
        let scanTask = Task {
            try await service.loadReviewItems(
                selection: FolderSelection(resolvedPath: source.path),
                recursive: true,
                includeVideos: true
            )
        }

        await gate.waitUntilPaused()
        try FileManager.default.moveItem(at: nested, to: displaced)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("replacement.jpg"))
        await gate.resume()

        do {
            let listing = try await scanTask.value
            XCTAssertFalse(listing.items.contains { $0.displayName == "replacement.jpg" })
            XCTFail("The scan should reject a tree whose directory changed during metadata loading")
        } catch let error as ReviewError {
            XCTAssertEqual(error, .emptySourceFolder)
        }
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

    func testFolderCommitRejectsSymlinkedSourceAncestorAfterScan() async throws {
        let root = try makeTemporaryDirectory()
        let parent = root.deletingLastPathComponent()
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let displaced = root.appendingPathComponent("nested-original", isDirectory: true)
        let outside = parent.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = nested.appendingPathComponent("photo.jpg")
        let outsideFile = outside.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: source)
        try Data("outside".utf8).write(to: outsideFile)

        let listing = try await FolderLibraryService().loadReviewItems(
            selection: FolderSelection(resolvedPath: root.path),
            recursive: true,
            includeVideos: false
        )
        let scannedItem = try XCTUnwrap(listing.items.first)
        XCTAssertNotNil(scannedItem.fileInodeNumber)

        try FileManager.default.moveItem(at: nested, to: displaced)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)

        let plan = singleItemFolderCommitPlan(
            itemID: scannedItem.id,
            sourceURL: source,
            relativePath: "nested/photo.jpg",
            destination: .manualDeleteQueue,
            device: scannedItem.fileDeviceNumber,
            inode: scannedItem.fileInodeNumber
        )
        let result = try await FolderCommitService().execute(plan: plan, sourceFolderURL: root)

        XCTAssertTrue(result.movedItemIDs.isEmpty)
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside".utf8))
        XCTAssertEqual(try Data(contentsOf: displaced.appendingPathComponent("photo.jpg")), Data("original".utf8))
    }

    func testFolderCommitRejectsRegularFileReplacedAfterScan() async throws {
        let root = try makeTemporaryDirectory()
        let parent = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let source = root.appendingPathComponent("photo.jpg")
        let original = root.appendingPathComponent("photo-original.jpg")
        try Data("reviewed file".utf8).write(to: source)
        let listing = try await FolderLibraryService().loadReviewItems(
            selection: FolderSelection(resolvedPath: root.path),
            recursive: true,
            includeVideos: false
        )
        let scannedItem = try XCTUnwrap(listing.items.first)
        try FileManager.default.moveItem(at: source, to: original)
        try Data("replacement file".utf8).write(to: source)

        let result = try await FolderCommitService().execute(
            plan: singleItemFolderCommitPlan(
                itemID: scannedItem.id,
                sourceURL: source,
                relativePath: "photo.jpg",
                destination: .manualDeleteQueue,
                device: scannedItem.fileDeviceNumber,
                inode: scannedItem.fileInodeNumber
            ),
            sourceFolderURL: root
        )

        XCTAssertTrue(result.movedItemIDs.isEmpty)
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement file".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("reviewed file".utf8))
    }

    func testFolderCommitRejectsSymlinkedDestinationQueue() async throws {
        let root = try makeTemporaryDirectory()
        let parent = root.deletingLastPathComponent()
        let outside = parent.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("photo.jpg")
        try Data("source".utf8).write(to: source)
        let service = FolderCommitService()
        let destinationPaths = service.destinationPaths(for: root)
        try FileManager.default.createSymbolicLink(
            at: destinationPaths.manualDeleteQueueURL,
            withDestinationURL: outside
        )

        let result = try await service.execute(
            plan: singleItemFolderCommitPlan(
                itemID: source.path,
                sourceURL: source,
                relativePath: "photo.jpg",
                destination: .manualDeleteQueue
            ),
            sourceFolderURL: root
        )

        XCTAssertTrue(result.movedItemIDs.isEmpty)
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("photo.jpg").path))
    }

    func testFolderCommitNeverOverwritesAndReportsCollisionRename() async throws {
        let root = try makeTemporaryDirectory()
        let parent = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let source = root.appendingPathComponent("photo.jpg")
        try Data("source".utf8).write(to: source)
        let service = FolderCommitService()
        let destination = service.destinationPaths(for: root).editQueueURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destination.appendingPathComponent("photo.jpg"))

        let result = try await service.execute(
            plan: singleItemFolderCommitPlan(
                itemID: source.path,
                sourceURL: source,
                relativePath: "photo.jpg",
                destination: .editQueue
            ),
            sourceFolderURL: root
        )

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photo.jpg")), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photo (2).jpg")), Data("source".utf8))
        XCTAssertEqual(result.renamedItems.map(\.finalRelativePath), ["photo (2).jpg"])
        XCTAssertFalse(result.hasIssues)
    }

    func testFolderCommitCancellationLeavesUnprocessedFileInSource() async throws {
        let root = try makeTemporaryDirectory()
        let parent = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let source = root.appendingPathComponent("photo.jpg")
        try Data("source".utf8).write(to: source)
        let moving = expectation(description: "commit reached first move")
        let service = FolderCommitService()
        let plan = singleItemFolderCommitPlan(
            itemID: source.path,
            sourceURL: source,
            relativePath: "photo.jpg",
            destination: .editQueue
        )
        let task = Task {
            try await service.execute(
                plan: plan,
                sourceFolderURL: root,
                progress: { progress in
                    guard progress.currentRelativePath != nil else { return }
                    moving.fulfill()
                    try? await Task.sleep(for: .seconds(2))
                }
            )
        }

        await fulfillment(of: [moving], timeout: 2)
        task.cancel()
        let result = try await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.movedItemIDs.isEmpty)
        XCTAssertEqual(result.processedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testUnbatchedPartialFolderCommitReleasesGateBeforeRescanning() async throws {
        let sourceFolder = try makeTemporaryDirectory()
        let parent = sourceFolder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let firstURL = sourceFolder.appendingPathComponent("first.jpg")
        let secondURL = sourceFolder.appendingPathComponent("second.jpg")
        let thirdURL = sourceFolder.appendingPathComponent("third.jpg")
        let fourthURL = sourceFolder.appendingPathComponent("fourth.jpg")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        try Data("third".utf8).write(to: thirdURL)
        try Data("fourth".utf8).write(to: fourthURL)

        let folderSessionStore = ReviewSessionFileStore(
            legacyURL: parent.appendingPathComponent("legacy-review.json"),
            folderURL: parent.appendingPathComponent("folder-review.json"),
            fileManager: .default
        )

        let listing = try await FolderLibraryService().loadReviewItems(
            selection: FolderSelection(resolvedPath: sourceFolder.path),
            recursive: true,
            includeVideos: false
        )
        let firstItem = try XCTUnwrap(listing.items.first { $0.absolutePath == firstURL.path })
        let secondItem = try XCTUnwrap(listing.items.first { $0.absolutePath == secondURL.path })
        let thirdItem = try XCTUnwrap(listing.items.first { $0.absolutePath == thirdURL.path })
        let fourthItem = try XCTUnwrap(listing.items.first { $0.absolutePath == fourthURL.path })
        let editIDs: Set<String> = [firstItem.id, secondItem.id, fourthItem.id]
        let explicitKeepItem = thirdItem

        let reviewStore = try SQLiteReviewStore(url: parent.appendingPathComponent("review-state.sqlite"))
        let viewModel = ReviewViewModel(
            photoReviewStore: reviewStore,
            usesUserPersistence: false,
            reviewSessionFileStore: folderSessionStore
        )
        viewModel.selectedSourceKind = .folder
        viewModel.folderSelection = FolderSelection(resolvedPath: sourceFolder.path)
        viewModel.requestScan()
        let initialScanDeadline = Date().addingTimeInterval(5)
        while Date() < initialScanDeadline {
            if !viewModel.isPreparingScan && !viewModel.isScanning,
               Set(viewModel.groups.flatMap(\.itemIDs)) == Set([firstItem.id, secondItem.id, thirdItem.id, fourthItem.id]) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(viewModel.groups.flatMap(\.itemIDs)), Set([firstItem.id, secondItem.id, thirdItem.id, fourthItem.id]))
        for (groupIndex, group) in viewModel.groups.enumerated() {
            viewModel.currentGroupIndex = groupIndex
            for editID in editIDs.intersection(Set(group.itemIDs)) {
                viewModel.setHighlighted(assetID: editID, in: group)
                viewModel.queueHighlightedAssetForEditingInCurrentGroup()
            }
            if group.itemIDs.contains(explicitKeepItem.id) {
                viewModel.toggleKeep(assetID: explicitKeepItem.id, in: group)
            }
            viewModel.markGroupReviewed(group)
        }

        let sourceURLByID = [
            firstItem.id: firstURL,
            secondItem.id: secondURL,
            thirdItem.id: thirdURL,
            fourthItem.id: fourthURL
        ]
        var replacedEditID: String?
        var replacementError: Error?
        let cancelAfterFirstMove = viewModel.$folderCommitProgress.sink { progress in
            guard progress?.movedCount == 1,
                  replacedEditID == nil,
                  let movedPath = progress?.lastProcessedRelativePath,
                  let movedID = sourceURLByID.first(where: { $0.value.lastPathComponent == movedPath })?.key,
                  let targetEditID = editIDs.subtracting([movedID]).sorted().first,
                  let targetURL = sourceURLByID[targetEditID]
            else { return }

            viewModel.cancelFolderCommit()
            do {
                let displacedURL = sourceFolder.deletingLastPathComponent()
                    .appendingPathComponent("replaced-edit-\(UUID().uuidString).jpg")
                try FileManager.default.moveItem(at: targetURL, to: displacedURL)
                try Data("replacement".utf8).write(to: targetURL)
                replacedEditID = targetEditID
            } catch {
                replacementError = error
            }
        }
        viewModel.queueMarkedAssetsForManualDelete()

        let scanDeadline = Date().addingTimeInterval(5)
        while Date() < scanDeadline {
            let scanFinished = !viewModel.isDeleting
                && !viewModel.isPreparingScan
                && !viewModel.isScanning
                && (viewModel.scanStatusMessage.hasPrefix("Found ")
                    || viewModel.scanStatusMessage.hasPrefix("No similar groups found"))
            if scanFinished { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(viewModel.isDeleting)
        XCTAssertFalse(viewModel.isPreparingScan)
        XCTAssertFalse(viewModel.isScanning)
        let remainingIDs = Set(sourceURLByID.compactMap { id, url in
            FileManager.default.fileExists(atPath: url.path) ? id : nil
        })
        XCTAssertNil(replacementError)
        let replacedID = try XCTUnwrap(replacedEditID)
        let originalReplacedItem = try XCTUnwrap([firstItem, secondItem, fourthItem].first { $0.id == replacedID })
        let refreshedListing = try await FolderLibraryService().loadReviewItems(
            selection: FolderSelection(resolvedPath: sourceFolder.path),
            recursive: true,
            includeVideos: false
        )
        let refreshedReplacement = try XCTUnwrap(refreshedListing.items.first { $0.id == replacedID })
        XCTAssertNotEqual(refreshedReplacement.fileInodeNumber, originalReplacedItem.fileInodeNumber)
        XCTAssertEqual(remainingIDs.count, 3)
        XCTAssertEqual(Set(viewModel.groups.flatMap(\.itemIDs)), remainingIDs)

        let remainingEditIDs = remainingIDs.intersection(editIDs)
        XCTAssertEqual(remainingEditIDs.count, 2)
        XCTAssertFalse(viewModel.queuedForEditItemIDs.contains(replacedID))
        XCTAssertFalse(viewModel.isExplicitKeep(
            assetID: replacedID,
            in: try XCTUnwrap(viewModel.groups.first { $0.itemIDs.contains(replacedID) })
        ))
        let unchangedEditID = try XCTUnwrap(remainingEditIDs.subtracting([replacedID]).first)
        let unchangedEditGroup = try XCTUnwrap(viewModel.groups.first { $0.itemIDs.contains(unchangedEditID) })
        XCTAssertTrue(viewModel.queuedForEditItemIDs.contains(unchangedEditID))
        XCTAssertEqual(viewModel.reviewStatusLabel(assetID: unchangedEditID, in: unchangedEditGroup), "EDIT")

        XCTAssertTrue(remainingIDs.contains(explicitKeepItem.id))
        let keepGroup = try XCTUnwrap(viewModel.groups.first { $0.itemIDs.contains(explicitKeepItem.id) })
        XCTAssertTrue(viewModel.isExplicitKeep(assetID: explicitKeepItem.id, in: keepGroup))
        XCTAssertEqual(viewModel.reviewStatusLabel(assetID: explicitKeepItem.id, in: keepGroup), "KEEP")

        let movedEditID = try XCTUnwrap(editIDs.subtracting(remainingIDs).first)
        let movedRelativePath = URL(fileURLWithPath: try XCTUnwrap(sourceURLByID[movedEditID]?.path)).lastPathComponent
        let queuedURL = FolderCommitService().destinationPaths(for: sourceFolder).editQueueURL
            .appending(path: movedRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queuedURL.path))

        let durableEntry = try XCTUnwrap(folderSessionStore.loadPreferred(
            selectedSourceKind: .folder,
            hasStoredSourcePreference: true
        ))
        XCTAssertEqual(durableEntry.session.queuedForEditItemIDs, [unchangedEditID])
        XCTAssertTrue(durableEntry.session.reviewDecisionsByGroup.values.contains {
            $0.explicitKeepIDs.contains(explicitKeepItem.id)
        })
        cancelAfterFirstMove.cancel()
    }

    @MainActor
    func testFailedFolderRescanRestoresReviewAndKeepsDurableSessionForRelaunch() async throws {
        let sourceFolder = try makeTemporaryDirectory()
        let parent = sourceFolder.deletingLastPathComponent()
        let displacedFolder = parent.appendingPathComponent("source-displaced-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let firstURL = sourceFolder.appendingPathComponent("first.jpg")
        let secondURL = sourceFolder.appendingPathComponent("second.jpg")
        let keepURL = sourceFolder.appendingPathComponent("keep.jpg")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        try Data("keep".utf8).write(to: keepURL)

        let folderSessionStore = ReviewSessionFileStore(
            legacyURL: parent.appendingPathComponent("legacy-review.json"),
            folderURL: parent.appendingPathComponent("folder-review.json"),
            fileManager: .default
        )
        let reviewStore = try SQLiteReviewStore(url: parent.appendingPathComponent("review-state.sqlite"))
        let viewModel = ReviewViewModel(
            photoReviewStore: reviewStore,
            usesUserPersistence: false,
            reviewSessionFileStore: folderSessionStore
        )
        viewModel.selectedSourceKind = .folder
        viewModel.folderSelection = FolderSelection(resolvedPath: sourceFolder.path)
        viewModel.requestScan()

        let initialListing = try await FolderLibraryService().loadReviewItems(
            selection: FolderSelection(resolvedPath: sourceFolder.path),
            recursive: true,
            includeVideos: false
        )
        let firstItem = try XCTUnwrap(initialListing.items.first { $0.absolutePath == firstURL.path })
        let secondItem = try XCTUnwrap(initialListing.items.first { $0.absolutePath == secondURL.path })
        let keepItem = try XCTUnwrap(initialListing.items.first { $0.absolutePath == keepURL.path })
        let editIDs: Set<String> = [firstItem.id, secondItem.id]
        let initialIDs = Set([firstItem.id, secondItem.id, keepItem.id])

        let initialScanDeadline = Date().addingTimeInterval(5)
        while Date() < initialScanDeadline {
            if !viewModel.isPreparingScan && !viewModel.isScanning,
               Set(viewModel.groups.flatMap(\.itemIDs)) == initialIDs {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(viewModel.groups.flatMap(\.itemIDs)), initialIDs)

        for (groupIndex, group) in viewModel.groups.enumerated() {
            viewModel.currentGroupIndex = groupIndex
            for editID in editIDs.intersection(Set(group.itemIDs)) {
                viewModel.setHighlighted(assetID: editID, in: group)
                viewModel.queueHighlightedAssetForEditingInCurrentGroup()
            }
            if group.itemIDs.contains(keepItem.id) {
                viewModel.toggleKeep(assetID: keepItem.id, in: group)
            }
            viewModel.markGroupReviewed(group)
        }

        var relocatedSource = false
        let cancelAndBreakSourceRoot = viewModel.$folderCommitProgress.sink { progress in
            guard progress?.movedCount == 1, !relocatedSource else { return }
            relocatedSource = true
            viewModel.cancelFolderCommit()
            do {
                try FileManager.default.moveItem(at: sourceFolder, to: displacedFolder)
                try FileManager.default.createSymbolicLink(at: sourceFolder, withDestinationURL: displacedFolder)
            } catch {
                XCTFail("Could not replace the selected folder root for the rescan failure test: \(error)")
            }
        }
        viewModel.queueMarkedAssetsForManualDelete()

        let failureDeadline = Date().addingTimeInterval(5)
        while Date() < failureDeadline {
            if !viewModel.isDeleting && !viewModel.isPreparingScan && !viewModel.isScanning,
               viewModel.scanStatusMessage.hasPrefix("Folder scan failed") {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(relocatedSource)
        XCTAssertTrue(viewModel.scanStatusMessage.hasPrefix("Folder scan failed"))
        XCTAssertEqual(Set(viewModel.groups.flatMap(\.itemIDs)), Set([secondItem.id, keepItem.id]))
        let editGroup = try XCTUnwrap(viewModel.groups.first { $0.itemIDs.contains(secondItem.id) })
        XCTAssertTrue(viewModel.queuedForEditItemIDs.contains(secondItem.id))
        XCTAssertEqual(viewModel.reviewStatusLabel(assetID: secondItem.id, in: editGroup), "EDIT")
        let keepGroup = try XCTUnwrap(viewModel.groups.first { $0.itemIDs.contains(keepItem.id) })
        XCTAssertTrue(viewModel.isExplicitKeep(assetID: keepItem.id, in: keepGroup))

        let durableEntry = try XCTUnwrap(folderSessionStore.loadPreferred(
            selectedSourceKind: .folder,
            hasStoredSourcePreference: true
        ))
        XCTAssertEqual(durableEntry.session.selectedSourceKind, .folder)
        XCTAssertEqual(durableEntry.session.queuedForEditItemIDs, editIDs)
        XCTAssertTrue(durableEntry.session.reviewDecisionsByGroup.values.contains { $0.explicitKeepIDs.contains(keepItem.id) })

        let relaunchedViewModel = ReviewViewModel(
            photoReviewStore: reviewStore,
            usesUserPersistence: false,
            reviewSessionFileStore: folderSessionStore
        )
        relaunchedViewModel.authorizationStatus = .notDetermined
        await relaunchedViewModel.bootstrap()
        XCTAssertTrue(relaunchedViewModel.queuedForEditItemIDs.contains(secondItem.id))
        XCTAssertEqual(Set(relaunchedViewModel.groups.flatMap(\.itemIDs)), Set([secondItem.id, keepItem.id]))
        let relaunchedKeepGroup = try XCTUnwrap(relaunchedViewModel.groups.first { $0.itemIDs.contains(keepItem.id) })
        XCTAssertTrue(relaunchedViewModel.isExplicitKeep(assetID: keepItem.id, in: relaunchedKeepGroup))

        cancelAndBreakSourceRoot.cancel()
    }

    @MainActor
    func testFolderCommitThatEmptiesSourceClearsCompletedReviewSession() async throws {
        let sourceFolder = try makeTemporaryDirectory()
        let parent = sourceFolder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let sourceURLs = (1...3).map { sourceFolder.appendingPathComponent("item-\($0).jpg") }
        for (index, url) in sourceURLs.enumerated() {
            try Data("image-\(index)".utf8).write(to: url)
        }

        let folderSessionStore = ReviewSessionFileStore(
            legacyURL: parent.appendingPathComponent("legacy-review.json"),
            folderURL: parent.appendingPathComponent("folder-review.json"),
            fileManager: .default
        )
        let reviewStore = try SQLiteReviewStore(url: parent.appendingPathComponent("review-state.sqlite"))
        let viewModel = ReviewViewModel(
            photoReviewStore: reviewStore,
            usesUserPersistence: false,
            reviewSessionFileStore: folderSessionStore
        )
        viewModel.selectedSourceKind = .folder
        viewModel.folderSelection = FolderSelection(resolvedPath: sourceFolder.path)
        viewModel.requestScan()

        let initialScanDeadline = Date().addingTimeInterval(5)
        while Date() < initialScanDeadline {
            if !viewModel.isPreparingScan && !viewModel.isScanning,
               Set(viewModel.groups.flatMap(\.itemIDs)).count == sourceURLs.count {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(viewModel.groups.flatMap(\.itemIDs)).count, sourceURLs.count)

        for (groupIndex, group) in viewModel.groups.enumerated() {
            viewModel.currentGroupIndex = groupIndex
            for itemID in group.itemIDs {
                viewModel.setHighlighted(assetID: itemID, in: group)
                viewModel.queueHighlightedAssetForEditingInCurrentGroup()
            }
            viewModel.markGroupReviewed(group)
        }

        viewModel.queueMarkedAssetsForManualDelete()
        let completionDeadline = Date().addingTimeInterval(10)
        while Date() < completionDeadline {
            if !viewModel.isDeleting && !viewModel.isPreparingScan && !viewModel.isScanning,
               viewModel.scanStatusMessage == "Folder scan complete. No reviewable media remain." {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.scanStatusMessage, "Folder scan complete. No reviewable media remain.")
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertTrue(sourceURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let durableEntry = try XCTUnwrap(folderSessionStore.loadPreferred(
            selectedSourceKind: .folder,
            hasStoredSourcePreference: true
        ))
        XCTAssertEqual(durableEntry.session.selectedSourceKind, .folder)
        XCTAssertTrue(durableEntry.session.groups.isEmpty)
        XCTAssertTrue(durableEntry.session.items.isEmpty)
    }

    func testFolderScanHonorsCancellationBeforeEnumeration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let task = Task {
            try await FolderLibraryService().loadReviewItems(
                selection: FolderSelection(resolvedPath: root.path),
                recursive: true,
                includeVideos: true
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testFolderScanRejectsSymbolicLinkAsSelectedRoot() async throws {
        let root = try makeTemporaryDirectory()
        let parent = root.deletingLastPathComponent()
        let alias = parent.appendingPathComponent("source-alias", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        do {
            _ = try await FolderLibraryService().loadReviewItems(
                selection: FolderSelection(resolvedPath: alias.path),
                recursive: true,
                includeVideos: true
            )
            XCTFail("Expected a selected symlink root to be rejected")
        } catch let error as ReviewError {
            XCTAssertEqual(error, .sourceFolderIsSymbolicLink)
        }
    }

    private func singleItemFolderCommitPlan(
        itemID: String,
        sourceURL: URL,
        relativePath: String,
        destination: FolderCommitDestination,
        device: UInt64? = nil,
        inode: UInt64? = nil
    ) -> FolderCommitPlan {
        FolderCommitPlan(
            operations: [FolderCommitOperation(
                itemID: itemID,
                sourceURL: sourceURL,
                relativePath: relativePath,
                destination: destination,
                expectedDeviceNumber: device,
                expectedInodeNumber: inode
            )],
            reviewedGroupCount: 1,
            editQueueCount: destination == .editQueue ? 1 : 0,
            manualDeleteCount: destination == .manualDeleteQueue ? 1 : 0,
            keepCount: destination == .keep ? 1 : 0,
            editQueueSamples: destination == .editQueue ? [relativePath] : [],
            manualDeleteSamples: destination == .manualDeleteQueue ? [relativePath] : [],
            keepSamples: destination == .keep ? [relativePath] : []
        )
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
    func testQueueHighlightedPhotoForEditingStaysLocalUntilCommit() throws {
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

        try withPhotosTestModel(group) { viewModel, _, _ in
            viewModel.highlightedItemByGroup = [group.id: item.id]

            viewModel.queueHighlightedAssetForEditingInCurrentGroup()

            XCTAssertTrue(viewModel.isQueuedForEdit(assetID: item.id))
            XCTAssertEqual(viewModel.reviewStatusLabel(assetID: item.id, in: group), "EDIT")
            XCTAssertEqual(viewModel.reviewStateDescription(assetID: item.id, in: group), "Explicit Edit")
            XCTAssertEqual(viewModel.editQueueCountTotal, 1)
            XCTAssertEqual(viewModel.editQueueMessage, "Selected item will queue to \"Files to Edit\" when you commit.")

            viewModel.queueHighlightedAssetForEditingInCurrentGroup()

            XCTAssertFalse(viewModel.isQueuedForEdit(assetID: item.id))
            XCTAssertEqual(viewModel.reviewStatusLabel(assetID: item.id, in: group), "KEEP")
            XCTAssertEqual(viewModel.editQueueCountTotal, 0)
            XCTAssertEqual(viewModel.editQueueMessage, "Removed selected item from the Photos edit queue.")
        }
    }

    @MainActor
    func testPhotoQueuePlanSeparatesEditItemsFromKeepAndDiscard() throws {
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

        try withPhotosTestModel(group) { viewModel, store, snapshot in
            try store.setExplicitDecision(libraryKey: "system-photo-library", assetID: keepItem.id, decision: .keep, scopeID: snapshot.scopeID, groupID: snapshot.id)
            try store.setExplicitDecision(libraryKey: "system-photo-library", assetID: discardItem.id, decision: .discard, scopeID: snapshot.scopeID, groupID: snapshot.id)
            try store.setExplicitDecision(libraryKey: "system-photo-library", assetID: editItem.id, decision: .edit, scopeID: snapshot.scopeID, groupID: snapshot.id)
            viewModel.reloadPhotoPendingItems()

            let plan = viewModel.photoQueuePlan()

            XCTAssertEqual(plan.keepIDs, [keepItem.id])
            XCTAssertEqual(plan.discardIDs, [discardItem.id])
            XCTAssertEqual(plan.editIDs, [editItem.id])
        }
    }

    @MainActor
    func testPhotoGroupHistoryRestoresLegacyIdentityOnlyForExactMembershipAndFingerprint() throws {
        try assertPhotoGroupRestoration(
            priorFingerprint: "\(TemporalGrouping.fingerprint(maxGapSeconds: 8))|videos=false",
            expectedCompleted: true
        )
        try assertPhotoGroupRestoration(
            priorFingerprint: "obsolete-grouping",
            expectedCompleted: false
        )
    }

    @MainActor
    func testChangingSourceRequiresConfirmationAndClearsSessionState() {
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
        viewModel.reviewedGroupIDs = [group.id]
        viewModel.reviewDecisionsByGroup = [
            group.id: ReviewGroupDecisions(explicitKeepIDs: [item.id])
        ]

        viewModel.requestSourceKindChange(.folder)

        XCTAssertTrue(viewModel.showSourceResetConfirmation)
        XCTAssertEqual(viewModel.selectedSourceKind, .photos)
        XCTAssertEqual(viewModel.groups, [group])

        viewModel.confirmSourceKindChange()

        XCTAssertFalse(viewModel.showSourceResetConfirmation)
        XCTAssertEqual(viewModel.selectedSourceKind, .folder)
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertTrue(viewModel.reviewedGroupIDs.isEmpty)
        XCTAssertTrue(viewModel.reviewDecisionsByGroup.isEmpty)
        XCTAssertEqual(viewModel.scannedAssetCount, 0)
        XCTAssertEqual(viewModel.temporalClusterCount, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return source
    }

    @MainActor
    private func assertPhotoGroupRestoration(priorFingerprint: String, expectedCompleted: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var store: SQLiteReviewStore? = try SQLiteReviewStore(url: directory.appendingPathComponent("review-state.sqlite"))
        var viewModel: ReviewViewModel? = ReviewViewModel(photoReviewStore: store, usesUserPersistence: false)
        defer {
            viewModel = nil
            store = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let reviewStore = try XCTUnwrap(store)
        let model = try XCTUnwrap(viewModel)
        let group = ReviewGroup(
            id: UUID(),
            itemIDs: ["asset-a", "asset-b"],
            startDate: Date(timeIntervalSince1970: 1),
            endDate: Date(timeIntervalSince1970: 2)
        )
        let settings = ScanSettings(
            reviewMode: .discardFirst,
            selectedSourceKind: .photos,
            sourceMode: .allPhotos,
            selectedAlbumID: nil,
            folderSelection: nil,
            folderRecursiveScan: true,
            moveKeptItemsToKeepFolder: false,
            dateFrom: nil,
            dateTo: nil,
            includeVideos: false,
            maxTimeGapSeconds: 8,
            similarityDistanceThreshold: 12,
            groupLimit: nil
        )
        let scope = model.scopeID(for: settings)
        let legacyID = UUID().uuidString.lowercased()
        try reviewStore.save(group: ReviewGroupSnapshot(
            id: legacyID,
            scopeID: scope,
            position: 0,
            itemIDs: group.itemIDs,
            startDate: group.startDate,
            endDate: group.endDate,
            groupingFingerprint: priorFingerprint,
            state: .completed
        ))
        try reviewStore.save(position: ScopePosition(
            id: scope,
            currentGroupID: legacyID,
            currentItemID: "asset-a",
            fallbackGroupIndex: 0,
            groupingFingerprint: priorFingerprint
        ))

        model.selectedSourceKind = .photos
        model.groups = [group]
        try model.restorePhotoGroups(for: settings)

        XCTAssertEqual(model.isGroupReviewed(group), expectedCompleted)
        XCTAssertEqual(model.currentGroupIndex, 0)
    }

    @MainActor
    private func withPhotosTestModel(
        _ group: ReviewGroup,
        body: (ReviewViewModel, SQLiteReviewStore, ReviewGroupSnapshot) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("review-state.sqlite")
        var store: SQLiteReviewStore? = try SQLiteReviewStore(url: databaseURL)
        var viewModel: ReviewViewModel? = ReviewViewModel(photoReviewStore: store, usesUserPersistence: false)
        defer {
            viewModel = nil
            store = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let model = try XCTUnwrap(viewModel)
        let reviewStore = try XCTUnwrap(store)
        model.selectedSourceKind = .photos
        model.groups = [group]
        model.currentGroupIndex = 0
        let settings = ScanSettings(
            reviewMode: .discardFirst,
            selectedSourceKind: .photos,
            sourceMode: .allPhotos,
            selectedAlbumID: nil,
            folderSelection: nil,
            folderRecursiveScan: true,
            moveKeptItemsToKeepFolder: false,
            dateFrom: nil,
            dateTo: nil,
            includeVideos: false,
            maxTimeGapSeconds: 8,
            similarityDistanceThreshold: 12,
            groupLimit: nil
        )
        try model.restorePhotoGroups(for: settings)
        let snapshot = try XCTUnwrap(reviewStore.groups(scopeID: model.scopeID(for: settings)).first)
        try body(model, reviewStore, snapshot)
    }
}
