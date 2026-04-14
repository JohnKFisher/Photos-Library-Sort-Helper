import Foundation

enum AppPaths {
    static let reviewSessionFileName = "review-session-v2.json"
    static let legacyReviewSessionFileName = "review-session-v1.json"
    static let scanPreferencesFileName = "scan-preferences-v2.json"
    static let legacyScanPreferencesFileName = "scan-preferences-v1.json"

    static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return baseURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static func reviewSessionURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent(reviewSessionFileName, isDirectory: false)
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
}
