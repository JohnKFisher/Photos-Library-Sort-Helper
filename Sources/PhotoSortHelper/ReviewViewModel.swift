import AppKit
import AVFoundation
import Foundation
import Photos

@MainActor
final class ReviewViewModel: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus
    @Published var albums: [AlbumOption] = []

    @Published var sourceMode: PhotoSourceMode = .allPhotos
    @Published var selectedAlbumID: String?

    @Published var useDateRange = false
    @Published var rangeStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var rangeEndDate = Date()
    @Published var includeVideos = false
    @Published var autoplayPreviewVideos = false

    @Published var maxTimeGapSeconds: Double = 8
    @Published var similarityDistanceThreshold: Double = 12.0
    @Published var maxAssetsToScan: Int = 4_000

    @Published var isScanning = false
    @Published var scanProgress: Double = 0
    @Published var scanStatusMessage = "Ready to scan"

    @Published var scannedAssetCount = 0
    @Published var temporalClusterCount = 0

    @Published var groups: [ReviewGroup] = []
    @Published var currentGroupIndex = 0
    @Published var keepSelectionsByGroup: [UUID: Set<String>] = [:]
    @Published var highlightedAssetByGroup: [UUID: String] = [:]

    @Published var showDeleteConfirmation = false
    @Published var isDeleting = false
    @Published var deletionArmed = false

    @Published var deletionMessage: String?
    @Published var errorMessage: String?

    private let libraryService = PhotoLibraryService()
    private lazy var scanner = SimilarityScanner(libraryService: libraryService)

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailKeysByAssetID: [String: Set<String>] = [:]
    private var videoAssetCache: [String: AVAsset] = [:]
    private var mediaBadgesCache: [String: [String]] = [:]
    private var assetLookup: [String: PHAsset] = [:]
    private var scanTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?

    init() {
        authorizationStatus = libraryService.currentAuthorizationStatus()
    }

    deinit {
        scanTask?.cancel()
        prefetchTask?.cancel()
    }

    func bootstrap() async {
        if authorizationStatus == .notDetermined {
            authorizationStatus = await libraryService.requestAuthorization()
        }

        if isAuthorized {
            await refreshAlbums()
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    func requestPhotoAccess() async {
        authorizationStatus = await libraryService.requestAuthorization()
        if isAuthorized {
            await refreshAlbums()
        }
    }

    func refreshAlbums() async {
        albums = libraryService.fetchAlbums()
        if sourceMode == .album {
            if selectedAlbumID == nil || albums.contains(where: { $0.id == selectedAlbumID }) == false {
                selectedAlbumID = albums.first?.id
            }
        }
    }

    func scan() {
        guard !isScanning else {
            return
        }

        guard isAuthorized else {
            errorMessage = ReviewError.photoAccessDenied.localizedDescription
            return
        }

        let (dateFrom, dateTo): (Date?, Date?) = {
            guard useDateRange else { return (nil, nil) }

            let startOfFrom = Calendar.current.startOfDay(for: rangeStartDate)
            let startOfTo = Calendar.current.startOfDay(for: rangeEndDate)
            let endOfTo = Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: startOfTo) ?? startOfTo

            if startOfFrom <= endOfTo {
                return (startOfFrom, endOfTo)
            } else {
                return (endOfTo, startOfFrom)
            }
        }()

        let settings = ScanSettings(
            sourceMode: sourceMode,
            selectedAlbumID: selectedAlbumID,
            dateFrom: dateFrom,
            dateTo: dateTo,
            includeVideos: includeVideos,
            maxTimeGapSeconds: maxTimeGapSeconds,
            similarityDistanceThreshold: Float(similarityDistanceThreshold),
            maxAssetsToScan: maxAssetsToScan
        )

        errorMessage = nil
        deletionMessage = nil
        deletionArmed = false
        groups = []
        keepSelectionsByGroup = [:]
        highlightedAssetByGroup = [:]
        currentGroupIndex = 0
        assetLookup = [:]
        mediaBadgesCache = [:]
        thumbnailKeysByAssetID = [:]
        videoAssetCache = [:]
        prefetchTask?.cancel()
        prefetchTask = nil

        thumbnailCache.removeAllObjects()

        isScanning = true
        scanProgress = 0
        scanStatusMessage = "Starting scan..."

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let result = try await self.scanner.scan(settings: settings) { [weak self] progress in
                    guard let self else { return }
                    self.scanProgress = progress.fractionCompleted
                    self.scanStatusMessage = progress.message
                }

                self.scannedAssetCount = result.scannedAssetCount
                self.temporalClusterCount = result.temporalClusterCount
                self.assetLookup = result.assetLookup
                self.groups = result.groups
                self.currentGroupIndex = 0
                self.initializeDefaultSelections()
                self.schedulePrefetchAndCacheMaintenance()

                if result.groups.isEmpty {
                    self.scanStatusMessage = "No similar groups found with current settings."
                }
            } catch is CancellationError {
                self.scanStatusMessage = "Scan cancelled."
            } catch {
                self.errorMessage = error.localizedDescription
                self.scanStatusMessage = "Scan failed."
            }

            self.isScanning = false
            self.scanProgress = max(self.scanProgress, 1.0)
        }
    }

    var currentGroup: ReviewGroup? {
        guard groups.indices.contains(currentGroupIndex) else {
            return nil
        }

        return groups[currentGroupIndex]
    }

    func previousGroup() {
        guard currentGroupIndex > 0 else {
            return
        }

        currentGroupIndex -= 1
        schedulePrefetchAndCacheMaintenance()
    }

    func nextGroup() {
        guard currentGroupIndex < groups.count - 1 else {
            return
        }

        currentGroupIndex += 1
        schedulePrefetchAndCacheMaintenance()
    }

    var hasPreviousGroup: Bool {
        currentGroupIndex > 0
    }

    var hasNextGroup: Bool {
        currentGroupIndex < groups.count - 1
    }

    var hasHighlightInCurrentGroup: Bool {
        guard let group = currentGroup else {
            return false
        }

        return highlightedAssetID(in: group) != nil
    }

    func isKept(assetID: String, in group: ReviewGroup) -> Bool {
        keepSelections(for: group).contains(assetID)
    }

    func toggleKeep(assetID: String, in group: ReviewGroup) {
        var selection = keepSelections(for: group)

        if selection.contains(assetID) {
            selection.remove(assetID)
        } else {
            selection.insert(assetID)
        }

        keepSelectionsByGroup[group.id] = selection
    }

    func highlightedAssetID(in group: ReviewGroup) -> String? {
        guard !group.assetIDs.isEmpty else {
            return nil
        }

        if let highlighted = highlightedAssetByGroup[group.id], group.assetIDs.contains(highlighted) {
            return highlighted
        }

        return group.assetIDs.first
    }

    func isHighlighted(assetID: String, in group: ReviewGroup) -> Bool {
        highlightedAssetID(in: group) == assetID
    }

    func ensureHighlightedAsset(in group: ReviewGroup) {
        guard let highlighted = highlightedAssetID(in: group) else {
            highlightedAssetByGroup.removeValue(forKey: group.id)
            return
        }

        if highlightedAssetByGroup[group.id] != highlighted {
            highlightedAssetByGroup[group.id] = highlighted
        }
    }

    func setHighlighted(assetID: String, in group: ReviewGroup) {
        guard group.assetIDs.contains(assetID) else {
            return
        }

        if highlightedAssetByGroup[group.id] != assetID {
            highlightedAssetByGroup[group.id] = assetID
        }
    }

    func highlightPreviousAssetInCurrentGroup() {
        guard let group = currentGroup else {
            return
        }

        moveHighlight(in: group, delta: -1)
    }

    func highlightNextAssetInCurrentGroup() {
        guard let group = currentGroup else {
            return
        }

        moveHighlight(in: group, delta: 1)
    }

    func toggleHighlightedAssetInCurrentGroup() {
        guard let group = currentGroup else {
            return
        }

        ensureHighlightedAsset(in: group)
        guard let highlighted = highlightedAssetID(in: group) else {
            return
        }

        toggleKeep(assetID: highlighted, in: group)
    }

    func keepOnly(assetID: String, in group: ReviewGroup) {
        keepSelectionsByGroup[group.id] = [assetID]
    }

    func keepAll(in group: ReviewGroup) {
        keepSelectionsByGroup[group.id] = Set(group.assetIDs)
    }

    func discardAll(in group: ReviewGroup) {
        keepSelectionsByGroup[group.id] = []
    }

    func keptCount(in group: ReviewGroup) -> Int {
        keepSelections(for: group).count
    }

    func discardCount(in group: ReviewGroup) -> Int {
        max(0, group.assetIDs.count - keptCount(in: group))
    }

    var discardAssetIDs: [String] {
        var ids: Set<String> = []

        for group in groups {
            let kept = keepSelections(for: group)
            for assetID in group.assetIDs where !kept.contains(assetID) {
                ids.insert(assetID)
            }
        }

        return ids.sorted()
    }

    var discardCountTotal: Int {
        discardAssetIDs.count
    }

    func thumbnail(
        for assetID: String,
        side: CGFloat = 320,
        contentMode: PHImageContentMode = .aspectFill,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat
    ) async -> NSImage? {
        let modeSuffix = contentMode == .aspectFit ? "fit" : "fill"
        let deliverySuffix: String = {
            switch deliveryMode {
            case .fastFormat: return "fast"
            case .opportunistic: return "op"
            default: return "hq"
            }
        }()
        let cacheKey = NSString(string: "\(assetID)-\(Int(side))-\(modeSuffix)-\(deliverySuffix)")
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard let asset = assetLookup[assetID] else {
            return nil
        }

        let thumbnail = await libraryService.requestThumbnail(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: contentMode,
            deliveryMode: deliveryMode
        )

        if let thumbnail {
            thumbnailCache.setObject(thumbnail, forKey: cacheKey)
            thumbnailKeysByAssetID[assetID, default: []].insert(cacheKey as String)
        }

        return thumbnail
    }

    func isVideo(assetID: String) -> Bool {
        assetLookup[assetID]?.mediaType == .video
    }

    func previewPlayer(for assetID: String) async -> AVPlayer? {
        guard isVideo(assetID: assetID) else {
            return nil
        }

        let avAsset: AVAsset
        if let cached = videoAssetCache[assetID] {
            avAsset = cached
        } else {
            guard let fetched = await ensureVideoAssetCached(for: assetID) else {
                return nil
            }
            avAsset = fetched
        }

        let item = AVPlayerItem(asset: avAsset)
        item.preferredForwardBufferDuration = 2

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        return player
    }

    func mediaBadges(for assetID: String) -> [String] {
        if let cached = mediaBadgesCache[assetID] {
            return cached
        }

        guard let asset = assetLookup[assetID] else {
            return []
        }

        var badges: [String] = []
        let subtypes = asset.mediaSubtypes

        switch asset.mediaType {
        case .video:
            badges.append("VIDEO")
            if subtypes.contains(.videoHighFrameRate) { badges.append("SLO-MO") }
            if subtypes.contains(.videoTimelapse) { badges.append("TIMELAPSE") }
            if subtypes.contains(.videoCinematic) { badges.append("CINEMATIC") }
            if subtypes.contains(.videoScreenRecording) { badges.append("SCREEN REC") }
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

        let trimmed = Array(badges.prefix(4))
        mediaBadgesCache[assetID] = trimmed
        return trimmed
    }

    func confirmDeleteMarkedAssets() {
        guard discardCountTotal > 0, deletionArmed else {
            return
        }

        showDeleteConfirmation = true
    }

    func deleteMarkedAssets() {
        let ids = discardAssetIDs
        guard !ids.isEmpty else {
            return
        }

        errorMessage = nil
        deletionMessage = nil
        isDeleting = true

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.libraryService.deleteAssets(withIdentifiers: ids)
                self.deletionMessage = "Moved \(ids.count) photos to Recently Deleted. You can recover them in Photos for about 30 days."

                self.groups = []
                self.keepSelectionsByGroup = [:]
                self.highlightedAssetByGroup = [:]
                self.assetLookup = [:]
                self.mediaBadgesCache = [:]
                self.thumbnailKeysByAssetID = [:]
                self.videoAssetCache = [:]
                self.currentGroupIndex = 0
                self.deletionArmed = false
                self.thumbnailCache.removeAllObjects()
                self.prefetchTask?.cancel()
                self.prefetchTask = nil
                self.scanStatusMessage = "Deletion complete. Run a new scan when ready."
            } catch {
                self.errorMessage = error.localizedDescription
            }

            self.isDeleting = false
        }
    }

    private func keepSelections(for group: ReviewGroup) -> Set<String> {
        if let selection = keepSelectionsByGroup[group.id] {
            return selection
        }

        let defaultSelection = Set(group.assetIDs)
        keepSelectionsByGroup[group.id] = defaultSelection
        return defaultSelection
    }

    private func initializeDefaultSelections() {
        for group in groups {
            keepSelectionsByGroup[group.id] = Set(group.assetIDs)
            highlightedAssetByGroup[group.id] = group.assetIDs.first
        }
    }

    private func moveHighlight(in group: ReviewGroup, delta: Int) {
        ensureHighlightedAsset(in: group)
        guard let highlighted = highlightedAssetID(in: group),
              let currentIndex = group.assetIDs.firstIndex(of: highlighted) else {
            return
        }

        let targetIndex = max(0, min(group.assetIDs.count - 1, currentIndex + delta))
        let targetAssetID = group.assetIDs[targetIndex]

        if highlightedAssetByGroup[group.id] != targetAssetID {
            highlightedAssetByGroup[group.id] = targetAssetID
        }
    }

    private func schedulePrefetchAndCacheMaintenance() {
        trimCachesForCurrentWindow()

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            await self.prefetchNextGroupAssets()
        }
    }

    private func trimCachesForCurrentWindow() {
        guard !groups.isEmpty else {
            thumbnailCache.removeAllObjects()
            thumbnailKeysByAssetID = [:]
            videoAssetCache = [:]
            mediaBadgesCache = [:]
            return
        }

        let lowerBound = max(0, currentGroupIndex - 10)
        let upperBound = min(groups.count - 1, currentGroupIndex + 2)

        var keepAssetIDs: Set<String> = []
        for index in lowerBound...upperBound {
            keepAssetIDs.formUnion(groups[index].assetIDs)
        }

        let removableAssetIDs = thumbnailKeysByAssetID.keys.filter { !keepAssetIDs.contains($0) }
        for assetID in removableAssetIDs {
            if let keySet = thumbnailKeysByAssetID[assetID] {
                for key in keySet {
                    thumbnailCache.removeObject(forKey: NSString(string: key))
                }
            }
            thumbnailKeysByAssetID.removeValue(forKey: assetID)
        }

        mediaBadgesCache = mediaBadgesCache.filter { keepAssetIDs.contains($0.key) }
        videoAssetCache = videoAssetCache.filter { keepAssetIDs.contains($0.key) }
    }

    private func prefetchNextGroupAssets() async {
        let nextIndex = currentGroupIndex + 1
        guard groups.indices.contains(nextIndex) else {
            return
        }

        let nextAssetIDs = Array(groups[nextIndex].assetIDs.prefix(12))
        guard !nextAssetIDs.isEmpty else {
            return
        }

        for assetID in nextAssetIDs {
            if Task.isCancelled { return }
            _ = await thumbnail(
                for: assetID,
                side: 320,
                contentMode: .aspectFill,
                deliveryMode: .opportunistic
            )

            if Task.isCancelled { return }
            _ = await thumbnail(
                for: assetID,
                side: 320,
                contentMode: .aspectFill,
                deliveryMode: .highQualityFormat
            )
        }

        if let firstID = nextAssetIDs.first {
            if Task.isCancelled { return }
            _ = await thumbnail(
                for: firstID,
                side: 900,
                contentMode: .aspectFit,
                deliveryMode: .opportunistic
            )

            if Task.isCancelled { return }
            _ = await thumbnail(
                for: firstID,
                side: 2_000,
                contentMode: .aspectFit,
                deliveryMode: .highQualityFormat
            )
        }

        if let firstVideoID = nextAssetIDs.first(where: { isVideo(assetID: $0) }) {
            if Task.isCancelled { return }
            _ = await ensureVideoAssetCached(for: firstVideoID)
        }
    }

    @discardableResult
    private func ensureVideoAssetCached(for assetID: String) async -> AVAsset? {
        if let cached = videoAssetCache[assetID] {
            return cached
        }

        guard let asset = assetLookup[assetID], asset.mediaType == .video else {
            return nil
        }

        guard let avAssetBox = await libraryService.requestAVAsset(for: asset) else {
            return nil
        }

        let avAsset = avAssetBox.asset
        videoAssetCache[assetID] = avAsset
        return avAsset
    }
}
