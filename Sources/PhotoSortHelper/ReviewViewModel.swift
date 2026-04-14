import AppKit
import AVFoundation
import Foundation
import Photos

@MainActor
final class ReviewViewModel: ObservableObject {
    enum VideoPreviewLoadResult {
        case ready(AVPlayer)
        case unavailable(String)
    }

    @Published var authorizationStatus: PHAuthorizationStatus
    @Published var albums: [AlbumOption] = []

    @Published var sourceMode: PhotoSourceMode = .allPhotos
    @Published var selectedAlbumID: String?

    @Published var useDateRange = false {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var rangeStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var rangeEndDate = Date() {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var includeVideos = false {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var autoplayPreviewVideos = false {
        didSet { scheduleStoredScanPreferencesSave() }
    }

    @Published var maxTimeGapSeconds: Double = 8 {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published private(set) var similarityDistanceThreshold: Double = 12.0
    @Published var maxAssetsToScan: Int = 4_000 {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var showLargeSelectionWarning = false
    @Published var estimatedScanScopeCount = 0

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
    @Published var editQueueMessage: String?
    @Published private(set) var isQueuingForEdit = false
    @Published private(set) var estimatedDiscardBytes: Int64 = 0
    @Published private(set) var isEstimatingDiscardBytes = false

    private let libraryService = PhotoLibraryService()
    private lazy var scanner = SimilarityScanner(libraryService: libraryService)

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailKeysByAssetID: [String: Set<String>] = [:]
    private var videoAssetCache: [String: AVAsset] = [:]
    private var mediaBadgesCache: [String: [String]] = [:]
    private var reviewedGroupIDs: Set<UUID> = []
    private var manuallyEditedGroupIDs: Set<UUID> = []
    private var assetLookup: [String: PHAsset] = [:]
    private var scanTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var ignoreHoverUntilMouseMoves = false
    private var mouseLocationAtKeyboardNavigation: CGPoint = .zero
    private var sessionSaveTask: Task<Void, Never>?
    private var scanPreferencesSaveTask: Task<Void, Never>?
    private var sizeEstimateTask: Task<Void, Never>?
    private var estimatedAssetSizeByID: [String: Int64] = [:]
    private var hasAttemptedSessionRestore = false
    private var editQueueMessageTask: Task<Void, Never>?
    private let editAlbumTitle = "Files to Edit"
    private let manualDeleteAlbumTitle = "Files to Manually Delete"
    private let fullySortedAlbumTitle = "Fully Sorted"
    private let fixedSimilarityDistanceThreshold: Double = 12.0
    private let recommendedScopeThreshold = 2_000
    private let currentBundleIdentifierFallback = "com.jkfisher.photoslibrarysorthelper"
    private let legacyBundleIdentifier = "com.jkfisher.photosorthelper"
    private lazy var scanPreferencesStore = ScanPreferencesStore(bundleIdentifier: currentBundleIdentifier)
    private var pendingScanSettings: ScanSettings?

    init() {
        authorizationStatus = libraryService.currentAuthorizationStatus()
        migrateLegacyPersistenceIfNeeded()
        loadStoredScanPreferences()
    }

    deinit {
        scanTask?.cancel()
        prefetchTask?.cancel()
        sessionSaveTask?.cancel()
        scanPreferencesSaveTask?.cancel()
        sizeEstimateTask?.cancel()
        editQueueMessageTask?.cancel()
    }

    func bootstrap() async {
        if isAuthorized {
            await refreshAlbums()
            await restoreReviewSessionIfAvailable()
        }
    }

    var isAuthorized: Bool {
        PhotoAuthorizationSupport.canAccessLibrary(authorizationStatus)
    }

    var canInitiateScan: Bool {
        authorizationStatus != .denied && authorizationStatus != .restricted
    }

    func requestPhotoAccess() async {
        guard authorizationStatus == .notDetermined else {
            errorMessage = PhotoAuthorizationSupport.scanActionMessage(for: authorizationStatus)
            return
        }

        authorizationStatus = await libraryService.requestAuthorization()
        if isAuthorized {
            await refreshAlbums()
            await restoreReviewSessionIfAvailable()
        } else {
            errorMessage = PhotoAuthorizationSupport.scanActionMessage(for: authorizationStatus)
        }
    }

    private func ensureAuthorizationForScan() async -> Bool {
        if isAuthorized {
            return true
        }

        if authorizationStatus == .notDetermined {
            authorizationStatus = await libraryService.requestAuthorization()
            if isAuthorized {
                await refreshAlbums()
                await restoreReviewSessionIfAvailable()
                return true
            }
        }

        errorMessage = PhotoAuthorizationSupport.scanActionMessage(for: authorizationStatus)
        return false
    }

    private func ensureAuthorizationForQueueing() async -> Bool {
        if isAuthorized {
            return true
        }

        if authorizationStatus == .notDetermined {
            authorizationStatus = await libraryService.requestAuthorization()
            if isAuthorized {
                await refreshAlbums()
                return true
            }
        }

        errorMessage = PhotoAuthorizationSupport.queueActionMessage(for: authorizationStatus)
        return false
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
        requestScan()
    }

    func requestScan() {
        guard !isScanning else {
            return
        }

        Task { [weak self] in
            guard let self else { return }

            let canScan = await self.ensureAuthorizationForScan()
            guard canScan else {
                return
            }

            self.errorMessage = nil
            self.showLargeSelectionWarning = false
            self.pendingScanSettings = nil

            let settings = self.buildScanSettings()

            do {
                let estimatedCount = try self.libraryService.estimateAssetCount(settings: settings)
                self.estimatedScanScopeCount = estimatedCount

                if estimatedCount > self.recommendedScopeThreshold {
                    self.pendingScanSettings = settings
                    self.showLargeSelectionWarning = true
                    return
                }
            } catch {
                self.errorMessage = error.localizedDescription
                return
            }

            self.startScan(with: settings)
        }
    }

    func continueScanAfterLargeScopeWarning() {
        guard !isScanning, let pendingScanSettings else {
            showLargeSelectionWarning = false
            return
        }

        showLargeSelectionWarning = false
        self.pendingScanSettings = nil
        startScan(with: pendingScanSettings)
    }

    private func buildScanSettings() -> ScanSettings {
        
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

        return ScanSettings(
            sourceMode: sourceMode,
            selectedAlbumID: selectedAlbumID,
            dateFrom: dateFrom,
            dateTo: dateTo,
            includeVideos: includeVideos,
            maxTimeGapSeconds: maxTimeGapSeconds,
            similarityDistanceThreshold: Float(fixedSimilarityDistanceThreshold)
        )
    }

    private func startScan(with settings: ScanSettings) {
        errorMessage = nil
        deletionMessage = nil
        deletionArmed = false
        showLargeSelectionWarning = false
        pendingScanSettings = nil
        editQueueMessageTask?.cancel()
        editQueueMessage = nil
        isQueuingForEdit = false
        estimatedDiscardBytes = 0
        isEstimatingDiscardBytes = false
        groups = []
        keepSelectionsByGroup = [:]
        highlightedAssetByGroup = [:]
        reviewedGroupIDs = []
        manuallyEditedGroupIDs = []
        currentGroupIndex = 0
        assetLookup = [:]
        mediaBadgesCache = [:]
        thumbnailKeysByAssetID = [:]
        videoAssetCache = [:]
        estimatedAssetSizeByID = [:]
        prefetchTask?.cancel()
        prefetchTask = nil
        sessionSaveTask?.cancel()
        sizeEstimateTask?.cancel()

        thumbnailCache.removeAllObjects()
        clearPersistedReviewSession()

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
                self.currentGroupIndex = 0
                self.initializeDefaultSelections()
                self.schedulePrefetchAndCacheMaintenance()
                self.scheduleEstimatedDiscardSizeRefresh()
                self.scheduleSessionSave()
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
        scheduleSessionSave()
    }

    func nextGroup() {
        guard currentGroupIndex < groups.count - 1 else {
            return
        }

        currentGroupIndex += 1
        schedulePrefetchAndCacheMaintenance()
        scheduleSessionSave()
    }

    var hasPreviousGroup: Bool {
        currentGroupIndex > 0
    }

    var hasNextGroup: Bool {
        currentGroupIndex < groups.count - 1
    }

    func isGroupReviewed(_ group: ReviewGroup) -> Bool {
        reviewedGroupIDs.contains(group.id)
    }

    var reviewedGroupCount: Int {
        reviewedGroupIDs.intersection(Set(groups.map(\.id))).count
    }

    var hasHighlightInCurrentGroup: Bool {
        guard let group = currentGroup else {
            return false
        }

        return highlightedAssetID(in: group) != nil
    }

    var estimatedDiscardSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: estimatedDiscardBytes, countStyle: .file)
    }

    var estimatedDiscardSummary: String {
        guard discardCountTotal > 0 else {
            return "Estimated reclaim: 0 bytes"
        }

        if isEstimatingDiscardBytes && estimatedDiscardBytes == 0 {
            return "Estimated reclaim: estimating..."
        }

        if estimatedDiscardBytes > 0 {
            let suffix = isEstimatingDiscardBytes ? " (updating...)" : ""
            return "Estimated reclaim: \(estimatedDiscardSizeLabel)\(suffix)"
        }

        return "Estimated reclaim: unavailable"
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
        manuallyEditedGroupIDs.insert(group.id)
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
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

    func markGroupReviewed(_ group: ReviewGroup) {
        let inserted = reviewedGroupIDs.insert(group.id).inserted
        if inserted {
            scheduleEstimatedDiscardSizeRefresh()
            scheduleSessionSave()
        }
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

    func queueHighlightedAssetForEditingInCurrentGroup() {
        guard !isQueuingForEdit else {
            return
        }

        guard let group = currentGroup else {
            return
        }

        ensureHighlightedAsset(in: group)
        guard let highlighted = highlightedAssetID(in: group) else {
            return
        }

        var selection = keepSelections(for: group)
        if !selection.contains(highlighted) {
            selection.insert(highlighted)
            keepSelectionsByGroup[group.id] = selection
            manuallyEditedGroupIDs.insert(group.id)
            scheduleEstimatedDiscardSizeRefresh()
            scheduleSessionSave()
        }

        errorMessage = nil
        isQueuingForEdit = true

        Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.isQueuingForEdit = false
            }

            do {
                guard await self.ensureAuthorizationForQueueing() else {
                    return
                }

                let result = try await self.libraryService.queueAssetForEditing(
                    withIdentifier: highlighted,
                    albumTitle: self.editAlbumTitle
                )

                switch result {
                case .createdAlbumAndAdded:
                    self.publishEditQueueMessage("Created \"\(self.editAlbumTitle)\" and queued the selected item.")
                case .addedToExistingAlbum:
                    self.publishEditQueueMessage("Queued selected item in \"\(self.editAlbumTitle)\".")
                case .alreadyInAlbum:
                    self.publishEditQueueMessage("Selected item is already in \"\(self.editAlbumTitle)\".")
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func keepOnly(assetID: String, in group: ReviewGroup) {
        keepSelectionsByGroup[group.id] = [assetID]
        manuallyEditedGroupIDs.insert(group.id)
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func keepAll(in group: ReviewGroup) {
        keepSelectionsByGroup[group.id] = Set(group.assetIDs)
        manuallyEditedGroupIDs.insert(group.id)
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func discardAll(in group: ReviewGroup) {
        keepSelectionsByGroup[group.id] = []
        manuallyEditedGroupIDs.insert(group.id)
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func keptCount(in group: ReviewGroup) -> Int {
        keepSelections(for: group).count
    }

    func discardCount(in group: ReviewGroup) -> Int {
        max(0, group.assetIDs.count - keptCount(in: group))
    }

    var totalAssetCountInBatch: Int {
        groups.reduce(0) { partial, group in
            partial + group.assetIDs.count
        }
    }

    var keptCountTotalReviewed: Int {
        groups.reduce(0) { partial, group in
            guard reviewedGroupIDs.contains(group.id) else {
                return partial
            }
            return partial + keepSelections(for: group).count
        }
    }

    var discardCountTotalReviewed: Int {
        groups.reduce(0) { partial, group in
            guard reviewedGroupIDs.contains(group.id) else {
                return partial
            }
            let kept = keepSelections(for: group).count
            return partial + max(0, group.assetIDs.count - kept)
        }
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

    var keepAssetIDs: [String] {
        var ids: Set<String> = []

        for group in groups {
            guard reviewedGroupIDs.contains(group.id) else {
                continue
            }

            ids.formUnion(keepSelections(for: group))
        }

        return ids.sorted()
    }

    var keepCountTotal: Int {
        keepAssetIDs.count
    }

    var discardCountTotal: Int {
        discardCountTotalReviewed
    }

    var manualDeleteAlbumName: String {
        manualDeleteAlbumTitle
    }

    var fullySortedAlbumName: String {
        fullySortedAlbumTitle
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

    func previewPlayerResult(for assetID: String) async -> VideoPreviewLoadResult {
        guard isVideo(assetID: assetID) else {
            return .unavailable("The selected item is not a video.")
        }

        guard let asset = assetLookup[assetID], asset.mediaType == .video else {
            return .unavailable("The selected video is no longer available in Photos.")
        }

        switch await libraryService.requestPlayerItem(for: asset) {
        case .success(let playerItemBox):
            let item = playerItemBox.item
            item.preferredForwardBufferDuration = 2

            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = AVPlayer.ActionAtItemEnd.pause
            return .ready(player)

        case .unavailable(let playerItemError):
            let avAsset: AVAsset
            if let cached = videoAssetCache[assetID] {
                avAsset = cached
            } else {
                guard let fetched = await ensureVideoAssetCached(for: assetID) else {
                    return .unavailable(playerItemError)
                }
                avAsset = fetched
            }

            let item = AVPlayerItem(asset: avAsset)
            item.preferredForwardBufferDuration = 2

            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = AVPlayer.ActionAtItemEnd.pause
            return .ready(player)
        }
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

    func confirmQueueMarkedAssetsForManualDelete() {
        guard discardCountTotal > 0 || keepCountTotal > 0 else {
            return
        }

        deletionArmed = false
        scheduleEstimatedDiscardSizeRefresh()
        showDeleteConfirmation = true
    }

    func queueMarkedAssetsForManualDelete() {
        let discardIDs = discardAssetIDs
        let keepIDs = keepAssetIDs
        guard !discardIDs.isEmpty || !keepIDs.isEmpty else {
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
                guard await self.ensureAuthorizationForQueueing() else {
                    self.isDeleting = false
                    return
                }

                let keepQueueResult = keepIDs.isEmpty ? nil : try await self.libraryService.queueAssets(
                    withIdentifiers: keepIDs,
                    intoAlbumTitle: self.fullySortedAlbumTitle
                )
                let discardQueueResult = discardIDs.isEmpty ? nil : try await self.libraryService.queueAssets(
                    withIdentifiers: discardIDs,
                    intoAlbumTitle: self.manualDeleteAlbumTitle
                )

                let committedIDs: Set<String> =
                    (keepQueueResult?.processedAssetIDs ?? Set<String>())
                    .union(discardQueueResult?.processedAssetIDs ?? Set<String>())
                guard !committedIDs.isEmpty || keepQueueResult != nil else {
                    self.errorMessage = "No marked items could be queued."
                    self.showDeleteConfirmation = false
                    self.deletionArmed = false
                    return
                }

                var completionParts: [String] = []

                if let keepQueueResult {
                    if keepQueueResult.createdAlbum {
                        if keepQueueResult.addedCount == 0 {
                            completionParts.append("Created \"\(self.fullySortedAlbumTitle)\". Kept items were already present.")
                        } else {
                            completionParts.append("Created \"\(self.fullySortedAlbumTitle)\" and queued \(keepQueueResult.addedCount) kept item(s).")
                        }
                    } else if keepQueueResult.addedCount > 0, keepQueueResult.alreadyPresentCount > 0 {
                        completionParts.append("Queued \(keepQueueResult.addedCount) kept item(s) to \"\(self.fullySortedAlbumTitle)\". \(keepQueueResult.alreadyPresentCount) were already there.")
                    } else if keepQueueResult.addedCount > 0 {
                        completionParts.append("Queued \(keepQueueResult.addedCount) kept item(s) to \"\(self.fullySortedAlbumTitle)\".")
                    } else {
                        completionParts.append("All kept items were already in \"\(self.fullySortedAlbumTitle)\".")
                    }
                }

                if let discardQueueResult {
                    if discardQueueResult.createdAlbum {
                        if discardQueueResult.addedCount == 0 {
                            completionParts.append("Created \"\(self.manualDeleteAlbumTitle)\". Marked items were already present.")
                        } else {
                            completionParts.append("Created \"\(self.manualDeleteAlbumTitle)\" and queued \(discardQueueResult.addedCount) marked item(s).")
                        }
                    } else if discardQueueResult.addedCount > 0, discardQueueResult.alreadyPresentCount > 0 {
                        completionParts.append("Queued \(discardQueueResult.addedCount) marked item(s) to \"\(self.manualDeleteAlbumTitle)\". \(discardQueueResult.alreadyPresentCount) were already there.")
                    } else if discardQueueResult.addedCount > 0 {
                        completionParts.append("Queued \(discardQueueResult.addedCount) marked item(s) to \"\(self.manualDeleteAlbumTitle)\".")
                    } else {
                        completionParts.append("All marked items were already in \"\(self.manualDeleteAlbumTitle)\".")
                    }
                }

                let totalMissingCount = (keepQueueResult?.missingCount ?? 0) + (discardQueueResult?.missingCount ?? 0)
                let missingSuffix = totalMissingCount > 0
                    ? " \(totalMissingCount) item(s) were unavailable and not queued."
                    : ""
                let completionMessage = completionParts.joined(separator: " ")

                self.applyCommittedDiscardsToCurrentSession(
                    committedIDs: committedIDs,
                    completionMessage: completionMessage + missingSuffix,
                    statusMessage: keepQueueResult != nil ? "Album queues updated." : "Manual-delete queue updated."
                )
            } catch {
                self.errorMessage = error.localizedDescription
            }

            self.isDeleting = false
        }
    }

    private func applyCommittedDiscardsToCurrentSession(
        committedIDs: Set<String>,
        completionMessage: String,
        statusMessage: String
    ) {
        guard !committedIDs.isEmpty else {
            return
        }

        let previousGroupID = currentGroup?.id
        let previousHighlightedAssetID = currentGroup.flatMap { highlightedAssetID(in: $0) }
        let previousGroupIndex = currentGroupIndex
        let originalGroupIndexByID = Dictionary(
            uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) }
        )
        sizeEstimateTask?.cancel()
        isEstimatingDiscardBytes = false
        prefetchTask?.cancel()

        var updatedGroups: [ReviewGroup] = []
        updatedGroups.reserveCapacity(groups.count)
        for group in groups {
            let remainingIDs = group.assetIDs.filter { !committedIDs.contains($0) }
            guard !remainingIDs.isEmpty else {
                continue
            }

            if remainingIDs.count == group.assetIDs.count {
                updatedGroups.append(group)
            } else {
                updatedGroups.append(
                    ReviewGroup(
                        id: group.id,
                        assetIDs: remainingIDs,
                        startDate: group.startDate,
                        endDate: group.endDate
                    )
                )
            }
        }

        groups = updatedGroups

        let validGroupIDs = Set(updatedGroups.map(\.id))
        let validAssetIDs = Set(updatedGroups.flatMap(\.assetIDs))
        let groupsByID = Dictionary(uniqueKeysWithValues: updatedGroups.map { ($0.id, $0) })
        let assetIDsByGroupID = Dictionary(uniqueKeysWithValues: updatedGroups.map { ($0.id, Set($0.assetIDs)) })

        keepSelectionsByGroup = keepSelectionsByGroup.reduce(into: [:]) { partial, entry in
            guard let allowedIDs = assetIDsByGroupID[entry.key] else {
                return
            }
            partial[entry.key] = entry.value.intersection(allowedIDs)
        }

        highlightedAssetByGroup = highlightedAssetByGroup.reduce(into: [:]) { partial, entry in
            guard let allowedIDs = assetIDsByGroupID[entry.key] else {
                return
            }

            if allowedIDs.contains(entry.value) {
                partial[entry.key] = entry.value
            } else {
                if let fallback = groupsByID[entry.key]?.assetIDs.first {
                    partial[entry.key] = fallback
                }
            }
        }
        for group in updatedGroups where highlightedAssetByGroup[group.id] == nil {
            highlightedAssetByGroup[group.id] = group.assetIDs.first
        }

        reviewedGroupIDs = reviewedGroupIDs.intersection(validGroupIDs)
        manuallyEditedGroupIDs = manuallyEditedGroupIDs.intersection(validGroupIDs)
        assetLookup = assetLookup.filter { validAssetIDs.contains($0.key) }
        mediaBadgesCache = mediaBadgesCache.filter { validAssetIDs.contains($0.key) }
        videoAssetCache = videoAssetCache.filter { validAssetIDs.contains($0.key) }
        estimatedAssetSizeByID = estimatedAssetSizeByID.filter { validAssetIDs.contains($0.key) }

        let staleThumbnailAssetIDs = Set(thumbnailKeysByAssetID.keys).subtracting(validAssetIDs)
        for assetID in staleThumbnailAssetIDs {
            if let keySet = thumbnailKeysByAssetID.removeValue(forKey: assetID) {
                for key in keySet {
                    thumbnailCache.removeObject(forKey: NSString(string: key))
                }
            }
        }

        scannedAssetCount = validAssetIDs.count
        deletionArmed = false
        showDeleteConfirmation = false

        if groups.isEmpty {
            currentGroupIndex = 0
            deletionMessage = "\(completionMessage) No groups remain in this session."
            scanStatusMessage = "\(statusMessage) Run a new scan when ready."
        } else if let restoredIndex = anchoredGroupIndex(
            preferredGroupID: previousGroupID,
            preferredAssetID: previousHighlightedAssetID,
            in: groups
        ) {
            currentGroupIndex = restoredIndex
            deletionMessage = "\(completionMessage) Continued review from the current group."
            scanStatusMessage = "\(statusMessage) Continuing review."
        } else {
            currentGroupIndex = nearestSurvivingGroupIndex(
                fallbackOriginalIndex: previousGroupIndex,
                in: groups,
                originalIndexByGroupID: originalGroupIndexByID
            )
            deletionMessage = "\(completionMessage) Continued review in remaining groups."
            scanStatusMessage = "\(statusMessage) Continuing review."
        }

        schedulePrefetchAndCacheMaintenance()
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    private func anchoredGroupIndex(
        preferredGroupID: UUID?,
        preferredAssetID: String?,
        in groups: [ReviewGroup]
    ) -> Int? {
        if let preferredGroupID,
           let matchingIndex = groups.firstIndex(where: { $0.id == preferredGroupID }) {
            return matchingIndex
        }

        if let preferredAssetID,
           let matchingIndex = groups.firstIndex(where: { $0.assetIDs.contains(preferredAssetID) }) {
            return matchingIndex
        }

        return nil
    }

    private func nearestSurvivingGroupIndex(
        fallbackOriginalIndex: Int,
        in groups: [ReviewGroup],
        originalIndexByGroupID: [UUID: Int]
    ) -> Int {
        guard !groups.isEmpty else {
            return 0
        }

        if let nextIndex = groups.enumerated().first(where: { index, group in
            (originalIndexByGroupID[group.id] ?? index) >= fallbackOriginalIndex
        })?.offset {
            return nextIndex
        }

        return max(0, groups.count - 1)
    }

    private func keepSelections(for group: ReviewGroup) -> Set<String> {
        if let selection = keepSelectionsByGroup[group.id] {
            return selection
        }

        let defaultSelection = defaultKeepSelection(for: group)
        keepSelectionsByGroup[group.id] = defaultSelection
        return defaultSelection
    }

    private func initializeDefaultSelections() {
        for group in groups {
            keepSelectionsByGroup[group.id] = defaultKeepSelection(for: group)
            highlightedAssetByGroup[group.id] = group.assetIDs.first
        }
    }

    private func defaultKeepSelection(for group: ReviewGroup) -> Set<String> {
        []
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
            scheduleSessionSave()
        }
    }

    private func beginKeyboardNavigationSession() {
        ignoreHoverUntilMouseMoves = true
        mouseLocationAtKeyboardNavigation = NSEvent.mouseLocation
    }

    private func publishEditQueueMessage(_ message: String) {
        editQueueMessageTask?.cancel()
        editQueueMessage = message
        editQueueMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            self.editQueueMessage = nil
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

    private var persistedReviewSessionURL: URL {
        AppPaths.reviewSessionURL(bundleIdentifier: currentBundleIdentifier)
    }

    private var currentBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? currentBundleIdentifierFallback
    }

    private func migrateLegacyPersistenceIfNeeded() {
        migrateLegacyReviewSessionIfNeeded()
    }

    private func migrateLegacyReviewSessionIfNeeded() {
        guard currentBundleIdentifier != legacyBundleIdentifier else {
            return
        }

        let currentURL = persistedReviewSessionURL
        guard !FileManager.default.fileExists(atPath: currentURL.path) else {
            return
        }

        let legacyURL = AppPaths.reviewSessionURL(bundleIdentifier: legacyBundleIdentifier)
        guard let legacyData = try? Data(contentsOf: legacyURL) else {
            return
        }

        let currentDirectory = currentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: currentDirectory,
            withIntermediateDirectories: true
        )
        try? legacyData.write(to: currentURL, options: [.atomic])
    }

    private func restoreReviewSessionIfAvailable() async {
        guard !hasAttemptedSessionRestore else {
            return
        }
        hasAttemptedSessionRestore = true

        let url = persistedReviewSessionURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = try? Data(contentsOf: url),
            let stored = try? decoder.decode(StoredReviewSession.self, from: data)
        else {
            return
        }

        let requestedAssetIDs = Array(Set(stored.groups.flatMap(\.assetIDs)))
        guard !requestedAssetIDs.isEmpty else {
            clearPersistedReviewSession()
            return
        }

        let availableAssets = libraryService.fetchAssetsByLocalIdentifier(requestedAssetIDs)
        let restored = sanitizedReviewSession(from: stored, with: availableAssets)
        guard !restored.groups.isEmpty else {
            clearPersistedReviewSession()
            return
        }

        applyStoredScanControls(restored)

        let restoredAssetIDs = Set(restored.groups.flatMap(\.assetIDs))
        assetLookup = availableAssets.filter { restoredAssetIDs.contains($0.key) }
        groups = restored.groups
        keepSelectionsByGroup = restored.keepSelectionsByGroup
        highlightedAssetByGroup = restored.highlightedAssetByGroup
        reviewedGroupIDs = restored.reviewedGroupIDs
        manuallyEditedGroupIDs = restored.manuallyEditedGroupIDs
        scannedAssetCount = restored.scannedAssetCount
        temporalClusterCount = restored.temporalClusterCount
        currentGroupIndex = anchoredGroupIndex(
            preferredGroupID: restored.currentGroupID,
            preferredAssetID: restored.currentHighlightedAssetID,
            in: restored.groups
        ) ?? min(max(0, restored.currentGroupIndex), max(0, restored.groups.count - 1))

        deletionArmed = false
        scanProgress = 0
        isScanning = false
        scanStatusMessage = "Restored previous review session (\(groups.count) groups)."

        schedulePrefetchAndCacheMaintenance()
        scheduleEstimatedDiscardSizeRefresh()
    }

    private func applyStoredScanControls(_ stored: StoredReviewSession) {
        sourceMode = stored.sourceMode
        selectedAlbumID = stored.selectedAlbumID
        if sourceMode == .album, albums.contains(where: { $0.id == selectedAlbumID }) == false {
            sourceMode = .allPhotos
            selectedAlbumID = nil
        }

        useDateRange = stored.useDateRange
        rangeStartDate = stored.rangeStartDate
        rangeEndDate = stored.rangeEndDate
        includeVideos = stored.includeVideos
        autoplayPreviewVideos = stored.autoplayPreviewVideos
        maxTimeGapSeconds = stored.maxTimeGapSeconds
        similarityDistanceThreshold = fixedSimilarityDistanceThreshold
    }

    private func sanitizedReviewSession(
        from stored: StoredReviewSession,
        with availableAssets: [String: PHAsset]
    ) -> StoredReviewSession {
        var validGroups: [ReviewGroup] = []
        var validKeepSelections: [UUID: Set<String>] = [:]
        var validHighlighted: [UUID: String] = [:]

        for group in stored.groups {
            let filteredAssetIDs = group.assetIDs.filter { availableAssets[$0] != nil }
            guard !filteredAssetIDs.isEmpty else {
                continue
            }

            let validGroup = ReviewGroup(
                id: group.id,
                assetIDs: filteredAssetIDs,
                startDate: group.startDate,
                endDate: group.endDate
            )
            validGroups.append(validGroup)

            let allowedIDs = Set(filteredAssetIDs)
            let kept = stored.keepSelectionsByGroup[group.id, default: []]
                .intersection(allowedIDs)
            validKeepSelections[group.id] = kept

            if let highlighted = stored.highlightedAssetByGroup[group.id], allowedIDs.contains(highlighted) {
                validHighlighted[group.id] = highlighted
            } else {
                validHighlighted[group.id] = filteredAssetIDs.first
            }
        }

        let validGroupIDs = Set(validGroups.map(\.id))
        let validAssetIDs = Set(validGroups.flatMap(\.assetIDs))

        let validReviewed = stored.reviewedGroupIDs.intersection(validGroupIDs)
        let validManualEdits = stored.manuallyEditedGroupIDs.intersection(validGroupIDs)
        let validIndex = min(max(0, stored.currentGroupIndex), max(0, validGroups.count - 1))
        let validCurrentGroupID = stored.currentGroupID.flatMap { validGroupIDs.contains($0) ? $0 : nil }
        let validCurrentHighlightedAssetID = stored.currentHighlightedAssetID.flatMap {
            validAssetIDs.contains($0) ? $0 : nil
        }

        return StoredReviewSession(
            groups: validGroups,
            currentGroupIndex: validIndex,
            currentGroupID: validCurrentGroupID,
            currentHighlightedAssetID: validCurrentHighlightedAssetID,
            keepSelectionsByGroup: validKeepSelections,
            highlightedAssetByGroup: validHighlighted,
            reviewedGroupIDs: validReviewed,
            manuallyEditedGroupIDs: validManualEdits,
            scannedAssetCount: max(stored.scannedAssetCount, validAssetIDs.count),
            temporalClusterCount: max(0, stored.temporalClusterCount),
            sourceMode: stored.sourceMode,
            selectedAlbumID: stored.selectedAlbumID,
            useDateRange: stored.useDateRange,
            rangeStartDate: stored.rangeStartDate,
            rangeEndDate: stored.rangeEndDate,
            includeVideos: stored.includeVideos,
            autoplayPreviewVideos: stored.autoplayPreviewVideos,
            maxTimeGapSeconds: stored.maxTimeGapSeconds,
            similarityDistanceThreshold: fixedSimilarityDistanceThreshold
        )
    }

    private func makeStoredReviewSession() -> StoredReviewSession? {
        guard !groups.isEmpty else {
            return nil
        }

        var normalizedKeepSelections: [UUID: Set<String>] = [:]
        var normalizedHighlights: [UUID: String] = [:]

        for group in groups {
            let validIDs = Set(group.assetIDs)
            normalizedKeepSelections[group.id] = keepSelectionsByGroup[group.id, default: []]
                .intersection(validIDs)

            if let highlighted = highlightedAssetByGroup[group.id], validIDs.contains(highlighted) {
                normalizedHighlights[group.id] = highlighted
            } else {
                normalizedHighlights[group.id] = group.assetIDs.first
            }
        }

        return StoredReviewSession(
            groups: groups,
            currentGroupIndex: currentGroupIndex,
            currentGroupID: currentGroup?.id,
            currentHighlightedAssetID: currentGroup.flatMap { highlightedAssetID(in: $0) },
            keepSelectionsByGroup: normalizedKeepSelections,
            highlightedAssetByGroup: normalizedHighlights,
            reviewedGroupIDs: reviewedGroupIDs,
            manuallyEditedGroupIDs: manuallyEditedGroupIDs,
            scannedAssetCount: scannedAssetCount,
            temporalClusterCount: temporalClusterCount,
            sourceMode: sourceMode,
            selectedAlbumID: selectedAlbumID,
            useDateRange: useDateRange,
            rangeStartDate: rangeStartDate,
            rangeEndDate: rangeEndDate,
            includeVideos: includeVideos,
            autoplayPreviewVideos: autoplayPreviewVideos,
            maxTimeGapSeconds: maxTimeGapSeconds,
            similarityDistanceThreshold: fixedSimilarityDistanceThreshold
        )
    }

    private func scheduleSessionSave() {
        guard !isScanning else {
            return
        }

        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            self.persistReviewSessionNow()
        }
    }

    private func persistReviewSessionNow() {
        guard let snapshot = makeStoredReviewSession() else {
            clearPersistedReviewSession()
            return
        }

        let url = persistedReviewSessionURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(snapshot) else {
            return
        }

        let directoryURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    private func clearPersistedReviewSession() {
        let url = persistedReviewSessionURL
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func scheduleEstimatedDiscardSizeRefresh() {
        let ids = discardAssetIDs
        guard !ids.isEmpty else {
            sizeEstimateTask?.cancel()
            isEstimatingDiscardBytes = false
            estimatedDiscardBytes = 0
            return
        }

        sizeEstimateTask?.cancel()
        isEstimatingDiscardBytes = true

        let cachedSizes = estimatedAssetSizeByID
        let service = libraryService

        sizeEstimateTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (Int64, [String: Int64]) in
                var total: Int64 = 0
                var discoveredSizes: [String: Int64] = [:]

                for assetID in ids {
                    if Task.isCancelled {
                        return (0, [:])
                    }

                    if let cachedSize = cachedSizes[assetID] {
                        total += cachedSize
                        continue
                    }

                    if let measuredSize = service.estimatedByteSize(forAssetID: assetID) {
                        total += measuredSize
                        discoveredSizes[assetID] = measuredSize
                    }
                }

                return (total, discoveredSizes)
            }.value

            guard let self, !Task.isCancelled else {
                return
            }

            for (assetID, size) in result.1 {
                self.estimatedAssetSizeByID[assetID] = size
            }

            self.estimatedDiscardBytes = result.0
            self.isEstimatingDiscardBytes = false
        }
    }

    private func loadStoredScanPreferences() {
        guard let stored = scanPreferencesStore.load() else {
            return
        }

        useDateRange = stored.useDateRange
        rangeStartDate = stored.rangeStartDate
        rangeEndDate = stored.rangeEndDate
        includeVideos = stored.includeVideos
        autoplayPreviewVideos = stored.autoplayPreviewVideos
        maxTimeGapSeconds = stored.maxTimeGapSeconds
        similarityDistanceThreshold = fixedSimilarityDistanceThreshold
        maxAssetsToScan = stored.maxAssetsToScan
    }

    private func scheduleStoredScanPreferencesSave() {
        scanPreferencesSaveTask?.cancel()
        scanPreferencesSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            self.persistStoredScanPreferences()
        }
    }

    private func persistStoredScanPreferences() {
        scanPreferencesStore.save(
            StoredScanPreferences(
            useDateRange: useDateRange,
            rangeStartDate: rangeStartDate,
            rangeEndDate: rangeEndDate,
            includeVideos: includeVideos,
            autoplayPreviewVideos: autoplayPreviewVideos,
            maxTimeGapSeconds: maxTimeGapSeconds,
            maxAssetsToScan: maxAssetsToScan
            )
        )
    }
}
