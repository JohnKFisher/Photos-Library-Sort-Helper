import Foundation
import PhotosSortCore
import XCTest
@testable import PhotosLibrarySortHelper

final class BundleIdentifierDataMigrationTests: XCTestCase {
    private let oldMacIdentifier = "com.jkfisher.photoslibrarysorthelper"
    private let olderLegacyIdentifier = "com.jkfisher.photosorthelper"
    private let newMacIdentifier = "com.sidelarklabs.photoslibrarysorthelper"

    func testMigrationCopiesWALBackedReviewStateAndPreservesSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleIDMigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent(oldMacIdentifier, isDirectory: true)
        let olderSource = root.appendingPathComponent(olderLegacyIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: olderSource, withIntermediateDirectories: true)

        let sessionData = Data("retained session data".utf8)
        let sessionURL = source.appendingPathComponent(AppPaths.reviewSessionFileName)
        try sessionData.write(to: sessionURL)
        try Data("older legacy session".utf8)
            .write(to: olderSource.appendingPathComponent(AppPaths.legacyReviewSessionFileName))

        let sourceDatabaseURL = source.appendingPathComponent(AppPaths.reviewDatabaseFileName)
        var sourceStore: SQLiteReviewStore? = try SQLiteReviewStore(url: sourceDatabaseURL)
        _ = try sourceStore?.setExplicitDecision(
            libraryKey: "system-photo-library",
            assetID: "photo-pending-in-wal",
            decision: .keep,
            scopeID: "test-scope",
            groupID: "test-group"
        )
        XCTAssertEqual(
            try sourceStore?.pendingItems(libraryKey: "system-photo-library").map(\.assetID),
            ["photo-pending-in-wal"]
        )

        let migration = BundleIdentifierDataMigration(
            applicationSupportRoot: root,
            currentBundleIdentifier: newMacIdentifier,
            formerBundleIdentifiers: [oldMacIdentifier, olderLegacyIdentifier],
            isBundleRunning: { _ in false }
        )

        XCTAssertEqual(try migration.migrateIfNeeded(), .migrated(fromBundleIdentifier: oldMacIdentifier))

        let destination = root.appendingPathComponent(newMacIdentifier, isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(AppPaths.reviewSessionFileName)), sessionData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(AppPaths.legacyReviewSessionFileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDatabaseURL.path))

        let destinationStore = try SQLiteReviewStore(
            url: destination.appendingPathComponent(AppPaths.reviewDatabaseFileName)
        )
        let pending = try destinationStore.pendingItems(libraryKey: "system-photo-library")
        XCTAssertEqual(pending.map(\.assetID), ["photo-pending-in-wal"])
        XCTAssertEqual(pending.first?.decision, .keep)
        XCTAssertEqual(
            try sourceStore?.pendingItems(libraryKey: "system-photo-library").map(\.assetID),
            ["photo-pending-in-wal"]
        )

        XCTAssertEqual(try migration.migrateIfNeeded(), .alreadyMigrated)
        sourceStore = nil
    }

    func testMigrationStopsWhenAnOlderAppIsRunning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleIDMigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent(oldMacIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sessionURL = source.appendingPathComponent(AppPaths.reviewSessionFileName)
        try Data("preserve me".utf8).write(to: sessionURL)

        let migration = BundleIdentifierDataMigration(
            applicationSupportRoot: root,
            currentBundleIdentifier: newMacIdentifier,
            formerBundleIdentifiers: [oldMacIdentifier, olderLegacyIdentifier],
            isBundleRunning: { [oldMacIdentifier] in $0 == oldMacIdentifier }
        )

        XCTAssertThrowsError(try migration.migrateIfNeeded()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Quit the older Photos Library Sort Helper"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(newMacIdentifier).path))
    }

    func testMigrationUsesRetiredIdentifierOnlyWhenFormerCurrentFolderIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleIDMigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let formerCurrent = root.appendingPathComponent(oldMacIdentifier, isDirectory: true)
        let retired = root.appendingPathComponent(olderLegacyIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: formerCurrent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let legacySessionURL = retired.appendingPathComponent(AppPaths.legacyReviewSessionFileName)
        let legacySessionData = Data("retired identifier session".utf8)
        try legacySessionData.write(to: legacySessionURL)

        let migration = BundleIdentifierDataMigration(
            applicationSupportRoot: root,
            currentBundleIdentifier: newMacIdentifier,
            formerBundleIdentifiers: [oldMacIdentifier, olderLegacyIdentifier],
            isBundleRunning: { _ in false }
        )

        XCTAssertEqual(try migration.migrateIfNeeded(), .migrated(fromBundleIdentifier: olderLegacyIdentifier))
        let migratedSessionURL = root.appendingPathComponent(newMacIdentifier, isDirectory: true)
            .appendingPathComponent(AppPaths.legacyReviewSessionFileName)
        XCTAssertEqual(try Data(contentsOf: migratedSessionURL), legacySessionData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacySessionURL.path))
    }

    func testMigrationDoesNotMergeIntoAnAlreadyPopulatedDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleIDMigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent(oldMacIdentifier, isDirectory: true)
        let destination = root.appendingPathComponent(newMacIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceURL = source.appendingPathComponent(AppPaths.reviewSessionFileName)
        let destinationURL = destination.appendingPathComponent("owner-created-file.txt")
        try Data("source".utf8).write(to: sourceURL)
        try Data("destination".utf8).write(to: destinationURL)

        let migration = BundleIdentifierDataMigration(
            applicationSupportRoot: root,
            currentBundleIdentifier: newMacIdentifier,
            formerBundleIdentifiers: [oldMacIdentifier, olderLegacyIdentifier],
            isBundleRunning: { _ in false }
        )

        XCTAssertThrowsError(try migration.migrateIfNeeded())
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    }
}
