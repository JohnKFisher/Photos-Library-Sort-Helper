import AppKit
import AVFoundation
import Foundation
import Photos

@MainActor
final class ReviewViewModel: ObservableObject {
    private struct StoredBestShotLearning: Codable {
        var sampleCount: Int
        var weights: BestShotFeatureWeights
    }

    @Published var authorizationStatus: PHAuthorizationStatus
    @Published var albums: [AlbumOption] = []

    @Published var sourceMode: PhotoSourceMode = .allPhotos
    @Published var selectedAlbumID: String?

    @Published var useDateRange = false
    @Published var rangeStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var rangeEndDate = Date()
    @Published var includeVideos = false
    @Published var autoPickBestShot = true
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
    @Published private(set) var learnedBestShotSampleCount = 0

    private let libraryService = PhotoLibraryService()
    private lazy var scanner = SimilarityScanner(libraryService: libraryService)

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailKeysByAssetID: [String: Set<String>] = [:]
    private var videoAssetCache: [String: AVAsset] = [:]
    private var mediaBadgesCache: [String: [String]] = [:]
    private var suggestedBestAssetByGroup: [UUID: String] = [:]
    private var suggestedDiscardAssetIDsByGroup: [UUID: Set<String>] = [:]
    private var bestShotScoresByAssetID: [String: BestShotScoreBreakdown] = [:]
    private var reviewedGroupIDs: Set<UUID> = []
    private var manuallyEditedGroupIDs: Set<UUID> = []
    private var assetLookup: [String: PHAsset] = [:]
    private var scanTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var ignoreHoverUntilMouseMoves = false
    private var mouseLocationAtKeyboardNavigation: CGPoint = .zero
    private var learnedBestShotWeights: BestShotFeatureWeights = .baseline
    private let learnedBestShotDefaultsKey = "PhotoSortHelper.learnedBestShot.v1"

    init() {
        authorizationStatus = libraryService.currentAuthorizationStatus()
        loadStoredBestShotLearning()
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
            autoPickBestShot: autoPickBestShot,
            maxTimeGapSeconds: maxTimeGapSeconds,
            similarityDistanceThreshold: Float(similarityDistanceThreshold),
            maxAssetsToScan: maxAssetsToScan,
            bestShotPersonalization: currentBestShotPersonalization,
            useDeepPassTieBreaker: true,
            deepPassCloseCallDelta: 0.045,
            deepPassBlendWeight: 0.10
        )

        errorMessage = nil
        deletionMessage = nil
        deletionArmed = false
        groups = []
        keepSelectionsByGroup = [:]
        highlightedAssetByGroup = [:]
        suggestedBestAssetByGroup = [:]
        suggestedDiscardAssetIDsByGroup = [:]
        bestShotScoresByAssetID = [:]
        reviewedGroupIDs = []
        manuallyEditedGroupIDs = []
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

            var finishedSuccessfully = false
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
                self.suggestedBestAssetByGroup = result.bestAssetByGroupID
                self.suggestedDiscardAssetIDsByGroup = result.suggestedDiscardAssetIDsByGroupID
                self.bestShotScoresByAssetID = result.bestShotScoresByAssetID
                self.currentGroupIndex = 0
                self.initializeDefaultSelections()
                self.schedulePrefetchAndCacheMaintenance()
                finishedSuccessfully = true

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
            if finishedSuccessfully {
                self.scanProgress = max(self.scanProgress, 1.0)
            } else {
                self.scanProgress = min(self.scanProgress, 0.99)
            }
            self.scanTask = nil
        }
    }

    func stopScan() {
        guard isScanning else {
            return
        }

        scanStatusMessage = "Stopping scan..."
        scanTask?.cancel()
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
        updateLearnedBestShotModelIfNeeded(for: group)
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

    func isSuggestedBest(assetID: String, in group: ReviewGroup) -> Bool {
        suggestedBestAssetByGroup[group.id] == assetID
    }

    func isSuggestedDiscard(assetID: String, in group: ReviewGroup) -> Bool {
        suggestedDiscardAssetIDsByGroup[group.id]?.contains(assetID) == true
    }

    func bestShotExplanation(for assetID: String, in group: ReviewGroup) -> String {
        if let score = bestShotScoresByAssetID[assetID] {
            let total = Int((score.totalScore * 100).rounded())
            let focus = Int((score.sharpness * 100).rounded())
            let light = Int((score.lighting * 100).rounded())
            let framing = Int((score.framing * 100).rounded())
            let eyes = Int((score.eyesOpen * 100).rounded())
            let smile = Int((score.smile * 100).rounded())
            let face = Int((score.facePresence * 100).rounded())
            let subject = Int((score.subjectProminence * 100).rounded())
            let centering = Int((score.subjectCentering * 100).rounded())
            let color = Int((score.color * 100).rounded())
            let contrast = Int((score.contrast * 100).rounded())
            let base = Int((score.baseHeuristicScore * 100).rounded())
            let learned = Int((score.learnedPreferenceScore * 100).rounded())
            let adjustment = Int((score.learnedAdjustment * 100).rounded())
            let learnedAdjustmentText = adjustment == 0
                ? "Learned ±0"
                : "Learned \(adjustment > 0 ? "+" : "")\(adjustment)"
            let deepText: String = {
                guard score.usedDeepPass, let aesthetics = score.aestheticsScore else {
                    return ""
                }
                let value = Int((aesthetics * 100).rounded())
                return " • Deep \(value)"
            }()
            let status: String = {
                if isSuggestedDiscard(assetID: assetID, in: group) {
                    return "Suggested discard in this group (singleton quality warning)."
                }
                if isSuggestedBest(assetID: assetID, in: group) {
                    return "Suggested best in this group."
                }
                return "Scored for comparison (not top pick)."
            }()

            return "\(status)\nTotal \(total) • Base \(base) • LearnedScore \(learned) • \(learnedAdjustmentText)\(deepText) • Focus \(focus) • Light \(light) • Framing \(framing) • Eyes \(eyes) • Smile \(smile) • Faces \(face) • Subject \(subject) • Centering \(centering) • Color \(color) • Contrast \(contrast)"
        }

        if isVideo(assetID: assetID) {
            return "Video clip: auto-pick quality scoring is skipped (manual choice only)."
        }

        return "No quality score available for this item."
    }

    func markGroupReviewed(_ group: ReviewGroup) {
        let inserted = reviewedGroupIDs.insert(group.id).inserted
        guard inserted else {
            return
        }

        guard autoPickBestShot else {
            return
        }

        applyBestShotSuggestion(for: group)
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

        beginKeyboardNavigationSession()
        moveHighlight(in: group, delta: -1)
    }

    func highlightNextAssetInCurrentGroup() {
        guard let group = currentGroup else {
            return
        }

        beginKeyboardNavigationSession()
        moveHighlight(in: group, delta: 1)
    }

    func shouldAcceptHoverHighlight() -> Bool {
        guard ignoreHoverUntilMouseMoves else {
            return true
        }

        let currentMouseLocation = NSEvent.mouseLocation
        let dx = currentMouseLocation.x - mouseLocationAtKeyboardNavigation.x
        let dy = currentMouseLocation.y - mouseLocationAtKeyboardNavigation.y
        let distanceSquared = (dx * dx) + (dy * dy)

        // Require real movement before hover can override keyboard navigation.
        guard distanceSquared > 4.0 else {
            return false
        }

        ignoreHoverUntilMouseMoves = false
        mouseLocationAtKeyboardNavigation = currentMouseLocation
        return true
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
        updateLearnedBestShotModelIfNeeded(for: group)
    }

    func keepAll(in group: ReviewGroup) {
        keepSelectionsByGroup[group.id] = Set(group.assetIDs)
        updateLearnedBestShotModelIfNeeded(for: group)
    }

    func discardAll(in group: ReviewGroup) {
        keepSelectionsByGroup[group.id] = []
        updateLearnedBestShotModelIfNeeded(for: group)
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
            guard reviewedGroupIDs.contains(group.id) else {
                continue
            }

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
                self.suggestedBestAssetByGroup = [:]
                self.suggestedDiscardAssetIDsByGroup = [:]
                self.bestShotScoresByAssetID = [:]
                self.reviewedGroupIDs = []
                self.manuallyEditedGroupIDs = []
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

    private func applyBestShotSuggestion(for group: ReviewGroup) {
        if let discardSuggestions = suggestedDiscardAssetIDsByGroup[group.id], !discardSuggestions.isEmpty {
            let kept = Set(group.assetIDs).subtracting(discardSuggestions)
            keepSelectionsByGroup[group.id] = kept
            return
        }

        guard let suggestedID = suggestedBestAssetByGroup[group.id],
              group.assetIDs.contains(suggestedID) else {
            return
        }

        // Keep/discard suggestion is applied, but keep keyboard/preview focus at the top item.
        keepSelectionsByGroup[group.id] = [suggestedID]
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

    private func beginKeyboardNavigationSession() {
        ignoreHoverUntilMouseMoves = true
        mouseLocationAtKeyboardNavigation = NSEvent.mouseLocation
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

    private var currentBestShotPersonalization: BestShotPersonalization? {
        guard learnedBestShotSampleCount > 0 else {
            return nil
        }

        let confidence = min(1.0, Double(learnedBestShotSampleCount) / 80.0)
        return BestShotPersonalization(weights: learnedBestShotWeights, confidence: confidence)
    }

    private func updateLearnedBestShotModelIfNeeded(for group: ReviewGroup) {
        guard reviewedGroupIDs.contains(group.id) else {
            return
        }

        manuallyEditedGroupIDs.insert(group.id)
        recomputeLearnedBestShotModel()
    }

    private func recomputeLearnedBestShotModel() {
        var deltaSums: [BestShotFeature: Double] = [:]
        BestShotFeature.allCases.forEach { deltaSums[$0] = 0.0 }
        var sampleCount = 0

        for group in groups where manuallyEditedGroupIDs.contains(group.id) {
            guard let contribution = learningContribution(for: group) else {
                continue
            }

            for feature in BestShotFeature.allCases {
                deltaSums[feature, default: 0.0] += contribution[feature, default: 0.0]
            }
            sampleCount += 1
        }

        guard sampleCount > 0 else {
            learnedBestShotWeights = .baseline
            learnedBestShotSampleCount = 0
            persistStoredBestShotLearning()
            return
        }

        let confidence = min(1.0, Double(sampleCount) / 80.0)
        let maxShift = 0.55 * confidence
        var weights = BestShotFeatureWeights.baseline

        for feature in BestShotFeature.allCases {
            let baseWeight = BestShotFeatureWeights.baseline.value(for: feature)
            let averageDelta = deltaSums[feature, default: 0.0] / Double(sampleCount)
            let boundedDelta = min(1.0, max(-1.0, averageDelta))
            let scale = 1.0 + (maxShift * boundedDelta)
            let adjustedWeight = baseWeight * max(0.35, scale)
            weights = weights.withValue(adjustedWeight, for: feature)
        }

        learnedBestShotWeights = weights.clamped().normalized()
        learnedBestShotSampleCount = sampleCount
        persistStoredBestShotLearning()
    }

    private func learningContribution(for group: ReviewGroup) -> [BestShotFeature: Double]? {
        let scoredImageIDs = group.assetIDs.filter { assetID in
            guard assetLookup[assetID]?.mediaType == .image else {
                return false
            }
            return bestShotScoresByAssetID[assetID] != nil
        }

        guard scoredImageIDs.count >= 2 else {
            return nil
        }

        let keptSet = keepSelections(for: group)
        let keptImageIDs = scoredImageIDs.filter { keptSet.contains($0) }
        let discardedImageIDs = scoredImageIDs.filter { !keptSet.contains($0) }

        guard !keptImageIDs.isEmpty, !discardedImageIDs.isEmpty else {
            return nil
        }

        guard
            let keptMean = meanFeatureVector(for: keptImageIDs),
            let discardedMean = meanFeatureVector(for: discardedImageIDs)
        else {
            return nil
        }

        var delta: [BestShotFeature: Double] = [:]
        for feature in BestShotFeature.allCases {
            delta[feature] = keptMean[feature, default: 0.0] - discardedMean[feature, default: 0.0]
        }
        return delta
    }

    private func meanFeatureVector(for assetIDs: [String]) -> [BestShotFeature: Double]? {
        guard !assetIDs.isEmpty else {
            return nil
        }

        var sums: [BestShotFeature: Double] = [:]
        BestShotFeature.allCases.forEach { sums[$0] = 0.0 }
        var count = 0

        for assetID in assetIDs {
            guard let score = bestShotScoresByAssetID[assetID] else {
                continue
            }

            for feature in BestShotFeature.allCases {
                sums[feature, default: 0.0] += featureValue(feature, from: score)
            }
            count += 1
        }

        guard count > 0 else {
            return nil
        }

        var means: [BestShotFeature: Double] = [:]
        for feature in BestShotFeature.allCases {
            means[feature] = sums[feature, default: 0.0] / Double(count)
        }

        return means
    }

    private func featureValue(_ feature: BestShotFeature, from score: BestShotScoreBreakdown) -> Double {
        switch feature {
        case .facePresence: return score.facePresence
        case .framing: return score.framing
        case .eyesOpen: return score.eyesOpen
        case .smile: return score.smile
        case .subjectProminence: return score.subjectProminence
        case .subjectCentering: return score.subjectCentering
        case .sharpness: return score.sharpness
        case .lighting: return score.lighting
        case .color: return score.color
        case .contrast: return score.contrast
        }
    }

    private func loadStoredBestShotLearning() {
        guard let data = UserDefaults.standard.data(forKey: learnedBestShotDefaultsKey) else {
            learnedBestShotWeights = .baseline
            learnedBestShotSampleCount = 0
            return
        }

        guard let stored = try? JSONDecoder().decode(StoredBestShotLearning.self, from: data) else {
            learnedBestShotWeights = .baseline
            learnedBestShotSampleCount = 0
            return
        }

        learnedBestShotWeights = stored.weights.clamped().normalized()
        learnedBestShotSampleCount = max(0, stored.sampleCount)
    }

    private func persistStoredBestShotLearning() {
        let stored = StoredBestShotLearning(
            sampleCount: learnedBestShotSampleCount,
            weights: learnedBestShotWeights
        )

        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: learnedBestShotDefaultsKey)
        }
    }
}
