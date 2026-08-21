import Foundation
import XCTest
@testable import PhotosLibrarySortHelper

final class ScanBatchingTests: XCTestCase {
    private func group(_ id: String, _ date: TimeInterval) -> ReviewGroup {
        ReviewGroup(id: UUID(uuidString: id) ?? UUID(), itemIDs: [id], startDate: Date(timeIntervalSince1970: date), endDate: Date(timeIntervalSince1970: date))
    }

    private func item(_ id: String, date: TimeInterval = 1) -> ReviewItem {
        ReviewItem(
            id: id,
            source: .photoAsset(localIdentifier: id),
            displayName: id,
            mediaKind: .image,
            primaryDate: Date(timeIntervalSince1970: date),
            fallbackDate: nil,
            byteSize: 1,
            badgeLabels: [],
            detailLabel: nil
        )
    }

    func testExactPartitionAndFinalHasMoreState() {
        let groups = [group("00000000-0000-0000-0000-000000000003", 3), group("00000000-0000-0000-0000-000000000001", 1), group("00000000-0000-0000-0000-000000000002", 2)]
        let first = ScanBatcher.partition(groups: groups, limit: 2)
        XCTAssertEqual(first.selected.map(\.itemIDs), [["00000000-0000-0000-0000-000000000001"], ["00000000-0000-0000-0000-000000000002"]])
        XCTAssertEqual(first.pending.map(\.itemIDs), [["00000000-0000-0000-0000-000000000003"]])

        let final = ScanBatchCheckpoint(
            sourceKey: "source",
            groupingFingerprint: "settings",
            frozenItems: [],
            pendingGroups: [],
            remainingItemIDs: [],
            batchNumber: 2,
            hasMore: false
        )
        XCTAssertFalse(final.hasMore)
    }

    func testBatchSizeDoesNotChangeGroupingFingerprint() {
        let base = ScanSettings(
            reviewMode: .discardFirst,
            selectedSourceKind: .photos,
            sourceMode: .album,
            selectedAlbumID: "album-id",
            folderSelection: nil,
            folderRecursiveScan: true,
            moveKeptItemsToKeepFolder: false,
            dateFrom: nil,
            dateTo: nil,
            includeVideos: true,
            maxTimeGapSeconds: 8,
            similarityDistanceThreshold: 12,
            groupLimit: 100
        )
        var changedLimit = base
        changedLimit.groupLimit = 250
        XCTAssertEqual(
            ScanBatcher.groupingFingerprint(settings: base),
            ScanBatcher.groupingFingerprint(settings: changedLimit)
        )

        var changedGrouping = base
        changedGrouping.maxTimeGapSeconds = 12
        XCTAssertNotEqual(
            ScanBatcher.groupingFingerprint(settings: base),
            ScanBatcher.groupingFingerprint(settings: changedGrouping)
        )
    }

    func testMalformedAndUnsupportedCheckpointAreDiscardedByStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID().uuidString).json")
        let store = ScanBatchStateStore(fileURL: url)
        defer { store.clear() }
        try Data("{\"version\":999}".utf8).write(to: url)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try Data("not-json".utf8).write(to: url)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCheckpointRoundTripPreservesFrozenWorkAndReadiness() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID().uuidString).json")
        let store = ScanBatchStateStore(fileURL: url)
        defer { store.clear() }
        let checkpoint = ScanBatchCheckpoint(
            sourceKey: "photos|album|one",
            groupingFingerprint: "videos=false|gap=8",
            frozenItems: [item("one"), item("two", date: 2)],
            pendingGroups: [ReviewGroup(itemIDs: ["one"], startDate: Date(timeIntervalSince1970: 1), endDate: Date(timeIntervalSince1970: 1))],
            remainingItemIDs: ["two"],
            batchNumber: 3,
            hasMore: true,
            readyForNextBatch: true
        )
        store.save(checkpoint)
        XCTAssertEqual(store.load(), checkpoint)
    }

    func testScannerContinuesFrozenVideoGroupsWithoutRepeatingOrAddingLiveItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scan-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func video(_ name: String, date: TimeInterval) throws -> ReviewItem {
            let url = directory.appendingPathComponent(name + ".mov")
            try Data().write(to: url)
            return ReviewItem(
                id: name,
                source: .file(path: url.path, relativePath: url.lastPathComponent),
                displayName: url.lastPathComponent,
                mediaKind: .video,
                primaryDate: Date(timeIntervalSince1970: date),
                fallbackDate: nil,
                byteSize: 0,
                badgeLabels: [],
                detailLabel: nil
            )
        }

        let frozen = try [video("one", date: 1), video("two", date: 2), video("three", date: 3)]
        _ = try video("new-live-item", date: 0)
        var settings = ScanSettings(
            reviewMode: .discardFirst,
            selectedSourceKind: .folder,
            sourceMode: .allPhotos,
            selectedAlbumID: nil,
            folderSelection: FolderSelection(resolvedPath: directory.path),
            folderRecursiveScan: true,
            moveKeptItemsToKeepFolder: false,
            dateFrom: nil,
            dateTo: nil,
            includeVideos: true,
            maxTimeGapSeconds: 10,
            similarityDistanceThreshold: 12,
            groupLimit: 2
        )
        let checkpoint = ScanBatchCheckpoint(
            sourceKey: ScanBatcher.makeSourceKey(settings: settings),
            groupingFingerprint: ScanBatcher.groupingFingerprint(settings: settings),
            frozenItems: frozen,
            remainingItemIDs: frozen.map(\.id),
            readyForNextBatch: true
        )
        let scanner = SimilarityScanner(
            photoLibraryService: PhotoLibraryService(),
            folderLibraryService: FolderLibraryService()
        )
        let first = try await scanner.scan(settings: settings, continuation: checkpoint) { _ in }
        XCTAssertEqual(first.groups.flatMap(\.itemIDs), ["one", "two"])
        XCTAssertEqual(first.continuation?.pendingGroups.flatMap(\.itemIDs), ["three"])
        XCTAssertTrue(first.continuation?.hasMore == true)
        XCTAssertFalse(first.groups.flatMap(\.itemIDs).contains("new-live-item"))

        settings.groupLimit = 1
        let second = try await scanner.scan(settings: settings, continuation: try XCTUnwrap(first.continuation)) { _ in }
        XCTAssertEqual(second.groups.flatMap(\.itemIDs), ["three"])
        XCTAssertFalse(second.continuation?.hasMore == true)
        XCTAssertTrue(Set(first.groups.flatMap(\.itemIDs)).isDisjoint(with: second.groups.flatMap(\.itemIDs)))
    }

    func testCheckpointRejectsUnknownAndOverlappingContinuationIDs() throws {
        let checkpoint = ScanBatchCheckpoint(
            sourceKey: "source",
            groupingFingerprint: "settings",
            frozenItems: [item("frozen")],
            hasMore: false
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var overlap = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(checkpoint)) as? [String: Any])
        overlap["pendingGroups"] = [["id": UUID().uuidString, "itemIDs": ["frozen"], "startDate": NSNull(), "endDate": NSNull()]]
        overlap["remainingItemIDs"] = ["frozen"]
        overlap["hasMore"] = true
        XCTAssertThrowsError(try decoder.decode(ScanBatchCheckpoint.self, from: JSONSerialization.data(withJSONObject: overlap)))

        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(checkpoint)) as? [String: Any])
        unknown["remainingItemIDs"] = ["missing"]
        unknown["hasMore"] = true
        XCTAssertThrowsError(try decoder.decode(ScanBatchCheckpoint.self, from: JSONSerialization.data(withJSONObject: unknown)))
    }
}
