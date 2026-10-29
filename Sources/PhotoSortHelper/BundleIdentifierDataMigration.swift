import AppKit
import Foundation
import PhotosSortCore

/// Copies the Mac app's durable Application Support files when its bundle ID changes.
/// The former app's directory is never edited or removed.
struct BundleIdentifierDataMigration {
    enum Outcome: Equatable {
        case noSourceData
        case migrated(fromBundleIdentifier: String)
        case alreadyMigrated
    }

    enum MigrationError: LocalizedError {
        case sourceAppStillRunning(String)
        case destinationAlreadyContainsData(String)
        case orphanedSQLiteSidecar
        case symbolicLinkInSource(String)
        case invalidMigrationMarker
        case copiedFilesDidNotMatch(String)

        var errorDescription: String? {
            switch self {
            case .sourceAppStillRunning(let identifier):
                "Quit the older Photos Library Sort Helper (\(identifier)) before opening this version so its local review data can be copied safely."
            case .destinationAlreadyContainsData(let path):
                "The new app data folder already contains files but has no completed migration record: \(path). The older data was left untouched. Move or back up the new folder before retrying."
            case .orphanedSQLiteSidecar:
                "The older review database has SQLite journal files but no database file. The older app data was left untouched."
            case .symbolicLinkInSource(let path):
                "The older app data contains a symbolic link at \(path), so it was not copied. The original data was left untouched."
            case .invalidMigrationMarker:
                "The new app data folder has an unreadable migration record. No older data was copied over it."
            case .copiedFilesDidNotMatch(let reason):
                "The copied app data did not match the older files (\(reason)). The original data was left untouched."
            }
        }
    }

    private struct MigrationRecord: Codable {
        let formatVersion: Int
        let sourceBundleIdentifier: String
        let migratedAt: Date
    }

    private static let markerFileName = ".bundle-id-migration-v1.json"
    private static let databaseFileName = AppPaths.reviewDatabaseFileName

    let applicationSupportRoot: URL
    let currentBundleIdentifier: String
    let formerBundleIdentifiers: [String]
    let fileManager: FileManager
    let isBundleRunning: (String) -> Bool

    init(
        applicationSupportRoot: URL = AppPaths.applicationSupportRoot(),
        currentBundleIdentifier: String,
        formerBundleIdentifiers: [String],
        fileManager: FileManager = .default,
        isBundleRunning: @escaping (String) -> Bool = { identifier in
            !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
        }
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.currentBundleIdentifier = currentBundleIdentifier
        self.formerBundleIdentifiers = formerBundleIdentifiers.filter { $0 != currentBundleIdentifier }
        self.fileManager = fileManager
        self.isBundleRunning = isBundleRunning
    }

    func migrateIfNeeded() throws -> Outcome {
        let destination = applicationSupportRoot.appendingPathComponent(currentBundleIdentifier, isDirectory: true)
        let markerURL = destination.appendingPathComponent(Self.markerFileName, isDirectory: false)
        if fileManager.fileExists(atPath: markerURL.path) {
            try validateMigrationRecord(at: markerURL)
            return .alreadyMigrated
        }

        for identifier in formerBundleIdentifiers where isBundleRunning(identifier) {
            throw MigrationError.sourceAppStillRunning(identifier)
        }

        let source = try formerBundleIdentifiers
            .map { identifier -> (String, URL) in
                (identifier, applicationSupportRoot.appendingPathComponent(identifier, isDirectory: true))
            }
            .first { _, url in try directoryHasEntries(url) }

        guard let (sourceIdentifier, sourceDirectory) = source else {
            return .noSourceData
        }

        if fileManager.fileExists(atPath: destination.path) {
            guard try directoryHasEntries(destination) == false else {
                throw MigrationError.destinationAlreadyContainsData(destination.path)
            }
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        let staging = applicationSupportRoot.appendingPathComponent(
            ".\(currentBundleIdentifier).migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

        do {
            try rejectSymbolicLinks(in: sourceDirectory)
            try copyNonDatabaseEntries(from: sourceDirectory, to: staging)
            try copyDatabaseSnapshot(from: sourceDirectory, to: staging)
            try validateCopiedEntries(from: sourceDirectory, to: staging)

            let record = MigrationRecord(
                formatVersion: 1,
                sourceBundleIdentifier: sourceIdentifier,
                migratedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(
                to: staging.appendingPathComponent(Self.markerFileName),
                options: [.atomic]
            )
            try fileManager.moveItem(at: staging, to: destination)
            return .migrated(fromBundleIdentifier: sourceIdentifier)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func validateMigrationRecord(at url: URL) throws {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(MigrationRecord.self, from: Data(contentsOf: url))
            guard record.formatVersion == 1,
                  formerBundleIdentifiers.contains(record.sourceBundleIdentifier) else {
                throw MigrationError.invalidMigrationMarker
            }
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.invalidMigrationMarker
        }
    }

    private func directoryHasEntries(_ directory: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MigrationError.symbolicLinkInSource(directory.path)
        }
        return try !fileManager.contentsOfDirectory(atPath: directory.path).isEmpty
    }

    private func rejectSymbolicLinks(in directory: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }

        for case let itemURL as URL in enumerator {
            if try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw MigrationError.symbolicLinkInSource(itemURL.path)
            }
        }
    }

    private func copyNonDatabaseEntries(from source: URL, to destination: URL) throws {
        for itemURL in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            let name = itemURL.lastPathComponent
            guard !Self.isDatabaseArtifact(name), name != Self.markerFileName else { continue }
            try fileManager.copyItem(
                at: itemURL,
                to: destination.appendingPathComponent(name, isDirectory: false)
            )
        }
    }

    private func copyDatabaseSnapshot(from source: URL, to destination: URL) throws {
        let databaseURL = source.appendingPathComponent(Self.databaseFileName)
        let sidecarNames = ["-wal", "-journal", "-shm"].map { Self.databaseFileName + $0 }
        let sidecars = sidecarNames.map { source.appendingPathComponent($0) }
        let hasDatabase = fileManager.fileExists(atPath: databaseURL.path)
        let hasSidecar = sidecars.contains { fileManager.fileExists(atPath: $0.path) }

        guard hasDatabase else {
            if hasSidecar { throw MigrationError.orphanedSQLiteSidecar }
            return
        }

        // Copy the quiescent DB and recovery journal/WAL to a disposable staging source.
        // SQLite then resolves recovery state there and emits a clean online-backup snapshot.
        let snapshotSource = destination.appendingPathComponent(".sqlite-source", isDirectory: true)
        try fileManager.createDirectory(at: snapshotSource, withIntermediateDirectories: false)
        let stagedDatabaseURL = snapshotSource.appendingPathComponent(Self.databaseFileName)
        try fileManager.copyItem(at: databaseURL, to: stagedDatabaseURL)
        for suffix in ["-wal", "-journal"] {
            let sidecar = source.appendingPathComponent(Self.databaseFileName + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            try fileManager.copyItem(
                at: sidecar,
                to: snapshotSource.appendingPathComponent(Self.databaseFileName + suffix)
            )
        }

        try SQLiteReviewStore.createConsistentSnapshot(
            fromQuiescentCopy: stagedDatabaseURL,
            to: destination.appendingPathComponent(Self.databaseFileName)
        )
        try fileManager.removeItem(at: snapshotSource)
    }

    private func validateCopiedEntries(from source: URL, to destination: URL) throws {
        let sourceEntries = try comparableEntries(in: source)
        let destinationEntries = try comparableEntries(in: destination)
        guard sourceEntries == destinationEntries else {
            throw MigrationError.copiedFilesDidNotMatch(
                "source entries: \(sourceEntries.sorted()), copied entries: \(destinationEntries.sorted())"
            )
        }

        for relativePath in sourceEntries.sorted() {
            let sourceURL = source.appendingPathComponent(relativePath)
            if Self.isDatabaseArtifact(sourceURL.lastPathComponent) { continue }
            let destinationURL = destination.appendingPathComponent(relativePath)
            var sourceIsDirectory: ObjCBool = false
            var destinationIsDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory)
            _ = fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory)
            guard sourceIsDirectory.boolValue == destinationIsDirectory.boolValue else {
                throw MigrationError.copiedFilesDidNotMatch("file type differed for \(relativePath)")
            }
            if !sourceIsDirectory.boolValue,
               try Data(contentsOf: sourceURL) != Data(contentsOf: destinationURL) {
                throw MigrationError.copiedFilesDidNotMatch("file contents differed for \(relativePath)")
            }
        }
    }

    private func comparableEntries(in root: URL) throws -> Set<String> {
        var entries = Set<String>()
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return entries
        }
        let resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"
        for case let itemURL as URL in enumerator {
            let resolvedItemPath = itemURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedItemPath.hasPrefix(rootPrefix) else {
                throw MigrationError.copiedFilesDidNotMatch("an enumerated item escaped the source folder")
            }
            let relativePath = String(resolvedItemPath.dropFirst(rootPrefix.count))
            guard relativePath != Self.markerFileName,
                  relativePath != ".sqlite-source",
                  !Self.isDatabaseArtifact(itemURL.lastPathComponent) else { continue }
            entries.insert(relativePath)
        }
        return entries
    }

    private static func isDatabaseArtifact(_ name: String) -> Bool {
        name == databaseFileName || name.hasPrefix(databaseFileName + "-")
    }
}
