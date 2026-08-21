import Foundation

enum ScanBatchError: LocalizedError {
    case incompatibleContinuation

    var errorDescription: String? {
        switch self {
        case .incompatibleContinuation:
            return "The saved batch no longer matches this source or its grouping settings. Start from the beginning to continue."
        }
    }
}

struct ScanBatchCheckpoint: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var sourceKey: String
    var groupingFingerprint: String
    var frozenItems: [ReviewItem]
    var pendingGroups: [ReviewGroup]
    var remainingItemIDs: [String]
    var batchNumber: Int
    var hasMore: Bool
    var readyForNextBatch: Bool

    init(
        sourceKey: String,
        groupingFingerprint: String,
        frozenItems: [ReviewItem],
        pendingGroups: [ReviewGroup] = [],
        remainingItemIDs: [String] = [],
        batchNumber: Int = 1,
        hasMore: Bool = true,
        readyForNextBatch: Bool = false
    ) {
        self.version = Self.currentVersion
        self.sourceKey = sourceKey
        self.groupingFingerprint = groupingFingerprint
        self.frozenItems = frozenItems
        self.pendingGroups = pendingGroups
        self.remainingItemIDs = Array(Set(remainingItemIDs)).sorted()
        self.batchNumber = max(1, batchNumber)
        self.hasMore = hasMore
        self.readyForNextBatch = readyForNextBatch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard version == Self.currentVersion else { throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported batch state version") }
        sourceKey = try c.decode(String.self, forKey: .sourceKey)
        groupingFingerprint = try c.decode(String.self, forKey: .groupingFingerprint)
        frozenItems = try c.decode([ReviewItem].self, forKey: .frozenItems)
        pendingGroups = try c.decodeIfPresent([ReviewGroup].self, forKey: .pendingGroups) ?? []
        remainingItemIDs = try c.decodeIfPresent([String].self, forKey: .remainingItemIDs) ?? []
        batchNumber = max(1, try c.decodeIfPresent(Int.self, forKey: .batchNumber) ?? 1)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? true
        readyForNextBatch = try c.decodeIfPresent(Bool.self, forKey: .readyForNextBatch) ?? false
        guard pendingGroups.allSatisfy({ !$0.itemIDs.isEmpty }) else { throw DecodingError.dataCorruptedError(forKey: .pendingGroups, in: c, debugDescription: "Invalid pending group") }

        let frozenIDs = frozenItems.map(\.id)
        let frozenSet = Set(frozenIDs)
        guard frozenIDs.count == frozenSet.count else {
            throw DecodingError.dataCorruptedError(forKey: .frozenItems, in: c, debugDescription: "Duplicate frozen item IDs")
        }

        let pendingIDs = pendingGroups.flatMap(\.itemIDs)
        let pendingSet = Set(pendingIDs)
        guard pendingIDs.count == pendingSet.count else {
            throw DecodingError.dataCorruptedError(forKey: .pendingGroups, in: c, debugDescription: "Duplicate pending item IDs")
        }

        let decodedRemainingIDs = remainingItemIDs
        let remainingSet = Set(decodedRemainingIDs)
        guard decodedRemainingIDs.count == remainingSet.count else {
            throw DecodingError.dataCorruptedError(forKey: .remainingItemIDs, in: c, debugDescription: "Duplicate remaining item IDs")
        }
        guard pendingSet.isSubset(of: frozenSet), remainingSet.isSubset(of: frozenSet) else {
            throw DecodingError.dataCorruptedError(forKey: .remainingItemIDs, in: c, debugDescription: "Unknown item ID in continuation")
        }
        guard pendingSet.isDisjoint(with: remainingSet) else {
            throw DecodingError.dataCorruptedError(forKey: .remainingItemIDs, in: c, debugDescription: "Pending and remaining items overlap")
        }
        let actualHasMore = !pendingSet.isEmpty || !remainingSet.isEmpty
        guard hasMore == actualHasMore else {
            throw DecodingError.dataCorruptedError(forKey: .hasMore, in: c, debugDescription: "Inconsistent continuation completion state")
        }
        remainingItemIDs = decodedRemainingIDs.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case version, sourceKey, groupingFingerprint, frozenItems, pendingGroups, remainingItemIDs, batchNumber, hasMore, readyForNextBatch
    }
}

enum ScanBatcher {
    static func makeSourceKey(settings: ScanSettings) -> String {
        let source: String
        switch settings.selectedSourceKind {
        case .photos:
            source = "photos|\(settings.sourceMode.rawValue)|\(settings.selectedAlbumID ?? "all")"
        case .folder:
            source = "folder|\(settings.folderSelection?.resolvedPath ?? "")|\(settings.folderSelection?.bookmarkDataBase64 ?? "")|recursive=\(settings.folderRecursiveScan)"
        }
        let dates = "|from=\(settings.dateFrom?.timeIntervalSince1970 ?? -1)|to=\(settings.dateTo?.timeIntervalSince1970 ?? -1)"
        return source + dates
    }

    static func groupingFingerprint(settings: ScanSettings) -> String {
        "videos=\(settings.includeVideos)|gap=\(settings.maxTimeGapSeconds)|threshold=\(settings.similarityDistanceThreshold)|source=\(settings.selectedSourceKind.rawValue)|mode=\(settings.sourceMode.rawValue)|recursive=\(settings.folderRecursiveScan)|dates=\(settings.dateFrom?.timeIntervalSince1970 ?? -1),\(settings.dateTo?.timeIntervalSince1970 ?? -1)"
    }

    static func partition(
        groups: [ReviewGroup],
        limit: Int
    ) -> (selected: [ReviewGroup], pending: [ReviewGroup]) {
        let ordered = groups.map(normalizedGroup).sorted(by: stableGroupOrder)
        let validLimit = min(max(limit, 1), 10_000)
        return (
            Array(ordered.prefix(validLimit)),
            Array(ordered.dropFirst(validLimit))
        )
    }

    static func normalizedGroup(_ group: ReviewGroup) -> ReviewGroup {
        ReviewGroup(
            id: group.id,
            itemIDs: group.itemIDs.sorted(),
            startDate: group.startDate,
            endDate: group.endDate
        )
    }

    static func stableGroupOrder(_ lhs: ReviewGroup, _ rhs: ReviewGroup) -> Bool {
        let ld = lhs.startDate ?? .distantPast
        let rd = rhs.startDate ?? .distantPast
        if ld != rd { return ld < rd }
        return lhs.itemIDs.sorted().lexicographicallyPrecedes(rhs.itemIDs.sorted())
    }
}

struct ScanBatchStateStore {
    let fileURL: URL

    func load() -> ScanBatchCheckpoint? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(ScanBatchCheckpoint.self, from: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return checkpoint
    }

    func save(_ checkpoint: ScanBatchCheckpoint) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(checkpoint) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
