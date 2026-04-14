import Foundation

struct StoredReviewSession: Codable, Sendable {
    var items: [ReviewItem]
    var groups: [ReviewGroup]
    var currentGroupIndex: Int
    var currentGroupID: UUID?
    var currentHighlightedItemID: String?
    var reviewMode: ReviewMode
    var reviewDecisionsByGroup: [UUID: ReviewGroupDecisions]
    var highlightedItemByGroup: [UUID: String]
    var reviewedGroupIDs: Set<UUID>
    var queuedForEditItemIDs: Set<String>
    var scannedItemCount: Int
    var temporalClusterCount: Int

    var selectedSourceKind: ReviewSourceKind
    var sourceMode: PhotoSourceMode
    var selectedAlbumID: String?
    var folderSelection: FolderSelection?
    var folderRecursiveScan: Bool
    var moveKeptItemsToKeepFolder: Bool
    var useDateRange: Bool
    var rangeStartDate: Date
    var rangeEndDate: Date
    var includeVideos: Bool
    var autoplayPreviewVideos: Bool
    var maxTimeGapSeconds: Double
    var similarityDistanceThreshold: Double

    init(
        items: [ReviewItem],
        groups: [ReviewGroup],
        currentGroupIndex: Int,
        currentGroupID: UUID?,
        currentHighlightedItemID: String?,
        reviewMode: ReviewMode,
        reviewDecisionsByGroup: [UUID: ReviewGroupDecisions],
        highlightedItemByGroup: [UUID: String],
        reviewedGroupIDs: Set<UUID>,
        queuedForEditItemIDs: Set<String>,
        scannedItemCount: Int,
        temporalClusterCount: Int,
        selectedSourceKind: ReviewSourceKind,
        sourceMode: PhotoSourceMode,
        selectedAlbumID: String?,
        folderSelection: FolderSelection?,
        folderRecursiveScan: Bool,
        moveKeptItemsToKeepFolder: Bool,
        useDateRange: Bool,
        rangeStartDate: Date,
        rangeEndDate: Date,
        includeVideos: Bool,
        autoplayPreviewVideos: Bool,
        maxTimeGapSeconds: Double,
        similarityDistanceThreshold: Double
    ) {
        self.items = items
        self.groups = groups
        self.currentGroupIndex = currentGroupIndex
        self.currentGroupID = currentGroupID
        self.currentHighlightedItemID = currentHighlightedItemID
        self.reviewMode = reviewMode
        self.reviewDecisionsByGroup = reviewDecisionsByGroup
        self.highlightedItemByGroup = highlightedItemByGroup
        self.reviewedGroupIDs = reviewedGroupIDs
        self.queuedForEditItemIDs = queuedForEditItemIDs
        self.scannedItemCount = scannedItemCount
        self.temporalClusterCount = temporalClusterCount
        self.selectedSourceKind = selectedSourceKind
        self.sourceMode = sourceMode
        self.selectedAlbumID = selectedAlbumID
        self.folderSelection = folderSelection
        self.folderRecursiveScan = folderRecursiveScan
        self.moveKeptItemsToKeepFolder = moveKeptItemsToKeepFolder
        self.useDateRange = useDateRange
        self.rangeStartDate = rangeStartDate
        self.rangeEndDate = rangeEndDate
        self.includeVideos = includeVideos
        self.autoplayPreviewVideos = autoplayPreviewVideos
        self.maxTimeGapSeconds = maxTimeGapSeconds
        self.similarityDistanceThreshold = similarityDistanceThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([ReviewItem].self, forKey: .items) ?? []
        groups = try container.decode([ReviewGroup].self, forKey: .groups)
        currentGroupIndex = try container.decodeIfPresent(Int.self, forKey: .currentGroupIndex) ?? 0
        currentGroupID = try container.decodeIfPresent(UUID.self, forKey: .currentGroupID)
        let legacyHighlightedID = try container.decodeIfPresent(String.self, forKey: .currentHighlightedAssetID)
        currentHighlightedItemID = try container.decodeIfPresent(String.self, forKey: .currentHighlightedItemID) ?? legacyHighlightedID
        reviewMode = try container.decodeIfPresent(ReviewMode.self, forKey: .reviewMode) ?? .discardFirst
        reviewDecisionsByGroup =
            try Self.decodeReviewDecisions(from: container)
        let currentHighlightedMap = try? container.decodeIfPresent([UUID: String].self, forKey: .highlightedItemByGroup)
        let legacyHighlightedMap = try? container.decodeIfPresent([UUID: String].self, forKey: .highlightedAssetByGroup)
        let stringHighlightedMap = Self.decodeUUIDStringMap(from: container, key: .highlightedAssetByGroup)
        highlightedItemByGroup = currentHighlightedMap ?? legacyHighlightedMap ?? stringHighlightedMap ?? [:]
        let legacyReviewedGroupIDs = try container.decodeIfPresent([String].self, forKey: .reviewedGroupIDs) ?? []
        reviewedGroupIDs =
            (try? container.decodeIfPresent(Set<UUID>.self, forKey: .reviewedGroupIDs))
            ?? Set(legacyReviewedGroupIDs.compactMap(UUID.init(uuidString:)))
        queuedForEditItemIDs = try container.decodeIfPresent(Set<String>.self, forKey: .queuedForEditItemIDs) ?? []
        scannedItemCount = try container.decodeIfPresent(Int.self, forKey: .scannedItemCount) ?? 0
        temporalClusterCount = try container.decodeIfPresent(Int.self, forKey: .temporalClusterCount) ?? 0
        selectedSourceKind = try container.decodeIfPresent(ReviewSourceKind.self, forKey: .selectedSourceKind) ?? .photos
        sourceMode = try container.decodeIfPresent(PhotoSourceMode.self, forKey: .sourceMode) ?? .allPhotos
        selectedAlbumID = try container.decodeIfPresent(String.self, forKey: .selectedAlbumID)
        folderSelection = try container.decodeIfPresent(FolderSelection.self, forKey: .folderSelection)
        folderRecursiveScan = try container.decodeIfPresent(Bool.self, forKey: .folderRecursiveScan) ?? true
        moveKeptItemsToKeepFolder = try container.decodeIfPresent(Bool.self, forKey: .moveKeptItemsToKeepFolder) ?? false
        useDateRange = try container.decodeIfPresent(Bool.self, forKey: .useDateRange) ?? false
        rangeStartDate = try container.decodeIfPresent(Date.self, forKey: .rangeStartDate) ?? Date()
        rangeEndDate = try container.decodeIfPresent(Date.self, forKey: .rangeEndDate) ?? Date()
        includeVideos = try container.decodeIfPresent(Bool.self, forKey: .includeVideos) ?? false
        autoplayPreviewVideos = try container.decodeIfPresent(Bool.self, forKey: .autoplayPreviewVideos) ?? false
        maxTimeGapSeconds = try container.decodeIfPresent(Double.self, forKey: .maxTimeGapSeconds) ?? 8
        similarityDistanceThreshold = try container.decodeIfPresent(Double.self, forKey: .similarityDistanceThreshold) ?? 12.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(groups, forKey: .groups)
        try container.encode(currentGroupIndex, forKey: .currentGroupIndex)
        try container.encodeIfPresent(currentGroupID, forKey: .currentGroupID)
        try container.encodeIfPresent(currentHighlightedItemID, forKey: .currentHighlightedItemID)
        try container.encode(reviewMode, forKey: .reviewMode)
        try container.encode(reviewDecisionsByGroup, forKey: .reviewDecisionsByGroup)
        try container.encode(highlightedItemByGroup, forKey: .highlightedItemByGroup)
        try container.encode(reviewedGroupIDs, forKey: .reviewedGroupIDs)
        try container.encode(queuedForEditItemIDs, forKey: .queuedForEditItemIDs)
        try container.encode(scannedItemCount, forKey: .scannedItemCount)
        try container.encode(temporalClusterCount, forKey: .temporalClusterCount)
        try container.encode(selectedSourceKind, forKey: .selectedSourceKind)
        try container.encode(sourceMode, forKey: .sourceMode)
        try container.encodeIfPresent(selectedAlbumID, forKey: .selectedAlbumID)
        try container.encodeIfPresent(folderSelection, forKey: .folderSelection)
        try container.encode(folderRecursiveScan, forKey: .folderRecursiveScan)
        try container.encode(moveKeptItemsToKeepFolder, forKey: .moveKeptItemsToKeepFolder)
        try container.encode(useDateRange, forKey: .useDateRange)
        try container.encode(rangeStartDate, forKey: .rangeStartDate)
        try container.encode(rangeEndDate, forKey: .rangeEndDate)
        try container.encode(includeVideos, forKey: .includeVideos)
        try container.encode(autoplayPreviewVideos, forKey: .autoplayPreviewVideos)
        try container.encode(maxTimeGapSeconds, forKey: .maxTimeGapSeconds)
        try container.encode(similarityDistanceThreshold, forKey: .similarityDistanceThreshold)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case groups
        case currentGroupIndex
        case currentGroupID
        case currentHighlightedItemID
        case currentHighlightedAssetID
        case reviewMode
        case reviewDecisionsByGroup
        case keepSelectionsByGroup
        case highlightedItemByGroup
        case highlightedAssetByGroup
        case reviewedGroupIDs
        case queuedForEditItemIDs
        case scannedItemCount
        case temporalClusterCount
        case selectedSourceKind
        case sourceMode
        case selectedAlbumID
        case folderSelection
        case folderRecursiveScan
        case moveKeptItemsToKeepFolder
        case useDateRange
        case rangeStartDate
        case rangeEndDate
        case includeVideos
        case autoplayPreviewVideos
        case maxTimeGapSeconds
        case similarityDistanceThreshold
    }

    private static func decodeUUIDSetMap(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> [UUID: Set<String>] {
        if let decoded = try? container.decodeIfPresent([UUID: Set<String>].self, forKey: key) {
            return decoded
        }

        if let legacy = try? container.decodeIfPresent([String: [String]].self, forKey: key) {
            return legacy.reduce(into: [:]) { partial, entry in
                if let uuid = UUID(uuidString: entry.key) {
                    partial[uuid] = Set(entry.value)
                }
            }
        }

        return [:]
    }

    private static func decodeReviewDecisions(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [UUID: ReviewGroupDecisions] {
        if let decoded = try? container.decodeIfPresent([UUID: ReviewGroupDecisions].self, forKey: .reviewDecisionsByGroup) {
            return decoded
        }

        if let legacyStringMap = try? container.decodeIfPresent([String: ReviewGroupDecisions].self, forKey: .reviewDecisionsByGroup) {
            return legacyStringMap.reduce(into: [:]) { partial, entry in
                if let uuid = UUID(uuidString: entry.key) {
                    partial[uuid] = entry.value
                }
            }
        }

        let legacyKeeps = try decodeUUIDSetMap(from: container, key: .keepSelectionsByGroup)
        return legacyKeeps.reduce(into: [:]) { partial, entry in
            partial[entry.key] = ReviewGroupDecisions(explicitKeepIDs: entry.value)
        }
    }

    private static func decodeUUIDStringMap(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [UUID: String]? {
        guard let legacy = try? container.decodeIfPresent([String: String].self, forKey: key) else {
            return nil
        }

        return legacy.reduce(into: [:]) { partial, entry in
            if let uuid = UUID(uuidString: entry.key) {
                partial[uuid] = entry.value
            }
        }
    }
}
