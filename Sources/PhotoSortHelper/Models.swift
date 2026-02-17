import Foundation
import Photos

enum PhotoSourceMode: String, CaseIterable, Identifiable {
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

enum AlbumKind: String, Hashable {
    case user
    case smart

    var label: String {
        switch self {
        case .user: return "Album"
        case .smart: return "Smart"
        }
    }
}

enum AlbumSourceKind: String, Hashable {
    case assetCollection
    case collectionList
}

struct AlbumOption: Identifiable, Hashable {
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

struct ScanSettings {
    var sourceMode: PhotoSourceMode
    var selectedAlbumID: String?
    var dateFrom: Date?
    var dateTo: Date?
    var includeVideos: Bool
    var maxTimeGapSeconds: TimeInterval
    var similarityDistanceThreshold: Float
    var maxAssetsToScan: Int
}

struct ReviewGroup: Identifiable, Hashable {
    let id: UUID
    var assetIDs: [String]
    let startDate: Date
    let endDate: Date

    init(assetIDs: [String], startDate: Date, endDate: Date) {
        self.id = UUID()
        self.assetIDs = assetIDs
        self.startDate = startDate
        self.endDate = endDate
    }
}

struct ScanProgress {
    var fractionCompleted: Double
    var message: String
}

struct ScanResult {
    var groups: [ReviewGroup]
    var assetLookup: [String: PHAsset]
    var scannedAssetCount: Int
    var temporalClusterCount: Int
}

enum ReviewError: LocalizedError {
    case missingAlbumSelection
    case photoAccessDenied
    case albumNotFound
    case deletionCancelled
    case deletionFailed

    var errorDescription: String? {
        switch self {
        case .missingAlbumSelection:
            return "Pick an album before scanning."
        case .photoAccessDenied:
            return "Photo access is denied. Enable access in System Settings > Privacy & Security > Photos."
        case .albumNotFound:
            return "The selected album could not be found."
        case .deletionCancelled:
            return "Deletion was cancelled."
        case .deletionFailed:
            return "Photos could not be deleted."
        }
    }
}
