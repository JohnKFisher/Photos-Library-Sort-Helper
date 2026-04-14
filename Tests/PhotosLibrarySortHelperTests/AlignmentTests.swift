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

        XCTAssertEqual(versionInfo?.marketingVersion, "2.1.0")
        XCTAssertEqual(versionInfo?.build, "1")
    }

    func testScanPreferencesStoreMigratesDefaultsIntoInspectableFile() throws {
        let suiteName = "PhotosLibrarySortHelperTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

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
          "autoPickBestShot": true,
          "autoplayPreviewVideos": true,
          "maxTimeGapSeconds": 11,
          "similarityDistanceThreshold": 12,
          "maxAssetsToScan": 1500
        }
        """

        defaults.set(Data(legacyPreferences.utf8), forKey: ScanPreferencesStore.currentDefaultsKey)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertTrue(loaded.useDateRange)
        XCTAssertTrue(loaded.includeVideos)
        XCTAssertTrue(loaded.autoplayPreviewVideos)
        XCTAssertEqual(loaded.maxTimeGapSeconds, 11)
        XCTAssertEqual(loaded.maxAssetsToScan, 1500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
    }

    func testStoredReviewSessionDecodesLegacyBestShotFields() throws {
        let groupID = UUID()
        let assetID = "asset-1"
        let baseline = StoredReviewSession(
            groups: [
                ReviewGroup(
                    id: groupID,
                    assetIDs: [assetID],
                    startDate: Date(timeIntervalSince1970: 1_743_508_800),
                    endDate: Date(timeIntervalSince1970: 1_743_508_800)
                )
            ],
            currentGroupIndex: 0,
            currentGroupID: groupID,
            currentHighlightedAssetID: assetID,
            keepSelectionsByGroup: [groupID: [assetID]],
            highlightedAssetByGroup: [groupID: assetID],
            reviewedGroupIDs: [groupID],
            manuallyEditedGroupIDs: [groupID],
            scannedAssetCount: 1,
            temporalClusterCount: 1,
            sourceMode: .allPhotos,
            selectedAlbumID: nil,
            useDateRange: false,
            rangeStartDate: Date(timeIntervalSince1970: 1_743_465_600),
            rangeEndDate: Date(timeIntervalSince1970: 1_743_465_600),
            includeVideos: false,
            autoplayPreviewVideos: false,
            maxTimeGapSeconds: 8,
            similarityDistanceThreshold: 12
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let baselineData = try encoder.encode(baseline)
        var legacyJSONObject = try XCTUnwrap(JSONSerialization.jsonObject(with: baselineData) as? [String: Any])
        legacyJSONObject["autoPickBestShot"] = true
        legacyJSONObject["suggestedBestAssetByGroup"] = [groupID.uuidString: assetID]
        legacyJSONObject["suggestedDiscardAssetIDsByGroup"] = [String: Any]()
        legacyJSONObject["bestShotScoresByAssetID"] = [
            assetID: [
                "totalScore": 0.8,
                "baseHeuristicScore": 0.7,
                "learnedPreferenceScore": 0.7,
                "learnedAdjustment": 0.1,
                "facePresence": 0.0,
                "framing": 0.0,
                "eyesOpen": 0.0,
                "smile": 0.0,
                "subjectProminence": 0.0,
                "subjectCentering": 0.0,
                "sharpness": 0.0,
                "lighting": 0.0,
                "color": 0.0,
                "contrast": 0.0,
                "usedDeepPass": false
            ]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSONObject, options: [.prettyPrinted])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StoredReviewSession.self, from: legacyData)

        XCTAssertEqual(decoded.groups.count, 1)
        XCTAssertEqual(decoded.currentHighlightedAssetID, assetID)
        XCTAssertEqual(decoded.keepSelectionsByGroup[groupID], [assetID])
        XCTAssertEqual(decoded.similarityDistanceThreshold, 12)
    }

    func testPhotoAuthorizationSupportMessagesMatchStagedFlow() {
        XCTAssertFalse(PhotoAuthorizationSupport.canAccessLibrary(.notDetermined))
        XCTAssertTrue(PhotoAuthorizationSupport.scanActionMessage(for: .notDetermined).contains("start scanning"))
        XCTAssertTrue(PhotoAuthorizationSupport.queueActionMessage(for: .notDetermined).contains("before queueing"))
        XCTAssertTrue(PhotoAuthorizationSupport.accessDescription(for: .limited).contains("Limited access"))
    }
}
