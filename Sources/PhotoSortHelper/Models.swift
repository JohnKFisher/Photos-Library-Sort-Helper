import Foundation
import Photos

enum ReviewSourceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case photos
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos:
            return "Photos Library"
        case .folder:
            return "Folder"
        }
    }
}

enum PhotoSourceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case allPhotos
    case album

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allPhotos:
            return "All Photos"
        case .album:
            return "Album"
        }
    }
}

enum AlbumKind: String, Hashable, Codable, Sendable {
    case user
    case smart

    var label: String {
        switch self {
        case .user:
            return "Album"
        case .smart:
            return "Smart"
        }
    }
}

enum AlbumSourceKind: String, Hashable, Codable, Sendable {
    case assetCollection
    case collectionList
}

struct AlbumOption: Identifiable, Hashable, Codable, Sendable {
    let localIdentifier: String
    let sourceKind: AlbumSourceKind
    let title: String
    let kind: AlbumKind
    let estimatedAssetCount: Int

    var id: String {
        "\(sourceKind.rawValue):\(localIdentifier)"
    }

    var subtitle: String {
        estimatedAssetCount == 1 ? "1 photo" : "\(estimatedAssetCount) photos"
    }

    var pickerTitle: String {
        "\(title) (\(estimatedAssetCount))"
    }
}

struct FolderSelection: Codable, Hashable, Sendable {
    var resolvedPath: String
    var bookmarkDataBase64: String?

    init(resolvedPath: String, bookmarkDataBase64: String? = nil) {
        self.resolvedPath = resolvedPath
        self.bookmarkDataBase64 = bookmarkDataBase64
    }

    var displayName: String {
        URL(fileURLWithPath: resolvedPath).lastPathComponent
    }
}

enum ReviewItemSource: Hashable, Codable, Sendable {
    case photoAsset(localIdentifier: String)
    case file(path: String, relativePath: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case localIdentifier
        case path
        case relativePath
    }

    private enum Kind: String, Codable {
        case photoAsset
        case file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .photoAsset:
            self = .photoAsset(localIdentifier: try container.decode(String.self, forKey: .localIdentifier))
        case .file:
            self = .file(
                path: try container.decode(String.self, forKey: .path),
                relativePath: try container.decode(String.self, forKey: .relativePath)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .photoAsset(let localIdentifier):
            try container.encode(Kind.photoAsset, forKey: .kind)
            try container.encode(localIdentifier, forKey: .localIdentifier)
        case .file(let path, let relativePath):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(relativePath, forKey: .relativePath)
        }
    }
}

enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

struct ReviewItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let source: ReviewItemSource
    let displayName: String
    let mediaKind: MediaKind
    let primaryDate: Date?
    let fallbackDate: Date?
    let byteSize: Int64
    let badgeLabels: [String]
    let detailLabel: String?

    var preferredDate: Date? {
        primaryDate ?? fallbackDate
    }

    var sortDate: Date {
        preferredDate ?? .distantPast
    }

    var isVideo: Bool {
        mediaKind == .video
    }

    var relativePath: String? {
        if case .file(_, let relativePath) = source {
            return relativePath
        }
        return nil
    }

    var absolutePath: String? {
        if case .file(let path, _) = source {
            return path
        }
        return nil
    }

    var photoLocalIdentifier: String? {
        if case .photoAsset(let localIdentifier) = source {
            return localIdentifier
        }
        return nil
    }
}

struct ScanSettings: Sendable {
    var selectedSourceKind: ReviewSourceKind
    var sourceMode: PhotoSourceMode
    var selectedAlbumID: String?
    var folderSelection: FolderSelection?
    var folderRecursiveScan: Bool
    var moveKeptItemsToKeepFolder: Bool
    var dateFrom: Date?
    var dateTo: Date?
    var includeVideos: Bool
    var maxTimeGapSeconds: TimeInterval
    var similarityDistanceThreshold: Float
}

struct ReviewGroup: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var itemIDs: [String]
    let startDate: Date?
    let endDate: Date?

    init(id: UUID = UUID(), itemIDs: [String], startDate: Date?, endDate: Date?) {
        self.id = id
        self.itemIDs = itemIDs
        self.startDate = startDate
        self.endDate = endDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let itemIDs = try container.decodeIfPresent([String].self, forKey: .itemIDs) {
            self.itemIDs = itemIDs
        } else {
            self.itemIDs = try container.decodeIfPresent([String].self, forKey: .assetIDs) ?? []
        }
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(itemIDs, forKey: .itemIDs)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case itemIDs
        case assetIDs
        case startDate
        case endDate
    }
}

struct ScanProgress: Sendable {
    var fractionCompleted: Double
    var message: String
}

struct ScanResult: Sendable {
    var groups: [ReviewGroup]
    var itemLookup: [String: ReviewItem]
    var photoAssetLookup: [String: PHAsset]
    var scannedItemCount: Int
    var temporalClusterCount: Int
    var skippedHiddenCount: Int
    var skippedUnsupportedCount: Int
    var skippedPackageCount: Int
    var skippedSymlinkDirectoryCount: Int
}

enum FolderCommitDestination: String, Sendable, CaseIterable {
    case editQueue
    case manualDeleteQueue
    case keep

    var folderName: String {
        switch self {
        case .editQueue:
            return "Files to Edit"
        case .manualDeleteQueue:
            return "Files to Manually Delete"
        case .keep:
            return "Keep"
        }
    }

    var title: String {
        switch self {
        case .editQueue:
            return "Edit queue"
        case .manualDeleteQueue:
            return "Manual delete queue"
        case .keep:
            return "Keep folder"
        }
    }
}

struct FolderCommitOperation: Sendable {
    var itemID: String
    var sourceURL: URL
    var relativePath: String
    var destination: FolderCommitDestination
}

struct FolderCommitDestinationPaths: Sendable, Hashable {
    var destinationRootURL: URL
    var editQueueURL: URL
    var manualDeleteQueueURL: URL
    var keepURL: URL

    func url(for destination: FolderCommitDestination) -> URL {
        switch destination {
        case .editQueue:
            return editQueueURL
        case .manualDeleteQueue:
            return manualDeleteQueueURL
        case .keep:
            return keepURL
        }
    }
}

struct FolderCommitPlan: Sendable {
    var operations: [FolderCommitOperation]
    var reviewedGroupCount: Int
    var editQueueCount: Int
    var manualDeleteCount: Int
    var keepCount: Int
    var editQueueSamples: [String]
    var manualDeleteSamples: [String]
    var keepSamples: [String]

    var totalMoveCount: Int {
        operations.count
    }

    func count(for destination: FolderCommitDestination) -> Int {
        switch destination {
        case .editQueue:
            return editQueueCount
        case .manualDeleteQueue:
            return manualDeleteCount
        case .keep:
            return keepCount
        }
    }

    func samples(for destination: FolderCommitDestination) -> [String] {
        switch destination {
        case .editQueue:
            return editQueueSamples
        case .manualDeleteQueue:
            return manualDeleteSamples
        case .keep:
            return keepSamples
        }
    }
}

struct FolderCommitExecutionProgress: Sendable {
    var processedCount: Int
    var movedCount: Int
    var totalCount: Int
    var currentRelativePath: String?
    var lastProcessedRelativePath: String?
    var statusMessage: String

    var fractionCompleted: Double {
        guard totalCount > 0 else {
            return 0
        }

        return min(max(Double(processedCount) / Double(totalCount), 0), 1)
    }
}

struct FolderCommitSkippedSourceDetail: Identifiable, Hashable, Sendable {
    var sourcePath: String
    var relativePath: String
    var destination: FolderCommitDestination
    var destinationFolderPath: String

    var id: String {
        "\(sourcePath)|\(destination.rawValue)|missing"
    }
}

struct FolderCommitRenamedItem: Identifiable, Hashable, Sendable {
    var relativePath: String
    var finalRelativePath: String
    var destination: FolderCommitDestination
    var destinationPath: String

    var id: String {
        destinationPath
    }
}

struct FolderCommitFailureDetail: Identifiable, Hashable, Sendable {
    var sourcePath: String
    var relativePath: String
    var destination: FolderCommitDestination
    var destinationFolderPath: String
    var message: String

    var id: String {
        "\(sourcePath)|\(destination.rawValue)|failure|\(message)"
    }
}

struct FolderCommitExecutionResult: Sendable {
    var destinationPaths: FolderCommitDestinationPaths
    var totalOperationCount: Int
    var processedCount: Int
    var wasCancelled: Bool
    var movedItemIDs: Set<String>
    var movedToEditQueueCount: Int
    var movedToManualDeleteCount: Int
    var movedToKeepCount: Int
    var skippedMissingSources: [FolderCommitSkippedSourceDetail]
    var renamedItems: [FolderCommitRenamedItem]
    var failures: [FolderCommitFailureDetail]

    var totalMovedCount: Int {
        movedItemIDs.count
    }

    var skippedMissingSourceCount: Int {
        skippedMissingSources.count
    }

    var renamedCount: Int {
        renamedItems.count
    }

    var failureCount: Int {
        failures.count
    }

    var hasIssues: Bool {
        skippedMissingSourceCount > 0 || failureCount > 0 || wasCancelled
    }
}

enum ReviewError: LocalizedError, Equatable {
    case missingAlbumSelection
    case photoAccessDenied
    case albumNotFound
    case missingSourceFolder
    case staleSourceFolderBookmark
    case sourceFolderDoesNotExist
    case sourceFolderNotDirectory
    case sourceFolderConflictsWithDestination
    case unreadableSourceFolder
    case emptySourceFolder
    case noReviewedItemsToCommit

    var errorDescription: String? {
        switch self {
        case .missingAlbumSelection:
            return "Pick an album before scanning."
        case .photoAccessDenied:
            return "Photos access is denied. Enable it in System Settings > Privacy & Security > Photos."
        case .albumNotFound:
            return "The selected album could not be found."
        case .missingSourceFolder:
            return "Choose a source folder before scanning."
        case .staleSourceFolderBookmark:
            return "The saved folder access is stale. Choose the folder again to continue."
        case .sourceFolderDoesNotExist:
            return "The selected source folder does not exist."
        case .sourceFolderNotDirectory:
            return "The selected source path is not a folder."
        case .sourceFolderConflictsWithDestination:
            return "Choose a source folder that is not already named Files to Edit, Files to Manually Delete, or Keep."
        case .unreadableSourceFolder:
            return "The selected source folder could not be read."
        case .emptySourceFolder:
            return "The selected folder does not contain supported media files yet."
        case .noReviewedItemsToCommit:
            return "No reviewed items are ready to commit."
        }
    }
}
