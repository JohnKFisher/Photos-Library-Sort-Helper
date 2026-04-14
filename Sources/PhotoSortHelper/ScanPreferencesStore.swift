import Foundation

struct StoredScanPreferences: Codable, Sendable, Equatable {
    var useDateRange: Bool
    var rangeStartDate: Date
    var rangeEndDate: Date
    var includeVideos: Bool
    var autoplayPreviewVideos: Bool
    var maxTimeGapSeconds: Double
    var maxAssetsToScan: Int

    init(
        useDateRange: Bool,
        rangeStartDate: Date,
        rangeEndDate: Date,
        includeVideos: Bool,
        autoplayPreviewVideos: Bool,
        maxTimeGapSeconds: Double,
        maxAssetsToScan: Int
    ) {
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
        useDateRange = try container.decode(Bool.self, forKey: .useDateRange)
        rangeStartDate = try container.decode(Date.self, forKey: .rangeStartDate)
        rangeEndDate = try container.decode(Date.self, forKey: .rangeEndDate)
        includeVideos = try container.decode(Bool.self, forKey: .includeVideos)
        autoplayPreviewVideos = try container.decodeIfPresent(Bool.self, forKey: .autoplayPreviewVideos) ?? false
        maxTimeGapSeconds = try container.decode(Double.self, forKey: .maxTimeGapSeconds)
        maxAssetsToScan = try container.decodeIfPresent(Int.self, forKey: .maxAssetsToScan) ?? 4_000
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

        if let data = try? Data(contentsOf: fileURL),
           let stored = try? decoder.decode(StoredScanPreferences.self, from: data) {
            return stored
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
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(preferences) else {
            return
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
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
