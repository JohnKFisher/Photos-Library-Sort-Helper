import AppKit
import AVFoundation
import Foundation
import Photos
import PhotosSortCore

final class PhotoLibraryService: @unchecked Sendable {
    private static let videoScreenRecordingSubtype = PHAssetMediaSubtype(rawValue: 1 << 19)

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
        case ambiguousDestinationAlbum
        case missingDestinationAlbum

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
            case .ambiguousDestinationAlbum:
                return "A destination album binding is duplicated. Review the three album bindings before committing."
            case .missingDestinationAlbum:
                return "A destination album is no longer available. Rebind it before continuing."
            }
        }
    }

    final class VideoAssetBox: @unchecked Sendable {
        let asset: AVAsset

        init(asset: AVAsset) {
            self.asset = asset
        }
    }

    final class ImageBox: @unchecked Sendable {
        let image: NSImage?

        init(image: NSImage?) {
            self.image = image
        }
    }

    final class LivePhotoBox: @unchecked Sendable {
        let livePhoto: PHLivePhoto?

        init(livePhoto: PHLivePhoto?) {
            self.livePhoto = livePhoto
        }
    }

    private final class InspectionRequestState<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHImageRequestID?
        private var cancelled = false
        private var finished = false
        private var resume: ((Result<Value, Error>) -> Void)?

        func installResume(_ resume: @escaping (Result<Value, Error>) -> Void) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, !finished else { return false }
            self.resume = resume
            return true
        }

        func setRequestID(_ requestID: PHImageRequestID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, !finished else { return false }
            self.requestID = requestID
            return true
        }

        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let resume = self.resume
            self.resume = nil
            lock.unlock()
            resume?(result)
        }

        func cancel(using imageManager: PHCachingImageManager) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            cancelled = true
            finished = true
            let requestID = self.requestID
            let resume = self.resume
            self.resume = nil
            lock.unlock()

            if let requestID { imageManager.cancelImageRequest(requestID) }
            resume?(.failure(CancellationError()))
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private final class PhotoRequestCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHImageRequestID?
        private var cancelled = false

        func setRequestID(_ requestID: PHImageRequestID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.requestID = requestID
            return true
        }

        func cancel(using imageManager: PHCachingImageManager) {
            lock.lock()
            cancelled = true
            let requestID = self.requestID
            lock.unlock()

            if let requestID {
                imageManager.cancelImageRequest(requestID)
            }
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    final class PlayerItemBox: @unchecked Sendable {
        let item: AVPlayerItem

        init(item: AVPlayerItem) {
            self.item = item
        }
    }

    enum PlayerItemRequestResult: Sendable {
        case success(PlayerItemBox)
        case unavailable(String)
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

    func destinationAlbumCandidates() -> [PHAssetCollection] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let fetched = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        return (0..<fetched.count).map { fetched.object(at: $0) }
            .filter { $0.localizedTitle?.isEmpty == false }
    }

    func destinationMemberships(
        albumLocalIdentifiers: [DestinationRole: String]
    ) throws -> [DestinationRole: Set<String>] {
        guard Set(albumLocalIdentifiers.values).count == DestinationRole.allCases.count,
              albumLocalIdentifiers.count == DestinationRole.allCases.count else {
            throw ServiceError.ambiguousDestinationAlbum
        }
        var result: [DestinationRole: Set<String>] = [:]
        for role in DestinationRole.allCases {
            guard let identifier = albumLocalIdentifiers[role],
                  let album = fetchAlbum(localIdentifier: identifier) else {
                throw ServiceError.missingDestinationAlbum
            }
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            var ids: Set<String> = []
            ids.reserveCapacity(assets.count)
            for index in 0..<assets.count { ids.insert(assets.object(at: index).localIdentifier) }
            result[role] = ids
        }
        return result
    }

    /// Adds the frozen commit plan in one PhotoKit transaction, then verifies it from
    /// fresh album membership reads. It never removes assets from any album.
    func addPhotos(
        from attempt: CommitAttempt,
        albumLocalIdentifiers: [DestinationRole: String]
    ) async throws -> [String: CommitItemOutcome] {
        let albums = try resolveDestinationCollections(albumLocalIdentifiers)
        let before = try destinationMemberships(albumLocalIdentifiers: albumLocalIdentifiers)
        let requestedIDs = Set(attempt.items.map(\.assetID))
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(requestedIDs), options: nil)
        var assetsByID: [String: PHAsset] = [:]
        for index in 0..<fetch.count {
            let asset = fetch.object(at: index)
            assetsByID[asset.localIdentifier] = asset
        }

        var outcomes: [String: CommitItemOutcome] = [:]
        var assetsToAdd: [DestinationRole: [PHAsset]] = [:]
        let roleIDs = before
        for intent in attempt.items {
            let memberships = Set(roleIDs.compactMap { role, ids in ids.contains(intent.assetID) ? role : nil })
            let outcome = PhotoCommitReconciliation.outcome(
                for: intent.decision,
                memberships: memberships,
                assetAvailable: assetsByID[intent.assetID] != nil
            )
            switch outcome {
            case .retryable:
                if let asset = assetsByID[intent.assetID] {
                    assetsToAdd[PhotoCommitReconciliation.destination(for: intent.decision), default: []].append(asset)
                }
            default:
                outcomes[intent.assetID] = outcome
            }
        }

        let changedRoles = assetsToAdd.keys.filter { !(assetsToAdd[$0] ?? []).isEmpty }
        guard !changedRoles.isEmpty else { return outcomes }

        do {
            try await performPhotoChanges {
                for role in changedRoles {
                    guard let album = albums[role],
                          let request = PHAssetCollectionChangeRequest(for: album) else { continue }
                    request.addAssets((assetsToAdd[role] ?? []) as NSArray)
                }
            }
        } catch {
            // PhotoKit may complete close to a process interruption or return an
            // error after membership has changed elsewhere. Re-read all bound
            // albums before deciding whether any journaled intent remains pending.
        }

        let after = try destinationMemberships(albumLocalIdentifiers: albumLocalIdentifiers)
        for intent in attempt.items {
            let memberships = Set(after.compactMap { role, ids in ids.contains(intent.assetID) ? role : nil })
            outcomes[intent.assetID] = PhotoCommitReconciliation.outcome(
                for: intent.decision,
                memberships: memberships,
                assetAvailable: assetsByID[intent.assetID] != nil
            )
        }
        return outcomes
    }

    func createDestinationAlbum(named title: String) async throws -> PHAssetCollection {
        guard destinationAlbumCandidates().allSatisfy({ $0.localizedTitle?.compare(title, options: .caseInsensitive) != .orderedSame }) else {
            throw ServiceError.ambiguousDestinationAlbum
        }
        try await performPhotoChanges {
            PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
        }
        let matches = destinationAlbumCandidates().filter {
            $0.localizedTitle?.compare(title, options: .caseInsensitive) == .orderedSame
        }
        guard matches.count == 1, let album = matches.first else {
            throw ServiceError.albumFetchFailed
        }
        return album
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
                    dateToExclusive: settings.dateTo,
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
                        dateToExclusive: settings.dateTo,
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
                    dateToExclusive: settings.dateTo,
                    includeVideos: settings.includeVideos
                )
                return assets
            }
        }
    }

    func fetchReviewItems(settings: ScanSettings) throws -> ([ReviewItem], [String: PHAsset]) {
        let assets = try fetchAssets(settings: settings)
        return makeReviewItems(from: assets)
    }

    func makeReviewItems(from assets: [PHAsset]) -> ([ReviewItem], [String: PHAsset]) {
        var lookup: [String: PHAsset] = [:]
        let items = assets.map { asset -> ReviewItem in
            lookup[asset.localIdentifier] = asset
            return ReviewItem(
                id: asset.localIdentifier,
                source: .photoAsset(localIdentifier: asset.localIdentifier),
                displayName: displayName(for: asset),
                mediaKind: asset.mediaType == .video ? .video : .image,
                primaryDate: asset.creationDate,
                fallbackDate: asset.modificationDate,
                byteSize: estimatedByteSize(for: asset) ?? 0,
                badgeLabels: badges(for: asset),
                detailLabel: nil
            )
        }
        return (items, lookup)
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
                    dateToExclusive: settings.dateTo,
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
                        dateToExclusive: settings.dateTo,
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
                    dateToExclusive: settings.dateTo,
                    includeVideos: settings.includeVideos
                ).count
            }
        }
    }

    @MainActor
    func requestThumbnail(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat
    ) async -> NSImage? {
        let cancellationState = PhotoRequestCancellationState()
        let imageBox = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<ImageBox, Never>) in
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
                    continuation.resume(returning: ImageBox(image: image))
                }

                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    if cancelled || cancellationState.isCancelled {
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

                if !cancellationState.setRequestID(requestID) {
                    imageManager.cancelImageRequest(requestID)
                    resumeOnce(nil)
                }
            }
        }, onCancel: {
            cancellationState.cancel(using: imageManager)
        })

        return imageBox.image
    }

    @MainActor
    func requestInspectionImage(
        for asset: PHAsset,
        targetSize: CGSize,
        maximumSize: Bool,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> NSImage {
        let state = InspectionRequestState<ImageBox>()
        return try await withTaskCancellationHandler {
            let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ImageBox, Error>) in
                guard state.installResume({ continuation.resume(with: $0) }) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = maximumSize ? .fast : .exact
                options.version = .current
                options.isNetworkAccessAllowed = true
                options.isSynchronous = false
                options.progressHandler = { fraction, _, _, _ in
                    guard let progress else { return }
                    Task { @MainActor in progress(fraction) }
                }
                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: maximumSize ? PHImageManagerMaximumSize : targetSize,
                    contentMode: maximumSize ? .default : .aspectFit,
                    options: options
                ) { image, info in
                    if state.isCancelled || (info?[PHImageCancelledKey] as? Bool) == true {
                        state.finish(.failure(CancellationError()))
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        state.finish(.failure(error))
                    } else if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        return
                    } else if let image {
                        state.finish(.success(ImageBox(image: image)))
                    } else {
                        state.finish(.failure(ServiceError.assetNotFound))
                    }
                }
                if !state.setRequestID(requestID) {
                    imageManager.cancelImageRequest(requestID)
                }
            }
            guard let image = box.image else { throw ServiceError.assetNotFound }
            return image
        } onCancel: {
            state.cancel(using: imageManager)
        }
    }

    @MainActor
    func requestInspectionLivePhoto(
        for asset: PHAsset,
        targetSize: CGSize,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> PHLivePhoto {
        guard asset.mediaSubtypes.contains(.photoLive) else {
            throw ServiceError.assetNotFound
        }
        let state = InspectionRequestState<LivePhotoBox>()
        return try await withTaskCancellationHandler {
            let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LivePhotoBox, Error>) in
                guard state.installResume({ continuation.resume(with: $0) }) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let options = PHLivePhotoRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                options.progressHandler = { fraction, _, _, _ in
                    guard let progress else { return }
                    Task { @MainActor in progress(fraction) }
                }
                let requestID = imageManager.requestLivePhoto(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { livePhoto, info in
                    if state.isCancelled || (info?[PHImageCancelledKey] as? Bool) == true {
                        state.finish(.failure(CancellationError()))
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        state.finish(.failure(error))
                    } else if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        return
                    } else if let livePhoto {
                        state.finish(.success(LivePhotoBox(livePhoto: livePhoto)))
                    } else {
                        state.finish(.failure(ServiceError.assetNotFound))
                    }
                }
                if !state.setRequestID(requestID) {
                    imageManager.cancelImageRequest(requestID)
                }
            }
            guard let livePhoto = box.livePhoto else { throw ServiceError.assetNotFound }
            return livePhoto
        } onCancel: {
            state.cancel(using: imageManager)
        }
    }

    @MainActor
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

        let cancellationState = PhotoRequestCancellationState()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
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

                let requestID = imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    if cancelled || cancellationState.isCancelled {
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

                if !cancellationState.setRequestID(requestID) {
                    imageManager.cancelImageRequest(requestID)
                    resumeOnce(nil)
                }
            }
        }, onCancel: {
            cancellationState.cancel(using: imageManager)
        })
    }

    func requestPlayerItem(
        for asset: PHAsset,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async -> PlayerItemRequestResult {
        guard asset.mediaType == .video else {
            return .unavailable("The selected item is not a video.")
        }

        let cancellationState = PhotoRequestCancellationState()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let options = PHVideoRequestOptions()
                options.deliveryMode = .automatic
                options.version = .current
                options.isNetworkAccessAllowed = true
                options.progressHandler = { fraction, _, _, _ in
                    guard let progress else { return }
                    Task { @MainActor in progress(fraction) }
                }

                let resumeLock = NSLock()
                var didResume = false
                func resumeOnce(_ result: PlayerItemRequestResult) {
                    resumeLock.lock()
                    guard !didResume else {
                        resumeLock.unlock()
                        return
                    }
                    didResume = true
                    resumeLock.unlock()
                    continuation.resume(returning: result)
                }

                let requestID = imageManager.requestPlayerItem(forVideo: asset, options: options) { playerItem, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    if cancelled || cancellationState.isCancelled {
                        resumeOnce(.unavailable("Video preview loading was cancelled."))
                        return
                    }

                    if let error = info?[PHImageErrorKey] as? Error {
                        resumeOnce(.unavailable(error.localizedDescription))
                        return
                    }

                    if let playerItem {
                        resumeOnce(.success(PlayerItemBox(item: playerItem)))
                    } else {
                        resumeOnce(.unavailable("The video preview could not be loaded from Photos."))
                    }
                }

                if !cancellationState.setRequestID(requestID) {
                    imageManager.cancelImageRequest(requestID)
                    resumeOnce(.unavailable("Video preview loading was cancelled."))
                }
            }
        }, onCancel: {
            cancellationState.cancel(using: imageManager)
        })
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
        dateToExclusive: Date?,
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

        if let dateToExclusive {
            predicates.append(NSPredicate(format: "creationDate < %@", dateToExclusive as NSDate))
        }

        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    private func displayName(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let primary = resources.first?.originalFilename, !primary.isEmpty {
            return primary
        }

        return asset.mediaType == .video ? "Video" : "Photo"
    }

    private func badges(for asset: PHAsset) -> [String] {
        var badges: [String] = []
        let subtypes = asset.mediaSubtypes

        switch asset.mediaType {
        case .video:
            badges.append("VIDEO")
            if subtypes.contains(.videoHighFrameRate) { badges.append("SLO-MO") }
            if subtypes.contains(.videoTimelapse) { badges.append("TIMELAPSE") }
            if subtypes.contains(.videoCinematic) { badges.append("CINEMATIC") }
            if subtypes.contains(Self.videoScreenRecordingSubtype) { badges.append("SCREEN REC") }
        case .image:
            if subtypes.contains(.photoPanorama) { badges.append("PANO") }
            if subtypes.contains(.photoHDR) { badges.append("HDR") }
            if subtypes.contains(.photoLive) { badges.append("LIVE") }
            if subtypes.contains(.photoScreenshot) { badges.append("SHOT") }
            if subtypes.contains(.photoDepthEffect) { badges.append("DEPTH") }
            if subtypes.contains(.spatialMedia) { badges.append("SPATIAL") }
            if badges.isEmpty { badges.append("PHOTO") }
        default:
            badges.append("MEDIA")
        }

        return Array(badges.prefix(4))
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
        dateToExclusive: Date?,
        includeVideos: Bool
    ) -> [PHAsset] {
        var assetsByID: [String: PHAsset] = [:]
        collectAssets(
            in: collectionList,
            dateFrom: dateFrom,
            dateToExclusive: dateToExclusive,
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
        dateToExclusive: Date?,
        includeVideos: Bool,
        into assetsByID: inout [String: PHAsset]
    ) {
        if let assetCollection = collection as? PHAssetCollection {
            let assets = PHAsset.fetchAssets(
                in: assetCollection,
                options: assetFetchOptions(
                    dateFrom: dateFrom,
                    dateToExclusive: dateToExclusive,
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
                dateToExclusive: dateToExclusive,
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

    private func fetchAlbum(localIdentifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private func resolveDestinationCollections(
        _ identifiers: [DestinationRole: String]
    ) throws -> [DestinationRole: PHAssetCollection] {
        guard Set(identifiers.values).count == DestinationRole.allCases.count else {
            throw ServiceError.ambiguousDestinationAlbum
        }
        var result: [DestinationRole: PHAssetCollection] = [:]
        for role in DestinationRole.allCases {
            guard let identifier = identifiers[role], let album = fetchAlbum(localIdentifier: identifier) else {
                throw ServiceError.missingDestinationAlbum
            }
            result[role] = album
        }
        return result
    }

    private func performPhotoChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
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
