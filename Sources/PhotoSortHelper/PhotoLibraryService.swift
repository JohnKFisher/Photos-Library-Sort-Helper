import AppKit
import AVFoundation
import Foundation
import Photos

final class PhotoLibraryService: @unchecked Sendable {
    enum EditAlbumQueueResult: Sendable {
        case addedToExistingAlbum
        case createdAlbumAndAdded
        case alreadyInAlbum
    }

    struct AlbumQueueBatchResult: Sendable {
        let albumTitle: String
        let createdAlbum: Bool
        let requestedCount: Int
        let addedCount: Int
        let alreadyPresentCount: Int
        let missingCount: Int
        let processedAssetIDs: Set<String>
    }

    private enum ServiceError: LocalizedError {
        case assetNotFound
        case albumCreationFailed
        case albumFetchFailed
        case albumMutationFailed

        var errorDescription: String? {
            switch self {
            case .assetNotFound:
                return "The selected item could not be found in Photos."
            case .albumCreationFailed:
                return "The target album could not be created."
            case .albumFetchFailed:
                return "The target album could not be loaded."
            case .albumMutationFailed:
                return "The item could not be added to the target album."
            }
        }
    }

    final class VideoAssetBox: @unchecked Sendable {
        let asset: AVAsset

        init(asset: AVAsset) {
            self.asset = asset
        }
    }

    private let imageManager = PHCachingImageManager()

    func currentAuthorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func fetchAlbums() -> [AlbumOption] {
        var albums: [AlbumOption] = []
        var seen: Set<String> = []

        // Walk the same top-level hierarchy Photos shows in the sidebar.
        let topLevelCollections = PHCollection.fetchTopLevelUserCollections(with: nil)
        for index in 0..<topLevelCollections.count {
            appendCollection(
                topLevelCollections.object(at: index),
                inheritedKind: nil,
                to: &albums,
                seen: &seen
            )
        }

        // Fallback only if the top-level enumeration is empty.
        if albums.isEmpty {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]

            let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
            appendAlbums(from: userAlbums, kind: .user, to: &albums, seen: &seen)
        }

        return albums.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func fetchAssets(settings: ScanSettings) throws -> [PHAsset] {
        guard settings.sourceMode != .album || settings.selectedAlbumID != nil else {
            throw ReviewError.missingAlbumSelection
        }

        switch settings.sourceMode {
        case .allPhotos:
            let fetchResult = PHAsset.fetchAssets(
                with: assetFetchOptions(
                    dateFrom: settings.dateFrom,
                    dateTo: settings.dateTo,
                    includeVideos: settings.includeVideos
                )
            )
            return assets(from: fetchResult)

        case .album:
            let selectedID = settings.selectedAlbumID ?? ""
            let source = parseSelectedSource(selectedID) ?? (kind: .assetCollection, localIdentifier: selectedID)

            switch source.kind {
            case .assetCollection:
                let albumResult = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [source.localIdentifier],
                    options: nil
                )
                guard let album = albumResult.firstObject else {
                    throw ReviewError.albumNotFound
                }

                let fetchResult = PHAsset.fetchAssets(
                    in: album,
                    options: assetFetchOptions(
                        dateFrom: settings.dateFrom,
                        dateTo: settings.dateTo,
                        includeVideos: settings.includeVideos
                    )
                )
                return assets(from: fetchResult)

            case .collectionList:
                let listResult = PHCollectionList.fetchCollectionLists(
                    withLocalIdentifiers: [source.localIdentifier],
                    options: nil
                )
                guard let list = listResult.firstObject else {
                    throw ReviewError.albumNotFound
                }

                let assets = assets(
                    in: list,
                    dateFrom: settings.dateFrom,
                    dateTo: settings.dateTo,
                    includeVideos: settings.includeVideos
                )
                return assets
            }
        }
    }

    func estimateAssetCount(settings: ScanSettings) throws -> Int {
        guard settings.sourceMode != .album || settings.selectedAlbumID != nil else {
            throw ReviewError.missingAlbumSelection
        }

        switch settings.sourceMode {
        case .allPhotos:
            return PHAsset.fetchAssets(
                with: assetFetchOptions(
                    dateFrom: settings.dateFrom,
                    dateTo: settings.dateTo,
                    includeVideos: settings.includeVideos
                )
            ).count

        case .album:
            let selectedID = settings.selectedAlbumID ?? ""
            let source = parseSelectedSource(selectedID) ?? (kind: .assetCollection, localIdentifier: selectedID)

            switch source.kind {
            case .assetCollection:
                let albumResult = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [source.localIdentifier],
                    options: nil
                )
                guard let album = albumResult.firstObject else {
                    throw ReviewError.albumNotFound
                }

                return PHAsset.fetchAssets(
                    in: album,
                    options: assetFetchOptions(
                        dateFrom: settings.dateFrom,
                        dateTo: settings.dateTo,
                        includeVideos: settings.includeVideos
                    )
                ).count

            case .collectionList:
                let listResult = PHCollectionList.fetchCollectionLists(
                    withLocalIdentifiers: [source.localIdentifier],
                    options: nil
                )
                guard let list = listResult.firstObject else {
                    throw ReviewError.albumNotFound
                }

                return assets(
                    in: list,
                    dateFrom: settings.dateFrom,
                    dateTo: settings.dateTo,
                    includeVideos: settings.includeVideos
                ).count
            }
        }
    }

    func requestThumbnail(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let resumeLock = NSLock()
            var didResume = false
            func resumeOnce(_ image: NSImage?) {
                resumeLock.lock()
                guard !didResume else {
                    resumeLock.unlock()
                    return
                }
                didResume = true
                resumeLock.unlock()
                continuation.resume(returning: image)
            }

            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    resumeOnce(nil)
                    return
                }

                if info?[PHImageErrorKey] != nil {
                    resumeOnce(nil)
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false

                switch deliveryMode {
                case .highQualityFormat:
                    guard !isDegraded else {
                        return
                    }
                    resumeOnce(image)
                case .opportunistic, .fastFormat:
                    if let image {
                        resumeOnce(image)
                    } else if !isDegraded {
                        resumeOnce(nil)
                    }
                @unknown default:
                    if let image {
                        resumeOnce(image)
                    } else if !isDegraded {
                        resumeOnce(nil)
                    }
                }
            }
        }
    }

    func requestCGImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) async -> CGImage? {
        guard
            let image = await requestThumbnail(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode
            )
        else {
            return nil
        }

        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func requestAVAsset(for asset: PHAsset) async -> VideoAssetBox? {
        guard asset.mediaType == .video else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.version = .current
            options.isNetworkAccessAllowed = true

            let resumeLock = NSLock()
            var didResume = false
            func resumeOnce(_ box: VideoAssetBox?) {
                resumeLock.lock()
                guard !didResume else {
                    resumeLock.unlock()
                    return
                }
                didResume = true
                resumeLock.unlock()
                continuation.resume(returning: box)
            }

            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    resumeOnce(nil)
                    return
                }

                if info?[PHImageErrorKey] != nil {
                    resumeOnce(nil)
                    return
                }

                if let avAsset {
                    resumeOnce(VideoAssetBox(asset: avAsset))
                } else {
                    resumeOnce(nil)
                }
            }
        }
    }

    func fetchAssetsByLocalIdentifier(_ assetIDs: [String]) -> [String: PHAsset] {
        guard !assetIDs.isEmpty else {
            return [:]
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var lookup: [String: PHAsset] = [:]
        lookup.reserveCapacity(fetchResult.count)

        for index in 0..<fetchResult.count {
            let asset = fetchResult.object(at: index)
            lookup[asset.localIdentifier] = asset
        }

        return lookup
    }

    func estimatedByteSize(forAssetID assetID: String) -> Int64? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetchResult.firstObject else {
            return nil
        }

        return estimatedByteSize(for: asset)
    }

    func estimatedByteSize(for asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else {
            return nil
        }

        var total: Int64 = 0
        for resource in resources {
            if let size = resource.value(forKey: "fileSize") as? CLong {
                total += Int64(size)
            } else if let size = resource.value(forKey: "fileSize") as? Int64 {
                total += size
            } else if let size = resource.value(forKey: "fileSize") as? NSNumber {
                total += size.int64Value
            }
        }

        return total > 0 ? total : nil
    }

    func queueAssetForEditing(
        withIdentifier assetID: String,
        albumTitle: String = "Files to Edit"
    ) async throws -> EditAlbumQueueResult {
        let result = try await queueAssets(
            withIdentifiers: [assetID],
            intoAlbumTitle: albumTitle
        )

        if result.addedCount > 0 {
            return result.createdAlbum ? .createdAlbumAndAdded : .addedToExistingAlbum
        }

        return .alreadyInAlbum
    }

    func queueAssets(
        withIdentifiers identifiers: [String],
        intoAlbumTitle albumTitle: String
    ) async throws -> AlbumQueueBatchResult {
        var seen: Set<String> = []
        let requestedIDs = identifiers.filter { seen.insert($0).inserted }
        guard !requestedIDs.isEmpty else {
            return AlbumQueueBatchResult(
                albumTitle: albumTitle,
                createdAlbum: false,
                requestedCount: 0,
                addedCount: 0,
                alreadyPresentCount: 0,
                missingCount: 0,
                processedAssetIDs: []
            )
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: requestedIDs, options: nil)
        var foundAssets: [PHAsset] = []
        foundAssets.reserveCapacity(fetchResult.count)
        var foundIDs: Set<String> = []

        for index in 0..<fetchResult.count {
            let asset = fetchResult.object(at: index)
            foundAssets.append(asset)
            foundIDs.insert(asset.localIdentifier)
        }

        guard !foundAssets.isEmpty else {
            throw ServiceError.assetNotFound
        }

        let album: PHAssetCollection
        let createdAlbum: Bool
        if let existing = fetchAlbum(named: albumTitle) {
            album = existing
            createdAlbum = false
        } else {
            album = try await createAlbum(named: albumTitle)
            createdAlbum = true
        }

        let alreadyPresentIDs = assetIDs(in: album, matchingLocalIdentifiers: foundIDs)
        let assetsToAdd = foundAssets.filter { !alreadyPresentIDs.contains($0.localIdentifier) }
        if !assetsToAdd.isEmpty {
            try await addAssets(assetsToAdd, to: album)
        }

        return AlbumQueueBatchResult(
            albumTitle: albumTitle,
            createdAlbum: createdAlbum,
            requestedCount: requestedIDs.count,
            addedCount: assetsToAdd.count,
            alreadyPresentCount: alreadyPresentIDs.count,
            missingCount: max(0, requestedIDs.count - foundIDs.count),
            processedAssetIDs: foundIDs
        )
    }

    private func appendAlbums(
        from fetchResult: PHFetchResult<PHAssetCollection>,
        kind: AlbumKind,
        to albums: inout [AlbumOption],
        seen: inout Set<String>
    ) {
        for index in 0..<fetchResult.count {
            let album = fetchResult.object(at: index)
            guard let title = album.localizedTitle, !title.isEmpty else {
                continue
            }

            let count = resolvedImageCount(for: album)
            guard count > 0 else {
                continue
            }

            addAlbumOption(
                localIdentifier: album.localIdentifier,
                sourceKind: .assetCollection,
                title: title,
                kind: kind,
                count: count,
                to: &albums,
                seen: &seen
            )
        }
    }

    private func appendCollection(
        _ collection: PHCollection,
        inheritedKind: AlbumKind?,
        to albums: inout [AlbumOption],
        seen: inout Set<String>
    ) {
        if let assetCollection = collection as? PHAssetCollection {
            guard let title = assetCollection.localizedTitle, !title.isEmpty else {
                return
            }

            let count = resolvedImageCount(for: assetCollection)
            guard count > 0 else {
                return
            }

            addAlbumOption(
                localIdentifier: assetCollection.localIdentifier,
                sourceKind: .assetCollection,
                title: title,
                kind: kindForAssetCollection(assetCollection),
                count: count,
                to: &albums,
                seen: &seen
            )
            return
        }

        guard let collectionList = collection as? PHCollectionList else {
            return
        }

        if collectionList.collectionListType == .smartFolder,
           let title = collectionList.localizedTitle,
           !title.isEmpty {
            let count = imageAssetCount(in: collectionList)
            if count > 0 {
                addAlbumOption(
                    localIdentifier: collectionList.localIdentifier,
                    sourceKind: .collectionList,
                    title: title,
                    kind: .smart,
                    count: count,
                    to: &albums,
                    seen: &seen
                )
            }
        }

        let children = PHCollection.fetchCollections(in: collectionList, options: nil)
        for childIndex in 0..<children.count {
            appendCollection(
                children.object(at: childIndex),
                inheritedKind: inheritedKind,
                to: &albums,
                seen: &seen
            )
        }
    }

    private func addAlbumOption(
        localIdentifier: String,
        sourceKind: AlbumSourceKind,
        title: String,
        kind: AlbumKind,
        count: Int,
        to albums: inout [AlbumOption],
        seen: inout Set<String>
    ) {
        let key = sourceKey(localIdentifier: localIdentifier, sourceKind: sourceKind)
        guard !seen.contains(key) else {
            return
        }

        seen.insert(key)
        albums.append(
            AlbumOption(
                localIdentifier: localIdentifier,
                sourceKind: sourceKind,
                title: title,
                kind: kind,
                estimatedAssetCount: count
            )
        )
    }

    private func sourceKey(localIdentifier: String, sourceKind: AlbumSourceKind) -> String {
        "\(sourceKind.rawValue):\(localIdentifier)"
    }

    private func parseSelectedSource(_ selectedID: String) -> (kind: AlbumSourceKind, localIdentifier: String)? {
        guard let separator = selectedID.firstIndex(of: ":") else {
            return nil
        }

        let kindRaw = String(selectedID[..<separator])
        guard let kind = AlbumSourceKind(rawValue: kindRaw) else {
            return nil
        }

        let localIdentifier = String(selectedID[selectedID.index(after: separator)...])
        guard !localIdentifier.isEmpty else {
            return nil
        }

        return (kind, localIdentifier)
    }

    private func assets(from fetchResult: PHFetchResult<PHAsset>) -> [PHAsset] {
        let count = fetchResult.count
        var assets: [PHAsset] = []
        assets.reserveCapacity(count)

        for index in 0..<count {
            assets.append(fetchResult.object(at: index))
        }

        return assets
    }

    private func assetFetchOptions(
        dateFrom: Date?,
        dateTo: Date?,
        includeVideos: Bool
    ) -> PHFetchOptions {
        let options = PHFetchOptions()
        var mediaPredicates: [NSPredicate] = [
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        ]
        if includeVideos {
            mediaPredicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        }

        var predicates: [NSPredicate] = [
            NSCompoundPredicate(orPredicateWithSubpredicates: mediaPredicates)
        ]

        if let dateFrom {
            predicates.append(NSPredicate(format: "creationDate >= %@", dateFrom as NSDate))
        }

        if let dateTo {
            predicates.append(NSPredicate(format: "creationDate <= %@", dateTo as NSDate))
        }

        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    private func imageOnlyFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    private func resolvedImageCount(for collection: PHAssetCollection) -> Int {
        let estimatedCount = collection.estimatedAssetCount
        if estimatedCount == NSNotFound || estimatedCount <= 0 {
            return imageAssetCount(in: collection)
        }

        return estimatedCount
    }

    private func imageAssetCount(in collection: PHAssetCollection) -> Int {
        PHAsset.fetchAssets(in: collection, options: imageOnlyFetchOptions()).count
    }

    private func imageAssetCount(in collectionList: PHCollectionList) -> Int {
        var ids: Set<String> = []
        collectAssetIdentifiers(in: collectionList, into: &ids)
        return ids.count
    }

    private func collectAssetIdentifiers(in collection: PHCollection, into ids: inout Set<String>) {
        if let assetCollection = collection as? PHAssetCollection {
            let assets = PHAsset.fetchAssets(in: assetCollection, options: imageOnlyFetchOptions())
            for index in 0..<assets.count {
                ids.insert(assets.object(at: index).localIdentifier)
            }
            return
        }

        guard let collectionList = collection as? PHCollectionList else {
            return
        }

        let children = PHCollection.fetchCollections(in: collectionList, options: nil)
        for childIndex in 0..<children.count {
            collectAssetIdentifiers(in: children.object(at: childIndex), into: &ids)
        }
    }

    private func assets(
        in collectionList: PHCollectionList,
        dateFrom: Date?,
        dateTo: Date?,
        includeVideos: Bool
    ) -> [PHAsset] {
        var assetsByID: [String: PHAsset] = [:]
        collectAssets(
            in: collectionList,
            dateFrom: dateFrom,
            dateTo: dateTo,
            includeVideos: includeVideos,
            into: &assetsByID
        )

        return assetsByID.values.sorted { lhs, rhs in
            (lhs.creationDate ?? .distantPast) < (rhs.creationDate ?? .distantPast)
        }
    }

    private func collectAssets(
        in collection: PHCollection,
        dateFrom: Date?,
        dateTo: Date?,
        includeVideos: Bool,
        into assetsByID: inout [String: PHAsset]
    ) {
        if let assetCollection = collection as? PHAssetCollection {
            let assets = PHAsset.fetchAssets(
                in: assetCollection,
                options: assetFetchOptions(
                    dateFrom: dateFrom,
                    dateTo: dateTo,
                    includeVideos: includeVideos
                )
            )
            for index in 0..<assets.count {
                let asset = assets.object(at: index)
                assetsByID[asset.localIdentifier] = asset
            }
            return
        }

        guard let collectionList = collection as? PHCollectionList else {
            return
        }

        let children = PHCollection.fetchCollections(in: collectionList, options: nil)
        for childIndex in 0..<children.count {
            collectAssets(
                in: children.object(at: childIndex),
                dateFrom: dateFrom,
                dateTo: dateTo,
                includeVideos: includeVideos,
                into: &assetsByID
            )
        }
    }

    private func kindForAssetCollection(_ collection: PHAssetCollection) -> AlbumKind {
        collection.assetCollectionType == .smartAlbum ? .smart : .user
    }

    private func fetchAlbum(named title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle ==[c] %@", title)
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: options
        )
        return albums.firstObject
    }

    private func assetIDs(
        in album: PHAssetCollection,
        matchingLocalIdentifiers localIdentifiers: Set<String>
    ) -> Set<String> {
        guard !localIdentifiers.isEmpty else {
            return []
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier IN %@", Array(localIdentifiers))

        let assets = PHAsset.fetchAssets(in: album, options: options)
        var existingIDs: Set<String> = []
        existingIDs.reserveCapacity(assets.count)

        for index in 0..<assets.count {
            existingIDs.insert(assets.object(at: index).localIdentifier)
        }

        return existingIDs
    }

    private func createAlbum(named title: String) async throws -> PHAssetCollection {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ServiceError.albumCreationFailed)
                }
            }
        }

        guard let album = fetchAlbum(named: title) else {
            throw ServiceError.albumFetchFailed
        }

        return album
    }

    private func addAssets(_ assets: [PHAsset], to album: PHAssetCollection) async throws {
        guard !assets.isEmpty else {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: album) else {
                    return
                }
                request.addAssets(assets as NSArray)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ServiceError.albumMutationFailed)
                }
            }
        }
    }
}
