import Foundation

enum AppPaths {
    static let reviewSessionFileName = "review-session-v2.json"
    static let folderReviewSessionFileName = "folder-review-session-v2.json"
    static let reviewDatabaseFileName = "review-state.sqlite"
    static let legacyReviewSessionFileName = "review-session-v1.json"
    static let scanPreferencesFileName = "scan-preferences-v2.json"
    static let legacyScanPreferencesFileName = "scan-preferences-v1.json"
    static let scanBatchStateFileName = "scan-batch-state-v1.json"

    static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
    }

    static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static func reviewSessionURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(reviewSessionFileName, isDirectory: false)
    }

    static func folderReviewSessionURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(folderReviewSessionFileName, isDirectory: false)
    }

    static func reviewDatabaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(reviewDatabaseFileName, isDirectory: false)
    }

    static func legacyReviewSessionURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(legacyReviewSessionFileName, isDirectory: false)
    }

    static func scanPreferencesURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(scanPreferencesFileName, isDirectory: false)
    }

    static func legacyScanPreferencesURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(legacyScanPreferencesFileName, isDirectory: false)
    }

    static func scanBatchStateURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(scanBatchStateFileName, isDirectory: false)
    }
}
