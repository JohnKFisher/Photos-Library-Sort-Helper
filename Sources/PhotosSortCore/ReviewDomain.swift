import CryptoKit
import Foundation

public enum ReviewDecision: String, Codable, CaseIterable, Sendable {
    case keep
    case discard
    case edit
}

public enum DecisionOrigin: String, Codable, Sendable {
    case explicit
    case completedDefault
}

public enum PendingItemStatus: String, Codable, Sendable {
    case pending
    case conflict
    case unavailable
}

public enum SavedGroupState: String, Codable, Sendable {
    case unresolved
    case completed
    case skipped
}

public enum DestinationRole: String, Codable, CaseIterable, Sendable {
    case fullySorted
    case manualDelete
    case edit
}

public struct DestinationAlbumBinding: Codable, Hashable, Sendable, Identifiable {
    public let libraryKey: String
    public let role: DestinationRole
    public let localIdentifier: String
    public let cloudIdentifier: String?
    public let title: String
    public let updatedAt: Date

    public var id: String { "\(libraryKey):\(role.rawValue)" }

    public init(libraryKey: String, role: DestinationRole, localIdentifier: String, cloudIdentifier: String?, title: String, updatedAt: Date = Date()) {
        self.libraryKey = libraryKey
        self.role = role
        self.localIdentifier = localIdentifier
        self.cloudIdentifier = cloudIdentifier
        self.title = title
        self.updatedAt = updatedAt
    }
}

public enum CommitItemOutcome: String, Codable, Sendable {
    case verifiedCommitted
    case conflict
    case unavailable
    case retryable
}

/// Converts an observed PhotoKit membership snapshot into the queue outcome
/// used by both the Mac and iOS adapters.
public enum PhotoCommitReconciliation {
    public static func destination(for decision: ReviewDecision) -> DestinationRole {
        switch decision {
        case .keep: .fullySorted
        case .discard: .manualDelete
        case .edit: .edit
        }
    }

    public static func outcome(
        for decision: ReviewDecision,
        memberships: Set<DestinationRole>,
        assetAvailable: Bool
    ) -> CommitItemOutcome {
        let expected = destination(for: decision)
        if memberships.count > 1 || (!memberships.isEmpty && !memberships.contains(expected)) {
            return .conflict
        }
        if memberships.contains(expected) { return .verifiedCommitted }
        return assetAvailable ? .retryable : .unavailable
    }
}

public struct ReviewMediaMetadata: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let preferredDate: Date?
    public let isVideo: Bool
    /// Live Photos are still image items and participate in image time groups.
    public let isLivePhoto: Bool

    public init(id: String, preferredDate: Date?, isVideo: Bool, isLivePhoto: Bool = false) {
        self.id = id
        self.preferredDate = preferredDate
        self.isVideo = isVideo
        self.isLivePhoto = isLivePhoto
    }
}

public struct ReviewGroupSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let scopeID: String
    public let position: Int
    public let itemIDs: [String]
    public let startDate: Date?
    public let endDate: Date?
    public let groupingFingerprint: String
    public var state: SavedGroupState

    public init(
        id: String,
        scopeID: String,
        position: Int,
        itemIDs: [String],
        startDate: Date?,
        endDate: Date?,
        groupingFingerprint: String,
        state: SavedGroupState = .unresolved
    ) {
        self.id = id
        self.scopeID = scopeID
        self.position = position
        self.itemIDs = itemIDs
        self.startDate = startDate
        self.endDate = endDate
        self.groupingFingerprint = groupingFingerprint
        self.state = state
    }
}

public struct ScopePosition: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var currentGroupID: String?
    public var currentItemID: String?
    public var fallbackGroupIndex: Int
    public let groupingFingerprint: String
    public var checkpointJSON: String?

    public init(
        id: String,
        currentGroupID: String?,
        currentItemID: String?,
        fallbackGroupIndex: Int,
        groupingFingerprint: String,
        checkpointJSON: String? = nil
    ) {
        self.id = id
        self.currentGroupID = currentGroupID
        self.currentItemID = currentItemID
        self.fallbackGroupIndex = max(0, fallbackGroupIndex)
        self.groupingFingerprint = groupingFingerprint
        self.checkpointJSON = checkpointJSON
    }
}

public struct PendingReviewItem: Codable, Hashable, Sendable, Identifiable {
    public let libraryKey: String
    public let assetID: String
    public var cloudIdentifier: String?
    public var decision: ReviewDecision
    public var origin: DecisionOrigin
    public var revision: Int64
    public var scopeID: String?
    public var groupID: String?
    public var status: PendingItemStatus
    public var updatedAt: Date

    public var id: String { "\(libraryKey):\(assetID)" }

    public init(
        libraryKey: String,
        assetID: String,
        cloudIdentifier: String? = nil,
        decision: ReviewDecision,
        origin: DecisionOrigin,
        revision: Int64 = 1,
        scopeID: String? = nil,
        groupID: String? = nil,
        status: PendingItemStatus = .pending,
        updatedAt: Date = Date()
    ) {
        self.libraryKey = libraryKey
        self.assetID = assetID
        self.cloudIdentifier = cloudIdentifier
        self.decision = decision
        self.origin = origin
        self.revision = max(1, revision)
        self.scopeID = scopeID
        self.groupID = groupID
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct CommitItemIntent: Codable, Hashable, Sendable, Identifiable {
    public let libraryKey: String
    public let assetID: String
    public let cloudIdentifier: String?
    public let decision: ReviewDecision
    public let revision: Int64
    public let scopeID: String?
    public let groupID: String?
    public var outcome: CommitItemOutcome?

    public var id: String { "\(libraryKey):\(assetID)" }
}

public struct CommitAttempt: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let startedAt: Date
    public var items: [CommitItemIntent]
}

public struct ExplicitDecision: Codable, Hashable, Sendable {
    public let assetID: String
    public let cloudIdentifier: String?
    public let decision: ReviewDecision
    public let scopeID: String
    public let groupID: String

    public init(assetID: String, cloudIdentifier: String?, decision: ReviewDecision, scopeID: String, groupID: String) {
        self.assetID = assetID
        self.cloudIdentifier = cloudIdentifier
        self.decision = decision
        self.scopeID = scopeID
        self.groupID = groupID
    }
}

public struct LegacyReviewImport: Codable, Hashable, Sendable {
    public let sourceDigest: String
    public let libraryKey: String
    public let scopePosition: ScopePosition
    public let groups: [ReviewGroupSnapshot]
    public let explicitDecisions: [ExplicitDecision]

    public init(
        sourceDigest: String,
        libraryKey: String,
        scopePosition: ScopePosition,
        groups: [ReviewGroupSnapshot],
        explicitDecisions: [ExplicitDecision]
    ) {
        self.sourceDigest = sourceDigest
        self.libraryKey = libraryKey
        self.scopePosition = scopePosition
        self.groups = groups
        self.explicitDecisions = explicitDecisions
    }
}

public enum TemporalGrouping {
    public static let algorithmVersion = 3

    public static func fingerprint(maxGapSeconds: TimeInterval) -> String {
        let gap = max(0, maxGapSeconds.isFinite ? maxGapSeconds : 0)
        return "adjacent-gap-v\(algorithmVersion)|gap=\(gap.bitPattern)"
    }

    /// Groups images by adjacent capture-time gaps; the boundary is inclusive and chains are transitive.
    /// A video is always a singleton. Items without a usable date are stable, isolated singletons.
    public static func groups(
        from input: [ReviewMediaMetadata],
        maxGapSeconds: TimeInterval,
        scopeID: String = ""
    ) -> [ReviewGroupSnapshot] {
        guard !input.isEmpty else { return [] }
        let gap = max(0, maxGapSeconds.isFinite ? maxGapSeconds : 0)
        let ordered = input.sorted(by: stableItemOrder)
        var output: [ReviewGroupSnapshot] = []
        var temporalCluster: [ReviewMediaMetadata] = []

        func append(_ items: [ReviewMediaMetadata]) {
            guard !items.isEmpty else { return }
            let ids = items.map(\.id)
            let dates = items.compactMap(\.preferredDate)
            let startDate = dates.first
            let endDate = dates.last
            let canonical = "\(scopeID.utf8.count):\(scopeID)|" + ids.map { "\($0.utf8.count):\($0)" }.joined()
            let digest = SHA256.hash(data: Data(canonical.utf8))
            let id = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
            output.append(ReviewGroupSnapshot(
                id: id,
                scopeID: scopeID,
                position: 0,
                itemIDs: ids,
                startDate: startDate,
                endDate: endDate,
                groupingFingerprint: fingerprint(maxGapSeconds: gap)
            ))
        }

        func flushTemporalCluster() {
            guard !temporalCluster.isEmpty else { return }
            let images = temporalCluster.filter { !$0.isVideo }
            append(images)
            temporalCluster.filter(\.isVideo).forEach { append([$0]) }
            temporalCluster.removeAll(keepingCapacity: true)
        }

        var previousDate: Date?
        for item in ordered {
            guard let date = item.preferredDate else {
                flushTemporalCluster()
                append([item])
                previousDate = nil
                continue
            }

            if let previousDate, date.timeIntervalSince(previousDate) > gap {
                flushTemporalCluster()
            }
            temporalCluster.append(item)
            previousDate = date
        }
        flushTemporalCluster()
        return output.sorted(by: stableGroupOrder).enumerated().map { index, group in
            ReviewGroupSnapshot(
                id: group.id,
                scopeID: group.scopeID,
                position: index,
                itemIDs: group.itemIDs,
                startDate: group.startDate,
                endDate: group.endDate,
                groupingFingerprint: group.groupingFingerprint,
                state: group.state
            )
        }
    }

    private static func stableItemOrder(_ lhs: ReviewMediaMetadata, _ rhs: ReviewMediaMetadata) -> Bool {
        switch (lhs.preferredDate, rhs.preferredDate) {
        case let (.some(left), .some(right)) where left != right:
            return left < right
        case (.none, .some):
            return true
        case (.some, .none):
            return false
        default:
            return lhs.id < rhs.id
        }
    }

    private static func stableGroupOrder(_ lhs: ReviewGroupSnapshot, _ rhs: ReviewGroupSnapshot) -> Bool {
        let leftDate = lhs.startDate ?? .distantPast
        let rightDate = rhs.startDate ?? .distantPast
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.itemIDs.lexicographicallyPrecedes(rhs.itemIDs)
    }
}

public enum ReviewScopeIdentity {
    public static func make(
        sourceDescriptor: String,
        dateFrom: Date?,
        dateTo: Date?,
        groupingFingerprint: String
    ) -> String {
        func bits(_ date: Date?) -> String {
            guard let date else { return "none" }
            return String(date.timeIntervalSince1970.bitPattern, radix: 16)
        }
        let canonical = [sourceDescriptor, bits(dateFrom), bits(dateTo), groupingFingerprint]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Restores a per-scope cursor against the newly enumerated eligible frontier.
/// Array offsets alone are not stable when Photos membership changes between scans.
public enum ReviewFrontierPosition {
    public static func resolve(
        groupIDs: [String],
        itemIDsByGroup: [[String]],
        previouslyKnownGroupIDs: Set<String>,
        previouslyCompletedGroupIDs: Set<String> = [],
        currentGroupID: String?,
        currentItemID: String?,
        fallbackGroupIndex: Int
    ) -> Int {
        guard !groupIDs.isEmpty else { return 0 }

        if let currentItemID,
           let index = itemIDsByGroup.firstIndex(where: { $0.contains(currentItemID) }) {
            return index
        }
        if let currentGroupID, let index = groupIDs.firstIndex(of: currentGroupID) {
            return index
        }
        if let newWorkIndex = groupIDs.firstIndex(where: {
            !previouslyKnownGroupIDs.contains($0) || previouslyCompletedGroupIDs.contains($0)
        }) {
            return newWorkIndex
        }
        return min(max(0, fallbackGroupIndex), groupIDs.count)
    }
}
