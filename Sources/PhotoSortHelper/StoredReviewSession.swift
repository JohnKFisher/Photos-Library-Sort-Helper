import Foundation

struct StoredReviewSession: Codable, Sendable {
    var groups: [ReviewGroup]
    var currentGroupIndex: Int
    var currentGroupID: UUID?
    var currentHighlightedAssetID: String?
    var keepSelectionsByGroup: [UUID: Set<String>]
    var highlightedAssetByGroup: [UUID: String]
    var reviewedGroupIDs: Set<UUID>
    var manuallyEditedGroupIDs: Set<UUID>
    var scannedAssetCount: Int
    var temporalClusterCount: Int

    var sourceMode: PhotoSourceMode
    var selectedAlbumID: String?
    var useDateRange: Bool
    var rangeStartDate: Date
    var rangeEndDate: Date
    var includeVideos: Bool
    var autoplayPreviewVideos: Bool
    var maxTimeGapSeconds: Double
    var similarityDistanceThreshold: Double

    init(
        groups: [ReviewGroup],
        currentGroupIndex: Int,
        currentGroupID: UUID?,
        currentHighlightedAssetID: String?,
        keepSelectionsByGroup: [UUID: Set<String>],
        highlightedAssetByGroup: [UUID: String],
        reviewedGroupIDs: Set<UUID>,
        manuallyEditedGroupIDs: Set<UUID>,
        scannedAssetCount: Int,
        temporalClusterCount: Int,
        sourceMode: PhotoSourceMode,
        selectedAlbumID: String?,
        useDateRange: Bool,
        rangeStartDate: Date,
        rangeEndDate: Date,
        includeVideos: Bool,
        autoplayPreviewVideos: Bool,
        maxTimeGapSeconds: Double,
        similarityDistanceThreshold: Double
    ) {
        self.groups = groups
        self.currentGroupIndex = currentGroupIndex
        self.currentGroupID = currentGroupID
        self.currentHighlightedAssetID = currentHighlightedAssetID
        self.keepSelectionsByGroup = keepSelectionsByGroup
        self.highlightedAssetByGroup = highlightedAssetByGroup
        self.reviewedGroupIDs = reviewedGroupIDs
        self.manuallyEditedGroupIDs = manuallyEditedGroupIDs
        self.scannedAssetCount = scannedAssetCount
        self.temporalClusterCount = temporalClusterCount
        self.sourceMode = sourceMode
        self.selectedAlbumID = selectedAlbumID
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
        groups = try container.decode([ReviewGroup].self, forKey: .groups)
        currentGroupIndex = try container.decodeIfPresent(Int.self, forKey: .currentGroupIndex) ?? 0
        currentGroupID = try container.decodeIfPresent(UUID.self, forKey: .currentGroupID)
        currentHighlightedAssetID = try container.decodeIfPresent(String.self, forKey: .currentHighlightedAssetID)
        keepSelectionsByGroup = try container.decodeIfPresent([UUID: Set<String>].self, forKey: .keepSelectionsByGroup) ?? [:]
        highlightedAssetByGroup = try container.decodeIfPresent([UUID: String].self, forKey: .highlightedAssetByGroup) ?? [:]
        reviewedGroupIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .reviewedGroupIDs) ?? []
        manuallyEditedGroupIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .manuallyEditedGroupIDs) ?? []
        scannedAssetCount = try container.decodeIfPresent(Int.self, forKey: .scannedAssetCount) ?? 0
        temporalClusterCount = try container.decodeIfPresent(Int.self, forKey: .temporalClusterCount) ?? 0
        sourceMode = try container.decodeIfPresent(PhotoSourceMode.self, forKey: .sourceMode) ?? .allPhotos
        selectedAlbumID = try container.decodeIfPresent(String.self, forKey: .selectedAlbumID)
        useDateRange = try container.decodeIfPresent(Bool.self, forKey: .useDateRange) ?? false
        rangeStartDate = try container.decodeIfPresent(Date.self, forKey: .rangeStartDate) ?? Date()
        rangeEndDate = try container.decodeIfPresent(Date.self, forKey: .rangeEndDate) ?? Date()
        includeVideos = try container.decodeIfPresent(Bool.self, forKey: .includeVideos) ?? false
        autoplayPreviewVideos = try container.decodeIfPresent(Bool.self, forKey: .autoplayPreviewVideos) ?? false
        maxTimeGapSeconds = try container.decodeIfPresent(Double.self, forKey: .maxTimeGapSeconds) ?? 8
        similarityDistanceThreshold = try container.decodeIfPresent(Double.self, forKey: .similarityDistanceThreshold) ?? 12.0
    }
}
