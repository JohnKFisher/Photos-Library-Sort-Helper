import Foundation

struct StoredScanPreferences: Codable, Sendable, Equatable {
    var reviewMode: ReviewMode
    var selectedSourceKind: ReviewSourceKind
    var sourceMode: PhotoSourceMode
    var selectedAlbumID: String?
    var folderSelection: FolderSelection?
    var recentFolders: [FolderSelection]
    var folderRecursiveScan: Bool
    var moveKeptItemsToKeepFolder: Bool
    var useDateRange: Bool
    var rangeStartDate: Date
    var rangeEndDate: Date
    var includeVideos: Bool
    var autoplayPreviewVideos: Bool
    var maxTimeGapSeconds: Double
    var maxAssetsToScan: Int

    init(
        reviewMode: ReviewMode,
        selectedSourceKind: ReviewSourceKind,
        sourceMode: PhotoSourceMode,
        selectedAlbumID: String?,
        folderSelection: FolderSelection?,
        recentFolders: [FolderSelection],
        folderRecursiveScan: Bool,
        moveKeptItemsToKeepFolder: Bool,
        useDateRange: Bool,
        rangeStartDate: Date,
        rangeEndDate: Date,
        includeVideos: Bool,
        autoplayPreviewVideos: Bool,
        maxTimeGapSeconds: Double,
        maxAssetsToScan: Int
    ) {
        self.reviewMode = reviewMode
        self.selectedSourceKind = selectedSourceKind
        self.sourceMode = sourceMode
        self.selectedAlbumID = selectedAlbumID
        self.folderSelection = folderSelection
        self.recentFolders = recentFolders
        self.folderRecursiveScan = folderRecursiveScan
        self.moveKeptItemsToKeepFolder = moveKeptItemsToKeepFolder
        self.useDateRange = useDateRange
        self.rangeStartDate = rangeStartDate
        self.rangeEndDate = rangeEndDate
        self.includeVideos = includeVideos
        self.autoplayPreviewVideos = autoplayPreviewVideos
        self.maxTimeGapSeconds = maxTimeGapSeconds
        self.maxAssetsToScan = maxAssetsToScan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reviewMode = try container.decodeIfPresent(ReviewMode.self, forKey: .reviewMode) ?? .discardFirst
        selectedSourceKind = try container.decodeIfPresent(ReviewSourceKind.self, forKey: .selectedSourceKind) ?? .photos
        sourceMode = try container.decodeIfPresent(PhotoSourceMode.self, forKey: .sourceMode) ?? .allPhotos
        selectedAlbumID = try container.decodeIfPresent(String.self, forKey: .selectedAlbumID)
        folderSelection = try container.decodeIfPresent(FolderSelection.self, forKey: .folderSelection)
        recentFolders = try container.decodeIfPresent([FolderSelection].self, forKey: .recentFolders) ?? []
        folderRecursiveScan = try container.decodeIfPresent(Bool.self, forKey: .folderRecursiveScan) ?? true
        moveKeptItemsToKeepFolder = try container.decodeIfPresent(Bool.self, forKey: .moveKeptItemsToKeepFolder) ?? false
        useDateRange = try container.decode(Bool.self, forKey: .useDateRange)
        rangeStartDate = try container.decode(Date.self, forKey: .rangeStartDate)
        rangeEndDate = try container.decode(Date.self, forKey: .rangeEndDate)
        includeVideos = try container.decode(Bool.self, forKey: .includeVideos)
        autoplayPreviewVideos = try container.decodeIfPresent(Bool.self, forKey: .autoplayPreviewVideos) ?? false
        maxTimeGapSeconds = try container.decode(Double.self, forKey: .maxTimeGapSeconds)
        maxAssetsToScan = try container.decodeIfPresent(Int.self, forKey: .maxAssetsToScan) ?? 4_000
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reviewMode, forKey: .reviewMode)
        try container.encode(selectedSourceKind, forKey: .selectedSourceKind)
        try container.encode(sourceMode, forKey: .sourceMode)
        try container.encodeIfPresent(selectedAlbumID, forKey: .selectedAlbumID)
        try container.encodeIfPresent(folderSelection, forKey: .folderSelection)
        try container.encode(recentFolders, forKey: .recentFolders)
        try container.encode(folderRecursiveScan, forKey: .folderRecursiveScan)
        try container.encode(moveKeptItemsToKeepFolder, forKey: .moveKeptItemsToKeepFolder)
        try container.encode(useDateRange, forKey: .useDateRange)
        try container.encode(rangeStartDate, forKey: .rangeStartDate)
        try container.encode(rangeEndDate, forKey: .rangeEndDate)
        try container.encode(includeVideos, forKey: .includeVideos)
        try container.encode(autoplayPreviewVideos, forKey: .autoplayPreviewVideos)
        try container.encode(maxTimeGapSeconds, forKey: .maxTimeGapSeconds)
        try container.encode(maxAssetsToScan, forKey: .maxAssetsToScan)
    }

    private enum CodingKeys: String, CodingKey {
        case reviewMode
        case selectedSourceKind
        case sourceMode
        case selectedAlbumID
        case folderSelection
        case recentFolders
        case folderRecursiveScan
        case moveKeptItemsToKeepFolder
        case useDateRange
        case rangeStartDate
        case rangeEndDate
        case includeVideos
        case autoplayPreviewVideos
        case maxTimeGapSeconds
        case maxAssetsToScan
    }
}

struct ScanPreferencesStore {
    static let currentDefaultsKey = "PhotosLibrarySortHelper.scanPreferences.v1"
    static let legacyDefaultsKey = "PhotoSortHelper.scanPreferences.v1"

    let bundleIdentifier: String
    let legacyBundleIdentifier: String
    let fileManager: FileManager
    let defaults: UserDefaults

    init(
        bundleIdentifier: String,
        legacyBundleIdentifier: String = "com.jkfisher.photosorthelper",
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.legacyBundleIdentifier = legacyBundleIdentifier
        self.fileManager = fileManager
        self.defaults = defaults
    }

    var fileURL: URL {
        AppPaths.scanPreferencesURL(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
    }

    func load() -> StoredScanPreferences? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for url in preferredLoadURLs {
            if let data = try? Data(contentsOf: url),
               let stored = try? decoder.decode(StoredScanPreferences.self, from: data) {
                if url != fileURL {
                    save(stored)
                }
                return stored
            }
        }

        guard let migratedData = migratedDefaultsData(),
              let stored = try? decoder.decode(StoredScanPreferences.self, from: migratedData) else {
            return nil
        }

        save(stored)
        return stored
    }

    func save(_ preferences: StoredScanPreferences) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(preferences) else {
            return
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    private var preferredLoadURLs: [URL] {
        [
            AppPaths.scanPreferencesURL(fileManager: fileManager, bundleIdentifier: bundleIdentifier),
            AppPaths.legacyScanPreferencesURL(fileManager: fileManager, bundleIdentifier: bundleIdentifier),
            AppPaths.scanPreferencesURL(fileManager: fileManager, bundleIdentifier: legacyBundleIdentifier),
            AppPaths.legacyScanPreferencesURL(fileManager: fileManager, bundleIdentifier: legacyBundleIdentifier)
        ]
    }

    private func migratedDefaultsData() -> Data? {
        if let currentData = defaults.data(forKey: Self.currentDefaultsKey) {
            return currentData
        }

        let legacyDomain = defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
        if let currentDomainValue = legacyDomain[Self.currentDefaultsKey] as? Data {
            return currentDomainValue
        }

        if let legacyData = defaults.data(forKey: Self.legacyDefaultsKey) {
            return legacyData
        }

        return legacyDomain[Self.legacyDefaultsKey] as? Data
    }
}
