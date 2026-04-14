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

    enum EffectiveReviewState {
        case keep
        case discard
    }

    @Published var authorizationStatus: PHAuthorizationStatus
    @Published var albums: [AlbumOption] = []
    @Published private(set) var reviewMode: ReviewMode = .discardFirst

    @Published var selectedSourceKind: ReviewSourceKind = .photos {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var sourceMode: PhotoSourceMode = .allPhotos {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var selectedAlbumID: String? {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var folderSelection: FolderSelection? {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var recentFolders: [FolderSelection] = [] {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var folderRecursiveScan = true {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var moveKeptItemsToKeepFolder = false {
        didSet { scheduleStoredScanPreferencesSave() }
    }

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
    @Published var skippedHiddenCount = 0
    @Published var skippedUnsupportedCount = 0
    @Published var skippedPackageCount = 0
    @Published var skippedSymlinkDirectoryCount = 0

    @Published var groups: [ReviewGroup] = []
    @Published var currentGroupIndex = 0
    @Published var reviewDecisionsByGroup: [UUID: ReviewGroupDecisions] = [:]
    @Published var highlightedItemByGroup: [UUID: String] = [:]
    @Published var reviewedGroupIDs: Set<UUID> = []
    @Published var queuedForEditItemIDs: Set<String> = []
    @Published var showReviewModeResetConfirmation = false

    @Published var showDeleteConfirmation = false
    @Published var isDeleting = false
    @Published var deletionArmed = false
    @Published var deletionMessage: String?
    @Published var errorMessage: String?
    @Published var editQueueMessage: String?
    @Published private(set) var isQueuingForEdit = false
    @Published private(set) var estimatedDiscardBytes: Int64 = 0
    @Published private(set) var isEstimatingDiscardBytes = false
    @Published private(set) var folderCommitPlan: FolderCommitPlan?

    private let libraryService = PhotoLibraryService()
    private let folderLibraryService = FolderLibraryService()
    private let folderCommitService = FolderCommitService()
    private lazy var scanner = SimilarityScanner(
        photoLibraryService: libraryService,
        folderLibraryService: folderLibraryService
    )

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailKeysByItemID: [String: Set<String>] = [:]
    private var photoAssetLookup: [String: PHAsset] = [:]
    private var itemLookup: [String: ReviewItem] = [:]
    private var videoAssetCache: [String: AVAsset] = [:]

    private var scanTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var ignoreHoverUntilMouseMoves = false
    private var mouseLocationAtKeyboardNavigation: CGPoint = .zero
    private var sessionSaveTask: Task<Void, Never>?
    private var scanPreferencesSaveTask: Task<Void, Never>?
    private var sizeEstimateTask: Task<Void, Never>?
    private var editQueueMessageTask: Task<Void, Never>?
    private var hasAttemptedSessionRestore = false
    private let editAlbumTitle = "Files to Edit"
    private let manualDeleteAlbumTitle = "Files to Manually Delete"
    private let fullySortedAlbumTitle = "Fully Sorted"
    private let fixedSimilarityDistanceThreshold: Double = 12.0
    private let recommendedScopeThreshold = 2_000
    private let recentFolderLimit = 6
    private let currentBundleIdentifierFallback = "com.jkfisher.photoslibrarysorthelper"
    private let legacyBundleIdentifier = "com.jkfisher.photosorthelper"
    private lazy var scanPreferencesStore = ScanPreferencesStore(bundleIdentifier: currentBundleIdentifier)
    private var pendingScanSettings: ScanSettings?
    private var pendingReviewMode: ReviewMode?

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
        }
        await restoreReviewSessionIfAvailable()
    }

    var isAuthorized: Bool {
        PhotoAuthorizationSupport.canAccessLibrary(authorizationStatus)
    }

    var canInitiateScan: Bool {
        switch selectedSourceKind {
        case .photos:
            return authorizationStatus != .denied && authorizationStatus != .restricted
        case .folder:
            return folderSelection != nil
        }
    }

    var currentGroup: ReviewGroup? {
        guard groups.indices.contains(currentGroupIndex) else {
            return nil
        }
        return groups[currentGroupIndex]
    }

    var hasPreviousGroup: Bool {
        currentGroupIndex > 0
    }

    var hasNextGroup: Bool {
        currentGroupIndex < groups.count - 1
    }

    var reviewedGroupCount: Int {
        reviewedGroupIDs.intersection(Set(groups.map(\.id))).count
    }

    var hasActiveReviewSession: Bool {
        !groups.isEmpty
    }

    var hasHighlightInCurrentGroup: Bool {
        guard let group = currentGroup else { return false }
        return highlightedAssetID(in: group) != nil
    }

    var totalAssetCountInBatch: Int {
        groups.reduce(0) { $0 + $1.itemIDs.count }
    }

    var keepCountTotalReviewed: Int {
        groups.reduce(0) { partial, group in
            guard reviewedGroupIDs.contains(group.id) else { return partial }
            return partial + group.itemIDs.filter { effectiveReviewState(for: $0, in: group) == .keep }.count
        }
    }

    var discardCountTotalReviewed: Int {
        groups.reduce(0) { partial, group in
            guard reviewedGroupIDs.contains(group.id) else { return partial }
            return partial + group.itemIDs.filter { effectiveReviewState(for: $0, in: group) == .discard }.count
        }
    }

    var keepCountTotal: Int {
        explicitKeepItemIDs.count
    }

    var discardCountTotal: Int {
        explicitDiscardItemIDs.count
    }

    var implicitKeepCountTotal: Int {
        implicitKeepItemIDs.count
    }

    var editQueueCountTotal: Int {
        groups.reduce(0) { partial, group in
            guard reviewedGroupIDs.contains(group.id) else { return partial }
            return partial + queuedForEditItemIDs.intersection(group.itemIDs).count
        }
    }

    var reviewModeStatusText: String {
        reviewMode.title
    }

    var reviewModeSetupDescription: String {
        reviewMode.shortDescription
    }

    var reviewGuidanceText: String {
        switch (reviewMode, selectedSourceKind) {
        case (.discardFirst, .photos):
            return "Manual review only: items start as discard until you mark keep or edit, then queue the results into Photos albums."
        case (.discardFirst, .folder):
            return "Manual review only: items start as discard until you mark keep or edit, then use the summary to move queued files into sibling folders."
        case (.keepFirst, .photos):
            return "Manual review only: items start as kept for review, but only explicit keeps, discards, and edits are queued into Photos albums."
        case (.keepFirst, .folder):
            return "Manual review only: items start as kept for review, but only explicit keeps, discards, and edits affect folder moves."
        }
    }

    var summaryIntroText: String {
        switch (selectedSourceKind, reviewMode) {
        case (.photos, .discardFirst):
            return "Review this summary before queueing kept and discarded items into their Photos albums."
        case (.photos, .keepFirst):
            return "Review this summary before queueing explicit keeps, discards, and edits into their Photos albums."
        case (.folder, .discardFirst):
            return "Review this preview before moving any files into sibling queue folders."
        case (.folder, .keepFirst):
            return "Review this preview before moving explicit keeps, discards, and edits into sibling queue folders."
        }
    }

    var summaryConfirmationText: String {
        switch (selectedSourceKind, reviewMode) {
        case (.photos, .discardFirst):
            return "I understand this queues kept items to \"\(fullySortedAlbumName)\" and discards to \"\(manualDeleteAlbumName)\"."
        case (.photos, .keepFirst):
            return "I understand this queues only explicit keeps, discards, and edits. Untouched review-only keeps stay out of the keep album."
        case (.folder, .discardFirst):
            return "I understand this will move reviewed files into sibling queue folders while preserving subfolder structure."
        case (.folder, .keepFirst):
            return "I understand this will move only explicit keeps, discards, and edits into sibling queue folders while preserving subfolder structure."
        }
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

    var manualDeleteAlbumName: String {
        manualDeleteAlbumTitle
    }

    var fullySortedAlbumName: String {
        selectedSourceKind == .photos ? fullySortedAlbumTitle : FolderCommitDestination.keep.folderName
    }

    var selectedFolderPath: String {
        folderSelection?.resolvedPath ?? "No folder selected"
    }

    var folderSelectionDescription: String {
        folderSelection == nil ? "Choose a folder to review recursively." : selectedFolderPath
    }

    var recentFolderOptions: [FolderSelection] {
        recentFolders
    }

    var canOpenSummary: Bool {
        !isDeleting && ((discardCountTotal > 0 || keepCountTotal > 0) || (folderCommitPlan?.totalMoveCount ?? 0) > 0)
    }

    var canRevealSourceFolder: Bool {
        resolvedSourceFolderURL != nil
    }

    var canRevealQueueDestinations: Bool {
        selectedSourceKind == .folder && resolvedSourceFolderURL != nil
    }

    var canRevealHighlightedItemInFinder: Bool {
        highlightedFileURL != nil
    }

    var canOpenFocusedItem: Bool {
        highlightedFileURL != nil
    }

    var highlightedItem: ReviewItem? {
        guard let group = currentGroup, let itemID = highlightedAssetID(in: group) else {
            return nil
        }
        return itemLookup[itemID]
    }

    var highlightedItemTitle: String {
        highlightedItem?.displayName ?? "Nothing highlighted"
    }

    var highlightedItemSecondaryDetail: String {
        highlightedItem?.detailLabel ?? (highlightedFileURL?.path ?? "Select an item to inspect its details.")
    }

    var highlightedItemPath: String? {
        highlightedFileURL?.path
    }

    var currentSourceSummary: String {
        switch selectedSourceKind {
        case .photos:
            return sourceMode == .album ? "Photos library · album scope" : "Photos library · all photos"
        case .folder:
            return folderSelection?.resolvedPath ?? "Folder mode · no folder selected"
        }
    }

    var folderCommitDestinationRootPath: String {
        guard let sourceFolderURL = try? folderLibraryService.resolveValidatedFolderURL(for: folderSelection) else {
            return "Choose a source folder to determine destination paths."
        }
        return folderCommitService.destinationPaths(for: sourceFolderURL).destinationRootURL.path
    }

    func requestReviewModeChange(_ newMode: ReviewMode) {
        guard newMode != reviewMode else { return }

        if hasActiveReviewSession {
            pendingReviewMode = newMode
            showReviewModeResetConfirmation = true
            return
        }

        applyReviewModeChange(newMode, resetSession: false)
    }

    func confirmReviewModeChange() {
        guard let pendingReviewMode else {
            showReviewModeResetConfirmation = false
            return
        }

        showReviewModeResetConfirmation = false
        applyReviewModeChange(pendingReviewMode, resetSession: true)
        self.pendingReviewMode = nil
    }

    func cancelReviewModeChange() {
        pendingReviewMode = nil
        showReviewModeResetConfirmation = false
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

    func refreshAlbums() async {
        guard isAuthorized else {
            albums = []
            return
        }

        albums = libraryService.fetchAlbums()
        if sourceMode == .album,
           (selectedAlbumID == nil || albums.contains(where: { $0.id == selectedAlbumID }) == false) {
            selectedAlbumID = albums.first?.id
        }
    }

    func changeSourceFolder() {
        Task { [weak self] in
            guard let self else { return }
            guard let selected = await self.folderLibraryService.chooseFolder(
                attachedTo: NSApp.keyWindow,
                initialSelection: self.folderSelection
            ) else {
                return
            }

            self.applyFolderSelection(
                selected,
                statusMessage: "Folder changed. Run a scan to load media from the selected folder."
            )
        }
    }

    func selectRecentFolder(_ selection: FolderSelection) {
        applyFolderSelection(
            selection,
            statusMessage: "Recent folder selected. Run a scan to load media from the selected folder."
        )
    }

    func removeRecentFolder(_ selection: FolderSelection) {
        recentFolders.removeAll { $0.resolvedPath == selection.resolvedPath }
    }

    func clearRecentFolders() {
        recentFolders = []
    }

    func acceptDroppedFolders(_ urls: [URL]) -> Bool {
        guard let firstDirectory = urls.first(where: { folderLibraryService.isDirectoryURL($0.standardizedFileURL) }) else {
            return false
        }

        applyFolderSelection(
            folderLibraryService.makeSelection(from: firstDirectory.standardizedFileURL),
            statusMessage: "Folder dropped into the app. Run a scan to load media from the selected folder."
        )
        return true
    }

    func openSelectedFolder() {
        guard let url = resolvedSourceFolderURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealSourceFolderInFinder() {
        guard let url = resolvedSourceFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealQueueDestinationInFinder(_ destination: FolderCommitDestination) {
        guard let sourceFolderURL = resolvedSourceFolderURL else { return }
        let destinationURL = folderCommitService.destinationPaths(for: sourceFolderURL).url(for: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    }

    func revealHighlightedItemInFinder() {
        guard let url = highlightedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealItemInFinder(assetID: String) {
        guard let url = fileURL(for: assetID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFocusedItem() {
        guard let url = highlightedFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    func requestScan() {
        guard !isScanning else { return }

        Task { [weak self] in
            guard let self else { return }

            if self.selectedSourceKind == .photos {
                let canScan = await self.ensureAuthorizationForScan()
                guard canScan else { return }
            } else if self.folderSelection == nil {
                self.errorMessage = ReviewError.missingSourceFolder.localizedDescription
                return
            }

            self.errorMessage = nil
            self.deletionMessage = nil
            self.editQueueMessage = nil
            self.showLargeSelectionWarning = false
            self.pendingScanSettings = nil

            let settings = self.buildScanSettings()

            if settings.selectedSourceKind == .photos {
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

    func stopScan() {
        guard isScanning else { return }
        scanStatusMessage = "Stopping scan..."
        scanTask?.cancel()
    }

    func previousGroup() {
        guard currentGroupIndex > 0 else { return }
        currentGroupIndex -= 1
        schedulePrefetchAndCacheMaintenance()
        scheduleSessionSave()
    }

    func nextGroup() {
        guard currentGroupIndex < groups.count - 1 else { return }
        currentGroupIndex += 1
        schedulePrefetchAndCacheMaintenance()
        scheduleSessionSave()
    }

    func isGroupReviewed(_ group: ReviewGroup) -> Bool {
        reviewedGroupIDs.contains(group.id)
    }

    func keepOnly(assetID: String, in group: ReviewGroup) {
        var decisions = decisions(for: group)
        switch reviewMode {
        case .discardFirst:
            decisions.explicitKeepIDs = [assetID]
            decisions.explicitDiscardIDs = []
        case .keepFirst:
            decisions.explicitKeepIDs = [assetID]
            decisions.explicitDiscardIDs = Set(group.itemIDs.filter { $0 != assetID })
        }
        reviewDecisionsByGroup[group.id] = decisions
        queuedForEditItemIDs = queuedForEditItemIDs.filter { $0 == assetID || !group.itemIDs.contains($0) }.reduce(into: Set<String>()) { $0.insert($1) }
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func keepAll(in group: ReviewGroup) {
        var decisions = decisions(for: group)
        decisions.explicitKeepIDs = Set(group.itemIDs)
        decisions.explicitDiscardIDs = []
        reviewDecisionsByGroup[group.id] = decisions
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func discardAll(in group: ReviewGroup) {
        var decisions = decisions(for: group)
        switch reviewMode {
        case .discardFirst:
            decisions.explicitKeepIDs = []
            decisions.explicitDiscardIDs = []
        case .keepFirst:
            decisions.explicitKeepIDs = []
            decisions.explicitDiscardIDs = Set(group.itemIDs)
        }
        reviewDecisionsByGroup[group.id] = decisions
        queuedForEditItemIDs.subtract(group.itemIDs)
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func isKept(assetID: String, in group: ReviewGroup) -> Bool {
        effectiveReviewState(for: assetID, in: group) == .keep
    }

    func isExplicitKeep(assetID: String, in group: ReviewGroup) -> Bool {
        explicitKeepIDs(for: group).contains(assetID)
    }

    func isExplicitDiscard(assetID: String, in group: ReviewGroup) -> Bool {
        explicitDiscardIDs(for: group).contains(assetID)
    }

    func isImplicitKeep(assetID: String, in group: ReviewGroup) -> Bool {
        implicitKeepIDs(for: group).contains(assetID)
    }

    func isQueuedForEdit(assetID: String) -> Bool {
        queuedForEditItemIDs.contains(assetID)
    }

    func reviewStatusLabel(assetID: String, in group: ReviewGroup) -> String {
        if queuedForEditItemIDs.contains(assetID) {
            return "EDIT"
        }
        if isExplicitKeep(assetID: assetID, in: group) {
            return "KEEP"
        }
        if isExplicitDiscard(assetID: assetID, in: group) {
            return "DISCARD"
        }
        if isImplicitKeep(assetID: assetID, in: group) {
            return "REVIEW KEEP"
        }
        return "DISCARD"
    }

    func reviewStateDescription(assetID: String, in group: ReviewGroup) -> String {
        if queuedForEditItemIDs.contains(assetID) {
            return "Queued for edit"
        }
        if isExplicitKeep(assetID: assetID, in: group) {
            return "Explicit keep"
        }
        if isExplicitDiscard(assetID: assetID, in: group) {
            return "Explicit discard"
        }
        if isImplicitKeep(assetID: assetID, in: group) {
            return "Review-only keep"
        }
        return "Discard"
    }

    func toggleKeep(assetID: String, in group: ReviewGroup) {
        var decisions = decisions(for: group)

        switch reviewMode {
        case .discardFirst:
            if effectiveReviewState(for: assetID, in: group) == .keep {
                decisions.explicitKeepIDs.remove(assetID)
                queuedForEditItemIDs.remove(assetID)
            } else {
                decisions.explicitDiscardIDs.remove(assetID)
                decisions.explicitKeepIDs.insert(assetID)
            }

        case .keepFirst:
            if effectiveReviewState(for: assetID, in: group) == .keep {
                decisions.explicitKeepIDs.remove(assetID)
                decisions.explicitDiscardIDs.insert(assetID)
                queuedForEditItemIDs.remove(assetID)
            } else {
                decisions.explicitDiscardIDs.remove(assetID)
            }
        }

        reviewDecisionsByGroup[group.id] = decisions
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func highlightedAssetID(in group: ReviewGroup) -> String? {
        guard !group.itemIDs.isEmpty else { return nil }
        if let highlighted = highlightedItemByGroup[group.id], group.itemIDs.contains(highlighted) {
            return highlighted
        }
        return group.itemIDs.first
    }

    func isHighlighted(assetID: String, in group: ReviewGroup) -> Bool {
        highlightedAssetID(in: group) == assetID
    }

    func ensureHighlightedAsset(in group: ReviewGroup) {
        guard let highlighted = highlightedAssetID(in: group) else {
            highlightedItemByGroup.removeValue(forKey: group.id)
            return
        }
        if highlightedItemByGroup[group.id] != highlighted {
            highlightedItemByGroup[group.id] = highlighted
        }
    }

    func setHighlighted(assetID: String, in group: ReviewGroup) {
        guard group.itemIDs.contains(assetID) else { return }
        if highlightedItemByGroup[group.id] != assetID {
            highlightedItemByGroup[group.id] = assetID
            scheduleSessionSave()
        }
    }

    func markGroupReviewed(_ group: ReviewGroup) {
        if reviewedGroupIDs.insert(group.id).inserted {
            scheduleEstimatedDiscardSizeRefresh()
            scheduleSessionSave()
        }
    }

    func shouldAcceptHoverHighlight() -> Bool {
        guard ignoreHoverUntilMouseMoves else { return true }
        let currentMouseLocation = NSEvent.mouseLocation
        let dx = currentMouseLocation.x - mouseLocationAtKeyboardNavigation.x
        let dy = currentMouseLocation.y - mouseLocationAtKeyboardNavigation.y
        let distanceSquared = (dx * dx) + (dy * dy)
        guard distanceSquared > 4.0 else { return false }
        ignoreHoverUntilMouseMoves = false
        mouseLocationAtKeyboardNavigation = currentMouseLocation
        return true
    }

    func highlightPreviousAssetInCurrentGroup() {
        guard let group = currentGroup else { return }
        beginKeyboardNavigationSession()
        moveHighlight(in: group, delta: -1)
    }

    func highlightNextAssetInCurrentGroup() {
        guard let group = currentGroup else { return }
        beginKeyboardNavigationSession()
        moveHighlight(in: group, delta: 1)
    }

    func toggleHighlightedAssetInCurrentGroup() {
        guard let group = currentGroup else { return }
        ensureHighlightedAsset(in: group)
        guard let highlighted = highlightedAssetID(in: group) else { return }
        toggleKeep(assetID: highlighted, in: group)
    }

    func queueHighlightedAssetForEditingInCurrentGroup() {
        guard !isQueuingForEdit, let group = currentGroup else { return }
        ensureHighlightedAsset(in: group)
        guard let highlighted = highlightedAssetID(in: group) else { return }

        var decisions = decisions(for: group)
        decisions.explicitDiscardIDs.remove(highlighted)
        decisions.explicitKeepIDs.insert(highlighted)
        reviewDecisionsByGroup[group.id] = decisions

        if queuedForEditItemIDs.contains(highlighted) {
            queuedForEditItemIDs.remove(highlighted)
            switch selectedSourceKind {
            case .photos:
                publishEditQueueMessage("Removed selected item from the Photos edit queue.")
            case .folder:
                publishEditQueueMessage("Removed selected item from the folder edit queue.")
            }
        } else {
            queuedForEditItemIDs.insert(highlighted)
            switch selectedSourceKind {
            case .photos:
                publishEditQueueMessage("Selected item will queue to \"\(editAlbumTitle)\" when you commit.")
            case .folder:
                publishEditQueueMessage("Selected item will move to \"\(editAlbumTitle)\" when you commit.")
            }
        }
        scheduleSessionSave()

        scheduleEstimatedDiscardSizeRefresh()
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

        guard let item = itemLookup[assetID] else {
            return nil
        }

        let thumbnail: NSImage?
        switch item.source {
        case .photoAsset:
            guard let asset = photoAssetLookup[assetID] else { return nil }
            thumbnail = await libraryService.requestThumbnail(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: contentMode,
                deliveryMode: deliveryMode
            )
        case .file:
            thumbnail = await folderLibraryService.thumbnail(for: item, maxPixel: side)
        }

        if let thumbnail {
            thumbnailCache.setObject(thumbnail, forKey: cacheKey)
            thumbnailKeysByItemID[assetID, default: []].insert(cacheKey as String)
        }

        return thumbnail
    }

    func isVideo(assetID: String) -> Bool {
        itemLookup[assetID]?.isVideo == true
    }

    func previewPlayerResult(for assetID: String) async -> VideoPreviewLoadResult {
        guard let item = itemLookup[assetID], item.isVideo else {
            return .unavailable("The selected item is not a video.")
        }

        switch item.source {
        case .photoAsset:
            guard let asset = photoAssetLookup[assetID], asset.mediaType == .video else {
                return .unavailable("The selected video is no longer available in Photos.")
            }

            switch await libraryService.requestPlayerItem(for: asset) {
            case .success(let playerItemBox):
                let player = AVPlayer(playerItem: playerItemBox.item)
                player.actionAtItemEnd = .pause
                return .ready(player)

            case .unavailable(let message):
                let avAsset: AVAsset
                if let cached = videoAssetCache[assetID] {
                    avAsset = cached
                } else {
                    guard let avAssetBox = await libraryService.requestAVAsset(for: asset) else {
                        return .unavailable(message)
                    }
                    avAsset = avAssetBox.asset
                    videoAssetCache[assetID] = avAsset
                }

                let player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                player.actionAtItemEnd = .pause
                return .ready(player)
            }

        case .file:
            guard let player = folderLibraryService.previewPlayer(for: item) else {
                return .unavailable("The selected video could not be loaded.")
            }
            return .ready(player)
        }
    }

    func mediaBadges(for assetID: String) -> [String] {
        itemLookup[assetID]?.badgeLabels ?? []
    }

    func confirmQueueMarkedAssetsForManualDelete() {
        guard discardCountTotal > 0 || keepCountTotal > 0 || !queuedForEditItemIDs.isEmpty else {
            return
        }

        if selectedSourceKind == .folder {
            folderCommitPlan = buildFolderCommitPlan()
        }

        deletionArmed = false
        scheduleEstimatedDiscardSizeRefresh()
        showDeleteConfirmation = true
    }

    func queueMarkedAssetsForManualDelete() {
        switch selectedSourceKind {
        case .photos:
            queueMarkedPhotos()
        case .folder:
            queueMarkedFolderItems()
        }
    }

    func folderCommitCount(for destination: FolderCommitDestination) -> Int {
        folderCommitPlan?.count(for: destination) ?? 0
    }

    func folderCommitSamples(for destination: FolderCommitDestination) -> [String] {
        folderCommitPlan?.samples(for: destination) ?? []
    }

    func folderRemainingSampleCount(for destination: FolderCommitDestination) -> Int {
        let count = folderCommitCount(for: destination)
        let sampleCount = folderCommitSamples(for: destination).count
        return max(0, count - sampleCount)
    }

    func folderDestinationPath(for destination: FolderCommitDestination) -> String {
        guard let sourceFolderURL = try? folderLibraryService.resolveValidatedFolderURL(for: folderSelection) else {
            return "Unavailable"
        }
        return folderCommitService.destinationPaths(for: sourceFolderURL).url(for: destination).path
    }

    func canRevealItemInFinder(assetID: String) -> Bool {
        fileURL(for: assetID) != nil
    }

    private var explicitDiscardItemIDs: [String] {
        var ids: Set<String> = []
        for group in groups where reviewedGroupIDs.contains(group.id) {
            ids.formUnion(commitDiscardIDs(for: group))
        }
        return ids.sorted()
    }

    private var explicitKeepItemIDs: [String] {
        var ids: Set<String> = []
        for group in groups where reviewedGroupIDs.contains(group.id) {
            ids.formUnion(commitKeepIDs(for: group))
        }
        return ids.sorted()
    }

    private var implicitKeepItemIDs: [String] {
        var ids: Set<String> = []
        guard reviewMode == .keepFirst else { return [] }
        for group in groups where reviewedGroupIDs.contains(group.id) {
            ids.formUnion(implicitKeepIDs(for: group))
        }
        return ids.sorted()
    }

    private var highlightedFileURL: URL? {
        guard let group = currentGroup, let itemID = highlightedAssetID(in: group) else {
            return nil
        }
        return fileURL(for: itemID)
    }

    private var resolvedSourceFolderURL: URL? {
        try? folderLibraryService.resolveValidatedFolderURL(for: folderSelection)
    }

    private func fileURL(for itemID: String) -> URL? {
        guard let path = itemLookup[itemID]?.absolutePath else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func applyFolderSelection(_ selection: FolderSelection, statusMessage: String) {
        folderSelection = selection
        selectedSourceKind = .folder
        rememberRecentFolder(selection)
        resetCurrentSessionState(clearMessages: true)
        scanStatusMessage = statusMessage
    }

    private func rememberRecentFolder(_ selection: FolderSelection) {
        var updated = recentFolders.filter { $0.resolvedPath != selection.resolvedPath }
        updated.insert(selection, at: 0)
        if updated.count > recentFolderLimit {
            updated = Array(updated.prefix(recentFolderLimit))
        }
        recentFolders = updated
    }

    private func ensureAuthorizationForScan() async -> Bool {
        if isAuthorized { return true }
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
        if isAuthorized { return true }
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

    private func buildScanSettings() -> ScanSettings {
        let (dateFrom, dateTo): (Date?, Date?) = {
            guard useDateRange else { return (nil, nil) }
            let startOfFrom = Calendar.current.startOfDay(for: rangeStartDate)
            let startOfTo = Calendar.current.startOfDay(for: rangeEndDate)
            let endOfTo = Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: startOfTo) ?? startOfTo
            return startOfFrom <= endOfTo ? (startOfFrom, endOfTo) : (endOfTo, startOfFrom)
        }()

        return ScanSettings(
            reviewMode: reviewMode,
            selectedSourceKind: selectedSourceKind,
            sourceMode: sourceMode,
            selectedAlbumID: selectedAlbumID,
            folderSelection: folderSelection,
            folderRecursiveScan: folderRecursiveScan,
            moveKeptItemsToKeepFolder: moveKeptItemsToKeepFolder,
            dateFrom: dateFrom,
            dateTo: dateTo,
            includeVideos: includeVideos,
            maxTimeGapSeconds: maxTimeGapSeconds,
            similarityDistanceThreshold: Float(fixedSimilarityDistanceThreshold)
        )
    }

    private func startScan(with settings: ScanSettings) {
        resetCurrentSessionState(clearMessages: false)
        errorMessage = nil
        pendingScanSettings = nil
        showLargeSelectionWarning = false
        isScanning = true
        scanProgress = 0
        scanStatusMessage = "Starting scan..."

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }

            var finishedSuccessfully = false
            do {
                let result = try await self.scanner.scan(settings: settings) { [weak self] progress in
                    self?.scanProgress = progress.fractionCompleted
                    self?.scanStatusMessage = progress.message
                }

                self.scannedAssetCount = result.scannedItemCount
                self.temporalClusterCount = result.temporalClusterCount
                self.skippedHiddenCount = result.skippedHiddenCount
                self.skippedUnsupportedCount = result.skippedUnsupportedCount
                self.skippedPackageCount = result.skippedPackageCount
                self.skippedSymlinkDirectoryCount = result.skippedSymlinkDirectoryCount
                self.itemLookup = result.itemLookup
                self.photoAssetLookup = result.photoAssetLookup
                self.groups = result.groups
                self.currentGroupIndex = 0
                self.initializeDefaultSelections()
                self.schedulePrefetchAndCacheMaintenance()
                self.scheduleEstimatedDiscardSizeRefresh()
                self.scheduleSessionSave()
                finishedSuccessfully = true

                if result.groups.isEmpty {
                    self.scanStatusMessage = "No similar groups found with current settings."
                } else {
                    self.scanStatusMessage = self.finishScanMessage(for: result)
                }
            } catch is CancellationError {
                self.scanStatusMessage = "Scan cancelled."
            } catch {
                self.errorMessage = error.localizedDescription
                self.scanStatusMessage = "Scan failed."
            }

            self.isScanning = false
            self.scanProgress = finishedSuccessfully ? max(self.scanProgress, 1.0) : min(self.scanProgress, 0.99)
            self.scanTask = nil
        }
    }

    private func finishScanMessage(for result: ScanResult) -> String {
        var parts = ["Found \(result.groups.count) review group(s)."]
        if selectedSourceKind == .folder {
            var skippedParts: [String] = []
            if result.skippedHiddenCount > 0 { skippedParts.append("hidden \(result.skippedHiddenCount)") }
            if result.skippedUnsupportedCount > 0 { skippedParts.append("unsupported \(result.skippedUnsupportedCount)") }
            if result.skippedPackageCount > 0 { skippedParts.append("packages \(result.skippedPackageCount)") }
            if result.skippedSymlinkDirectoryCount > 0 { skippedParts.append("symlinked folders \(result.skippedSymlinkDirectoryCount)") }
            if !skippedParts.isEmpty {
                parts.append("Skipped " + skippedParts.joined(separator: ", ") + ".")
            }
        }
        return parts.joined(separator: " ")
    }

    private func queueMarkedPhotos() {
        let plan = photoQueuePlan()
        guard !plan.discardIDs.isEmpty || !plan.keepIDs.isEmpty || !plan.editIDs.isEmpty else { return }

        errorMessage = nil
        deletionMessage = nil
        isDeleting = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isDeleting = false }

            do {
                guard await self.ensureAuthorizationForQueueing() else { return }

                let keepQueueResult = plan.keepIDs.isEmpty ? nil : try await self.libraryService.queueAssets(
                    withIdentifiers: Array(plan.keepIDs),
                    intoAlbumTitle: self.fullySortedAlbumTitle
                )
                let discardQueueResult = plan.discardIDs.isEmpty ? nil : try await self.libraryService.queueAssets(
                    withIdentifiers: Array(plan.discardIDs),
                    intoAlbumTitle: self.manualDeleteAlbumTitle
                )
                let editQueueResult = plan.editIDs.isEmpty ? nil : try await self.libraryService.queueAssets(
                    withIdentifiers: Array(plan.editIDs),
                    intoAlbumTitle: self.editAlbumTitle
                )

                let committedIDs = (keepQueueResult?.processedAssetIDs ?? [])
                    .union(discardQueueResult?.processedAssetIDs ?? [])
                    .union(editQueueResult?.processedAssetIDs ?? [])
                guard !committedIDs.isEmpty || keepQueueResult != nil || discardQueueResult != nil || editQueueResult != nil else {
                    self.errorMessage = "No marked items could be queued."
                    self.showDeleteConfirmation = false
                    self.deletionArmed = false
                    return
                }

                var completionParts: [String] = []
                if let keepQueueResult {
                    let keepLabel = self.reviewMode == .discardFirst ? "kept" : "explicit keep"
                    completionParts.append(
                        keepQueueResult.addedCount > 0
                        ? "Queued \(keepQueueResult.addedCount) \(keepLabel) item(s) to \"\(self.fullySortedAlbumTitle)\"."
                        : "All \(keepLabel) items were already in \"\(self.fullySortedAlbumTitle)\"."
                    )
                }
                if let discardQueueResult {
                    completionParts.append(
                        discardQueueResult.addedCount > 0
                        ? "Queued \(discardQueueResult.addedCount) marked item(s) to \"\(self.manualDeleteAlbumTitle)\"."
                        : "All marked items were already in \"\(self.manualDeleteAlbumTitle)\"."
                    )
                }
                if let editQueueResult {
                    completionParts.append(
                        editQueueResult.addedCount > 0
                        ? "Queued \(editQueueResult.addedCount) edit item(s) to \"\(self.editAlbumTitle)\"."
                        : "All edit items were already in \"\(self.editAlbumTitle)\"."
                    )
                }

                self.applyCommittedPhotoItems(
                    committedIDs: committedIDs,
                    completionMessage: completionParts.joined(separator: " "),
                    statusMessage: "Album queues updated."
                )
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func queueMarkedFolderItems() {
        guard let sourceFolderURL = try? folderLibraryService.resolveValidatedFolderURL(for: folderSelection) else {
            errorMessage = ReviewError.missingSourceFolder.localizedDescription
            return
        }

        let plan = buildFolderCommitPlan()
        folderCommitPlan = plan
        guard let plan, plan.totalMoveCount > 0 else {
            errorMessage = ReviewError.noReviewedItemsToCommit.localizedDescription
            return
        }

        errorMessage = nil
        deletionMessage = nil
        isDeleting = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isDeleting = false }

            do {
                let result = try await self.folderCommitService.execute(plan: plan, sourceFolderURL: sourceFolderURL)
                self.showDeleteConfirmation = false
                self.deletionArmed = false
                self.deletionMessage = self.folderCommitMessage(for: result)
                self.requestScan()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func buildFolderCommitPlan() -> FolderCommitPlan? {
        guard selectedSourceKind == .folder else { return nil }
        return folderCommitService.buildCommitPlan(
            itemLookup: itemLookup,
            groups: groups,
            reviewedGroupIDs: reviewedGroupIDs,
            reviewMode: reviewMode,
            reviewDecisionsByGroup: reviewDecisionsByGroup,
            queuedForEditItemIDs: queuedForEditItemIDs,
            moveKeptItemsToKeepFolder: moveKeptItemsToKeepFolder
        )
    }

    private func folderCommitMessage(for result: FolderCommitExecutionResult) -> String {
        if result.wasCancelled {
            return "Folder commit cancelled after processing \(result.processedCount) item(s)."
        }
        if result.hasIssues {
            return "Folder commit finished with issues. Moved \(result.totalMovedCount) item(s)."
        }
        return "Moved \(result.totalMovedCount) item(s) into sibling queue folders."
    }

    func photoQueuePlan() -> (keepIDs: Set<String>, discardIDs: Set<String>, editIDs: Set<String>) {
        var keepIDs: Set<String> = []
        var discardIDs: Set<String> = []
        var editIDs: Set<String> = []

        for group in groups where reviewedGroupIDs.contains(group.id) {
            let groupItemIDs = Set(group.itemIDs)
            let groupEditIDs = queuedForEditItemIDs.intersection(groupItemIDs)
            editIDs.formUnion(groupEditIDs)
            keepIDs.formUnion(commitKeepIDs(for: group).subtracting(groupEditIDs))
            discardIDs.formUnion(commitDiscardIDs(for: group).subtracting(groupEditIDs))
        }

        return (keepIDs, discardIDs, editIDs)
    }

    private func applyCommittedPhotoItems(
        committedIDs: Set<String>,
        completionMessage: String,
        statusMessage: String
    ) {
        guard !committedIDs.isEmpty else { return }

        let previousGroupID = currentGroup?.id
        let previousHighlightedItemID = currentGroup.flatMap { highlightedAssetID(in: $0) }
        let previousGroupIndex = currentGroupIndex
        let originalGroupIndexByID = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })

        var updatedGroups: [ReviewGroup] = []
        for group in groups {
            let remainingIDs = group.itemIDs.filter { !committedIDs.contains($0) }
            guard !remainingIDs.isEmpty else { continue }
            updatedGroups.append(
                ReviewGroup(id: group.id, itemIDs: remainingIDs, startDate: group.startDate, endDate: group.endDate)
            )
        }

        groups = updatedGroups
        let validGroupIDs = Set(updatedGroups.map(\.id))
        let validItemIDs = Set(updatedGroups.flatMap(\.itemIDs))

        reviewDecisionsByGroup = reviewDecisionsByGroup.reduce(into: [:]) { partial, entry in
            var decisions = entry.value
            decisions.explicitKeepIDs = decisions.explicitKeepIDs.intersection(validItemIDs)
            decisions.explicitDiscardIDs = decisions.explicitDiscardIDs.intersection(validItemIDs)
            if !decisions.explicitKeepIDs.isEmpty || !decisions.explicitDiscardIDs.isEmpty {
                partial[entry.key] = decisions
            }
        }
        highlightedItemByGroup = highlightedItemByGroup.reduce(into: [:]) { partial, entry in
            if validItemIDs.contains(entry.value) {
                partial[entry.key] = entry.value
            }
        }
        reviewedGroupIDs = reviewedGroupIDs.intersection(validGroupIDs)
        queuedForEditItemIDs = queuedForEditItemIDs.intersection(validItemIDs)
        itemLookup = itemLookup.filter { validItemIDs.contains($0.key) }
        photoAssetLookup = photoAssetLookup.filter { validItemIDs.contains($0.key) }
        videoAssetCache = videoAssetCache.filter { validItemIDs.contains($0.key) }

        if groups.isEmpty {
            currentGroupIndex = 0
            deletionMessage = "\(completionMessage) No groups remain in this session."
            scanStatusMessage = "\(statusMessage) Run a new scan when ready."
        } else if let restoredIndex = anchoredGroupIndex(
            preferredGroupID: previousGroupID,
            preferredItemID: previousHighlightedItemID,
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

        showDeleteConfirmation = false
        deletionArmed = false
        schedulePrefetchAndCacheMaintenance()
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    private func anchoredGroupIndex(
        preferredGroupID: UUID?,
        preferredItemID: String?,
        in groups: [ReviewGroup]
    ) -> Int? {
        if let preferredGroupID,
           let matchingIndex = groups.firstIndex(where: { $0.id == preferredGroupID }) {
            return matchingIndex
        }

        if let preferredItemID,
           let matchingIndex = groups.firstIndex(where: { $0.itemIDs.contains(preferredItemID) }) {
            return matchingIndex
        }

        return nil
    }

    private func nearestSurvivingGroupIndex(
        fallbackOriginalIndex: Int,
        in groups: [ReviewGroup],
        originalIndexByGroupID: [UUID: Int]
    ) -> Int {
        guard !groups.isEmpty else { return 0 }
        if let nextIndex = groups.enumerated().first(where: { index, group in
            (originalIndexByGroupID[group.id] ?? index) >= fallbackOriginalIndex
        })?.offset {
            return nextIndex
        }
        return max(0, groups.count - 1)
    }

    private func applyReviewModeChange(_ newMode: ReviewMode, resetSession: Bool) {
        reviewMode = newMode
        scheduleStoredScanPreferencesSave()

        if resetSession {
            resetCurrentSessionState(clearMessages: true)
            scanStatusMessage = "Review mode changed to \(newMode.title). Run a new scan to start fresh."
        }
    }

    private func decisions(for group: ReviewGroup) -> ReviewGroupDecisions {
        if let existing = reviewDecisionsByGroup[group.id] {
            return existing
        }
        let empty = ReviewGroupDecisions()
        reviewDecisionsByGroup[group.id] = empty
        return empty
    }

    private func effectiveReviewState(for itemID: String, in group: ReviewGroup) -> EffectiveReviewState {
        let decisions = decisions(for: group)

        if queuedForEditItemIDs.contains(itemID) {
            return .keep
        }

        switch reviewMode {
        case .discardFirst:
            return decisions.explicitKeepIDs.contains(itemID) ? .keep : .discard
        case .keepFirst:
            return decisions.explicitDiscardIDs.contains(itemID) ? .discard : .keep
        }
    }

    private func explicitKeepIDs(for group: ReviewGroup) -> Set<String> {
        let decisions = decisions(for: group)
        let validIDs = Set(group.itemIDs)
        return decisions.explicitKeepIDs.intersection(validIDs).union(queuedForEditItemIDs.intersection(validIDs))
    }

    private func explicitDiscardIDs(for group: ReviewGroup) -> Set<String> {
        let decisions = decisions(for: group)
        let validIDs = Set(group.itemIDs)
        return decisions.explicitDiscardIDs.intersection(validIDs).subtracting(queuedForEditItemIDs)
    }

    private func commitKeepIDs(for group: ReviewGroup) -> Set<String> {
        switch reviewMode {
        case .discardFirst:
            return Set(group.itemIDs.filter { effectiveReviewState(for: $0, in: group) == .keep })
        case .keepFirst:
            return explicitKeepIDs(for: group)
        }
    }

    private func commitDiscardIDs(for group: ReviewGroup) -> Set<String> {
        switch reviewMode {
        case .discardFirst:
            return Set(group.itemIDs.filter { effectiveReviewState(for: $0, in: group) == .discard })
        case .keepFirst:
            return explicitDiscardIDs(for: group)
        }
    }

    private func implicitKeepIDs(for group: ReviewGroup) -> Set<String> {
        guard reviewMode == .keepFirst else { return [] }
        let effectiveKeeps = Set(group.itemIDs.filter { effectiveReviewState(for: $0, in: group) == .keep })
        return effectiveKeeps.subtracting(commitKeepIDs(for: group))
    }

    private func initializeDefaultSelections() {
        for group in groups {
            reviewDecisionsByGroup[group.id] = ReviewGroupDecisions()
            highlightedItemByGroup[group.id] = group.itemIDs.first
        }
        reviewedGroupIDs = []
        queuedForEditItemIDs = []
        folderCommitPlan = nil
    }

    private func moveHighlight(in group: ReviewGroup, delta: Int) {
        ensureHighlightedAsset(in: group)
        guard let highlighted = highlightedAssetID(in: group),
              let currentIndex = group.itemIDs.firstIndex(of: highlighted) else {
            return
        }

        let targetIndex = max(0, min(group.itemIDs.count - 1, currentIndex + delta))
        let targetItemID = group.itemIDs[targetIndex]
        if highlightedItemByGroup[group.id] != targetItemID {
            highlightedItemByGroup[group.id] = targetItemID
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
            guard let self, !Task.isCancelled else { return }
            self.editQueueMessage = nil
        }
    }

    private func schedulePrefetchAndCacheMaintenance() {
        trimCachesForCurrentWindow()

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            await self.prefetchNextGroupItems()
        }
    }

    private func trimCachesForCurrentWindow() {
        guard !groups.isEmpty else {
            thumbnailCache.removeAllObjects()
            thumbnailKeysByItemID = [:]
            videoAssetCache = [:]
            return
        }

        let lowerBound = max(0, currentGroupIndex - 10)
        let upperBound = min(groups.count - 1, currentGroupIndex + 2)
        var keepItemIDs: Set<String> = []
        for index in lowerBound...upperBound {
            keepItemIDs.formUnion(groups[index].itemIDs)
        }

        let removableItemIDs = thumbnailKeysByItemID.keys.filter { !keepItemIDs.contains($0) }
        for itemID in removableItemIDs {
            if let keySet = thumbnailKeysByItemID[itemID] {
                for key in keySet {
                    thumbnailCache.removeObject(forKey: NSString(string: key))
                }
            }
            thumbnailKeysByItemID.removeValue(forKey: itemID)
        }

        videoAssetCache = videoAssetCache.filter { keepItemIDs.contains($0.key) }
    }

    private func prefetchNextGroupItems() async {
        let nextIndex = currentGroupIndex + 1
        guard groups.indices.contains(nextIndex) else { return }
        let nextItemIDs = Array(groups[nextIndex].itemIDs.prefix(12))
        guard !nextItemIDs.isEmpty else { return }

        for itemID in nextItemIDs {
            if Task.isCancelled { return }
            _ = await thumbnail(for: itemID, side: 320, contentMode: .aspectFill, deliveryMode: .opportunistic)
            if Task.isCancelled { return }
            _ = await thumbnail(for: itemID, side: 320, contentMode: .aspectFill, deliveryMode: .highQualityFormat)
        }

        if let firstID = nextItemIDs.first {
            if Task.isCancelled { return }
            _ = await thumbnail(for: firstID, side: 900, contentMode: .aspectFit, deliveryMode: .opportunistic)
            if Task.isCancelled { return }
            _ = await thumbnail(for: firstID, side: 2_000, contentMode: .aspectFit, deliveryMode: .highQualityFormat)
        }
    }

    private var persistedReviewSessionURL: URL {
        AppPaths.reviewSessionURL(bundleIdentifier: currentBundleIdentifier)
    }

    private var currentBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? currentBundleIdentifierFallback
    }

    private func migrateLegacyPersistenceIfNeeded() {
        let currentURL = persistedReviewSessionURL
        if !FileManager.default.fileExists(atPath: currentURL.path) {
            for url in [
                AppPaths.legacyReviewSessionURL(bundleIdentifier: currentBundleIdentifier),
                AppPaths.reviewSessionURL(bundleIdentifier: legacyBundleIdentifier),
                AppPaths.legacyReviewSessionURL(bundleIdentifier: legacyBundleIdentifier)
            ] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: url, to: currentURL)
                break
            }
        }
    }

    private func restoreReviewSessionIfAvailable() async {
        guard !hasAttemptedSessionRestore else { return }

        let url = persistedReviewSessionURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = try? Data(contentsOf: url),
            let stored = try? decoder.decode(StoredReviewSession.self, from: data)
        else {
            return
        }

        if stored.selectedSourceKind == .photos && !isAuthorized {
            return
        }

        hasAttemptedSessionRestore = true
        applyStoredScanControls(stored)

        switch stored.selectedSourceKind {
        case .photos:
            let requestedIDs = Array(Set(stored.groups.flatMap(\.itemIDs)))
            let assets = libraryService.fetchAssetsByLocalIdentifier(requestedIDs)
            let (items, assetsByID) = libraryService.makeReviewItems(from: Array(assets.values))
            let restored = sanitizedReviewSession(from: stored, availableItems: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }))
            guard !restored.groups.isEmpty else {
                clearPersistedReviewSession()
                return
            }
            itemLookup = Dictionary(uniqueKeysWithValues: restored.items.map { ($0.id, $0) })
            photoAssetLookup = assetsByID
            groups = restored.groups
            reviewMode = restored.reviewMode
            reviewDecisionsByGroup = restored.reviewDecisionsByGroup
            highlightedItemByGroup = restored.highlightedItemByGroup
            reviewedGroupIDs = restored.reviewedGroupIDs
            queuedForEditItemIDs = restored.queuedForEditItemIDs
            scannedAssetCount = restored.scannedItemCount
            temporalClusterCount = restored.temporalClusterCount

        case .folder:
            let availableItems = folderLibraryService.existingItems(from: stored.items)
            let restored = sanitizedReviewSession(from: stored, availableItems: Dictionary(uniqueKeysWithValues: availableItems.map { ($0.id, $0) }))
            guard !restored.groups.isEmpty else {
                clearPersistedReviewSession()
                return
            }
            itemLookup = Dictionary(uniqueKeysWithValues: restored.items.map { ($0.id, $0) })
            photoAssetLookup = [:]
            groups = restored.groups
            reviewMode = restored.reviewMode
            reviewDecisionsByGroup = restored.reviewDecisionsByGroup
            highlightedItemByGroup = restored.highlightedItemByGroup
            reviewedGroupIDs = restored.reviewedGroupIDs
            queuedForEditItemIDs = restored.queuedForEditItemIDs
            scannedAssetCount = restored.scannedItemCount
            temporalClusterCount = restored.temporalClusterCount
            folderCommitPlan = buildFolderCommitPlan()
        }

        currentGroupIndex = anchoredGroupIndex(
            preferredGroupID: stored.currentGroupID,
            preferredItemID: stored.currentHighlightedItemID,
            in: groups
        ) ?? min(max(0, stored.currentGroupIndex), max(0, groups.count - 1))

        deletionArmed = false
        scanProgress = 0
        isScanning = false
        scanStatusMessage = "Restored previous review session (\(groups.count) groups)."
        schedulePrefetchAndCacheMaintenance()
        scheduleEstimatedDiscardSizeRefresh()
    }

    private func applyStoredScanControls(_ stored: StoredReviewSession) {
        reviewMode = stored.reviewMode
        selectedSourceKind = stored.selectedSourceKind
        sourceMode = stored.sourceMode
        selectedAlbumID = stored.selectedAlbumID
        folderSelection = stored.folderSelection
        folderRecursiveScan = stored.folderRecursiveScan
        moveKeptItemsToKeepFolder = stored.moveKeptItemsToKeepFolder
        useDateRange = stored.useDateRange
        rangeStartDate = stored.rangeStartDate
        rangeEndDate = stored.rangeEndDate
        includeVideos = stored.includeVideos
        autoplayPreviewVideos = stored.autoplayPreviewVideos
        maxTimeGapSeconds = stored.maxTimeGapSeconds
        maxAssetsToScan = stored.scannedItemCount
    }

    private func sanitizedReviewSession(
        from stored: StoredReviewSession,
        availableItems: [String: ReviewItem]
    ) -> StoredReviewSession {
        var validGroups: [ReviewGroup] = []
        var validReviewDecisions: [UUID: ReviewGroupDecisions] = [:]
        var validHighlights: [UUID: String] = [:]

        for group in stored.groups {
            let filteredIDs = group.itemIDs.filter { availableItems[$0] != nil }
            guard !filteredIDs.isEmpty else { continue }
            let validGroup = ReviewGroup(id: group.id, itemIDs: filteredIDs, startDate: group.startDate, endDate: group.endDate)
            validGroups.append(validGroup)

            let allowed = Set(filteredIDs)
            var decisions = stored.reviewDecisionsByGroup[group.id] ?? ReviewGroupDecisions()
            decisions.explicitKeepIDs = decisions.explicitKeepIDs.intersection(allowed)
            decisions.explicitDiscardIDs = decisions.explicitDiscardIDs.intersection(allowed)
            validReviewDecisions[group.id] = decisions
            validHighlights[group.id] = stored.highlightedItemByGroup[group.id].flatMap { allowed.contains($0) ? $0 : nil } ?? filteredIDs.first
        }

        let validGroupIDs = Set(validGroups.map(\.id))
        let validItemIDs = Set(validGroups.flatMap(\.itemIDs))

        return StoredReviewSession(
            items: availableItems.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            groups: validGroups,
            currentGroupIndex: min(max(0, stored.currentGroupIndex), max(0, validGroups.count - 1)),
            currentGroupID: stored.currentGroupID.flatMap { validGroupIDs.contains($0) ? $0 : nil },
            currentHighlightedItemID: stored.currentHighlightedItemID.flatMap { validItemIDs.contains($0) ? $0 : nil },
            reviewMode: stored.reviewMode,
            reviewDecisionsByGroup: validReviewDecisions,
            highlightedItemByGroup: validHighlights,
            reviewedGroupIDs: stored.reviewedGroupIDs.intersection(validGroupIDs),
            queuedForEditItemIDs: stored.queuedForEditItemIDs.intersection(validItemIDs),
            scannedItemCount: max(stored.scannedItemCount, validItemIDs.count),
            temporalClusterCount: max(0, stored.temporalClusterCount),
            selectedSourceKind: stored.selectedSourceKind,
            sourceMode: stored.sourceMode,
            selectedAlbumID: stored.selectedAlbumID,
            folderSelection: stored.folderSelection,
            folderRecursiveScan: stored.folderRecursiveScan,
            moveKeptItemsToKeepFolder: stored.moveKeptItemsToKeepFolder,
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
        guard !groups.isEmpty else { return nil }

        var normalizedReviewDecisions: [UUID: ReviewGroupDecisions] = [:]
        var normalizedHighlights: [UUID: String] = [:]
        for group in groups {
            let validIDs = Set(group.itemIDs)
            var decisions = reviewDecisionsByGroup[group.id] ?? ReviewGroupDecisions()
            decisions.explicitKeepIDs = decisions.explicitKeepIDs.intersection(validIDs)
            decisions.explicitDiscardIDs = decisions.explicitDiscardIDs.intersection(validIDs)
            normalizedReviewDecisions[group.id] = decisions
            normalizedHighlights[group.id] = highlightedItemByGroup[group.id].flatMap { validIDs.contains($0) ? $0 : nil } ?? group.itemIDs.first
        }

        return StoredReviewSession(
            items: itemLookup.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            groups: groups,
            currentGroupIndex: currentGroupIndex,
            currentGroupID: currentGroup?.id,
            currentHighlightedItemID: currentGroup.flatMap { highlightedAssetID(in: $0) },
            reviewMode: reviewMode,
            reviewDecisionsByGroup: normalizedReviewDecisions,
            highlightedItemByGroup: normalizedHighlights,
            reviewedGroupIDs: reviewedGroupIDs,
            queuedForEditItemIDs: queuedForEditItemIDs,
            scannedItemCount: scannedAssetCount,
            temporalClusterCount: temporalClusterCount,
            selectedSourceKind: selectedSourceKind,
            sourceMode: sourceMode,
            selectedAlbumID: selectedAlbumID,
            folderSelection: folderSelection,
            folderRecursiveScan: folderRecursiveScan,
            moveKeptItemsToKeepFolder: moveKeptItemsToKeepFolder,
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
        guard !isScanning else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistReviewSessionNow()
        }
    }

    private func persistReviewSessionNow() {
        guard let snapshot = makeStoredReviewSession() else {
            clearPersistedReviewSession()
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let directoryURL = persistedReviewSessionURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: persistedReviewSessionURL, options: [.atomic])
    }

    private func clearPersistedReviewSession() {
        if FileManager.default.fileExists(atPath: persistedReviewSessionURL.path) {
            try? FileManager.default.removeItem(at: persistedReviewSessionURL)
        }
    }

    private func scheduleEstimatedDiscardSizeRefresh() {
        let ids = explicitDiscardItemIDs
        guard !ids.isEmpty else {
            sizeEstimateTask?.cancel()
            isEstimatingDiscardBytes = false
            estimatedDiscardBytes = 0
            return
        }

        sizeEstimateTask?.cancel()
        isEstimatingDiscardBytes = true
        let items = itemLookup
        let photoService = libraryService
        let photoLookup = photoAssetLookup

        sizeEstimateTask = Task { [weak self] in
            let total = await Task.detached(priority: .utility) { () -> Int64 in
                ids.reduce(into: Int64(0)) { partial, itemID in
                    if let cached = items[itemID]?.byteSize, cached > 0 {
                        partial += cached
                    } else if let asset = photoLookup[itemID], let measured = photoService.estimatedByteSize(for: asset) {
                        partial += measured
                    }
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.estimatedDiscardBytes = total
            self.isEstimatingDiscardBytes = false
        }
    }

    private func loadStoredScanPreferences() {
        guard let stored = scanPreferencesStore.load() else { return }
        reviewMode = stored.reviewMode
        selectedSourceKind = stored.selectedSourceKind
        sourceMode = stored.sourceMode
        selectedAlbumID = stored.selectedAlbumID
        folderSelection = stored.folderSelection
        recentFolders = stored.recentFolders
        folderRecursiveScan = stored.folderRecursiveScan
        moveKeptItemsToKeepFolder = stored.moveKeptItemsToKeepFolder
        useDateRange = stored.useDateRange
        rangeStartDate = stored.rangeStartDate
        rangeEndDate = stored.rangeEndDate
        includeVideos = stored.includeVideos
        autoplayPreviewVideos = stored.autoplayPreviewVideos
        maxTimeGapSeconds = stored.maxTimeGapSeconds
        maxAssetsToScan = stored.maxAssetsToScan
    }

    private func scheduleStoredScanPreferencesSave() {
        scanPreferencesSaveTask?.cancel()
        scanPreferencesSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistStoredScanPreferences()
        }
    }

    private func persistStoredScanPreferences() {
        scanPreferencesStore.save(
            StoredScanPreferences(
                reviewMode: reviewMode,
                selectedSourceKind: selectedSourceKind,
                sourceMode: sourceMode,
                selectedAlbumID: selectedAlbumID,
                folderSelection: folderSelection,
                recentFolders: recentFolders,
                folderRecursiveScan: folderRecursiveScan,
                moveKeptItemsToKeepFolder: moveKeptItemsToKeepFolder,
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

    private func resetCurrentSessionState(clearMessages: Bool) {
        deletionArmed = false
        showDeleteConfirmation = false
        pendingScanSettings = nil
        folderCommitPlan = nil
        groups = []
        reviewDecisionsByGroup = [:]
        highlightedItemByGroup = [:]
        reviewedGroupIDs = []
        queuedForEditItemIDs = []
        currentGroupIndex = 0
        itemLookup = [:]
        photoAssetLookup = [:]
        skippedHiddenCount = 0
        skippedUnsupportedCount = 0
        skippedPackageCount = 0
        skippedSymlinkDirectoryCount = 0
        estimatedDiscardBytes = 0
        isEstimatingDiscardBytes = false
        thumbnailCache.removeAllObjects()
        thumbnailKeysByItemID = [:]
        videoAssetCache = [:]
        prefetchTask?.cancel()
        sessionSaveTask?.cancel()
        sizeEstimateTask?.cancel()
        clearPersistedReviewSession()

        if clearMessages {
            deletionMessage = nil
            editQueueMessage = nil
            errorMessage = nil
        }
    }
}
