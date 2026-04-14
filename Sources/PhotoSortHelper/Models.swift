import Foundation
import Photos

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

struct ScanSettings: Sendable {
    var sourceMode: PhotoSourceMode
    var selectedAlbumID: String?
    var dateFrom: Date?
    var dateTo: Date?
    var includeVideos: Bool
    var maxTimeGapSeconds: TimeInterval
    var similarityDistanceThreshold: Float
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
    var assetLookup: [String: PHAsset]
    var scannedAssetCount: Int
    var temporalClusterCount: Int
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
            return "Photos access is denied. Enable it in System Settings > Privacy & Security > Photos."
        case .albumNotFound:
            return "The selected album could not be found."
        }
    }
}
