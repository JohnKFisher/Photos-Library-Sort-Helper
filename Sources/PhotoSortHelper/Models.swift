import Foundation
import Photos

enum PhotoSourceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case allPhotos
    case album

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allPhotos: return "All Photos"
        case .album: return "Album"
        }
    }
}

enum AlbumKind: String, Hashable, Codable, Sendable {
    case user
    case smart

    var label: String {
        switch self {
        case .user: return "Album"
        case .smart: return "Smart"
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

struct ScanSettings: Sendable {
    var sourceMode: PhotoSourceMode
    var selectedAlbumID: String?
    var dateFrom: Date?
    var dateTo: Date?
    var includeVideos: Bool
    var autoPickBestShot: Bool
    var maxTimeGapSeconds: TimeInterval
    var similarityDistanceThreshold: Float
    var bestShotPersonalization: BestShotPersonalization? = nil
    var useDeepPassTieBreaker: Bool = true
    var deepPassCloseCallDelta: Double = 0.045
    var deepPassBlendWeight: Double = 0.10
}

struct ReviewGroup: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var assetIDs: [String]
    let startDate: Date
    let endDate: Date

    init(id: UUID = UUID(), assetIDs: [String], startDate: Date, endDate: Date) {
        self.id = id
        self.assetIDs = assetIDs
        self.startDate = startDate
        self.endDate = endDate
    }
}

struct ScanProgress: Sendable {
    var fractionCompleted: Double
    var message: String
}

struct ScanResult: Sendable {
    var groups: [ReviewGroup]
    var bestAssetByGroupID: [UUID: String]
    var suggestedDiscardAssetIDsByGroupID: [UUID: Set<String>]
    var bestShotScoresByAssetID: [String: BestShotScoreBreakdown]
    var assetLookup: [String: PHAsset]
    var scannedAssetCount: Int
    var temporalClusterCount: Int
}

struct BestShotScoreBreakdown: Codable, Sendable {
    var totalScore: Double
    var baseHeuristicScore: Double
    var learnedPreferenceScore: Double
    var learnedAdjustment: Double
    var facePresence: Double
    var framing: Double
    var eyesOpen: Double
    var smile: Double
    var subjectProminence: Double
    var subjectCentering: Double
    var sharpness: Double
    var lighting: Double
    var color: Double
    var contrast: Double
    var aestheticsScore: Double?
    var usedDeepPass: Bool
}

enum BestShotFeature: String, CaseIterable, Codable, Sendable {
    case facePresence
    case framing
    case eyesOpen
    case smile
    case subjectProminence
    case subjectCentering
    case sharpness
    case lighting
    case color
    case contrast
}

struct BestShotFeatureWeights: Codable, Hashable, Sendable {
    var facePresence: Double
    var framing: Double
    var eyesOpen: Double
    var smile: Double
    var subjectProminence: Double
    var subjectCentering: Double
    var sharpness: Double
    var lighting: Double
    var color: Double
    var contrast: Double

    static let baseline = BestShotFeatureWeights(
        facePresence: 0.16,
        framing: 0.15,
        eyesOpen: 0.16,
        smile: 0.10,
        subjectProminence: 0.07,
        subjectCentering: 0.07,
        sharpness: 0.12,
        lighting: 0.09,
        color: 0.06,
        contrast: 0.02
    )

    func value(for feature: BestShotFeature) -> Double {
        switch feature {
        case .facePresence: return facePresence
        case .framing: return framing
        case .eyesOpen: return eyesOpen
        case .smile: return smile
        case .subjectProminence: return subjectProminence
        case .subjectCentering: return subjectCentering
        case .sharpness: return sharpness
        case .lighting: return lighting
        case .color: return color
        case .contrast: return contrast
        }
    }

    func withValue(_ value: Double, for feature: BestShotFeature) -> BestShotFeatureWeights {
        var updated = self
        switch feature {
        case .facePresence: updated.facePresence = value
        case .framing: updated.framing = value
        case .eyesOpen: updated.eyesOpen = value
        case .smile: updated.smile = value
        case .subjectProminence: updated.subjectProminence = value
        case .subjectCentering: updated.subjectCentering = value
        case .sharpness: updated.sharpness = value
        case .lighting: updated.lighting = value
        case .color: updated.color = value
        case .contrast: updated.contrast = value
        }
        return updated
    }

    func normalized() -> BestShotFeatureWeights {
        let total = BestShotFeature.allCases.reduce(0.0) { partial, feature in
            partial + max(0.0001, value(for: feature))
        }

        guard total > 0 else {
            return .baseline
        }

        var normalized = BestShotFeatureWeights.baseline
        for feature in BestShotFeature.allCases {
            normalized = normalized.withValue(max(0.0001, value(for: feature)) / total, for: feature)
        }
        return normalized
    }

    func clamped(min minValue: Double = 0.005, max maxValue: Double = 0.45) -> BestShotFeatureWeights {
        var clamped = BestShotFeatureWeights.baseline
        for feature in BestShotFeature.allCases {
            clamped = clamped.withValue(
                Swift.min(maxValue, Swift.max(minValue, value(for: feature))),
                for: feature
            )
        }
        return clamped
    }
}

struct BestShotPersonalization: Sendable {
    var weights: BestShotFeatureWeights
    var confidence: Double

    init(weights: BestShotFeatureWeights, confidence: Double) {
        self.weights = weights.normalized()
        self.confidence = Swift.min(1.0, Swift.max(0.0, confidence))
    }
}

enum ReviewError: LocalizedError {
    case missingAlbumSelection
    case photoAccessDenied
    case albumNotFound

    var errorDescription: String? {
        switch self {
        case .missingAlbumSelection:
            return "Pick an album before scanning."
        case .photoAccessDenied:
            return "Photo access is denied. Enable access in System Settings > Privacy & Security > Photos."
        case .albumNotFound:
            return "The selected album could not be found."
        }
    }
}
