import AppKit
import AVFoundation
import CryptoKit
import Foundation
@preconcurrency import Photos
import PhotosSortCore

@MainActor
final class ReviewViewModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    private struct FolderFileIdentity: Equatable {
        var deviceNumber: UInt64
        var inodeNumber: UInt64

        init?(item: ReviewItem) {
            guard let deviceNumber = item.fileDeviceNumber,
                  let inodeNumber = item.fileInodeNumber
            else { return nil }
            self.deviceNumber = deviceNumber
            self.inodeNumber = inodeNumber
        }

        func matches(_ item: ReviewItem) -> Bool {
            item.fileDeviceNumber == deviceNumber && item.fileInodeNumber == inodeNumber
        }
    }

    private struct FolderReviewStateSnapshot {
        var sourceKey: String
        var groupingFingerprint: String
        var reviewMode: ReviewMode
        var fileIdentityByItemID: [String: FolderFileIdentity]
        var explicitKeepIDs: Set<String>
        var explicitDiscardIDs: Set<String>
        var queuedForEditItemIDs: Set<String>
        var reviewedGroupMemberships: Set<Set<String>>
        var highlightedItemsByGroupMembership: [Set<String>: String]
        var focusedGroupMembership: Set<String>?
        var previousSession: StoredReviewSession?
    }

    enum VideoPreviewLoadResult {
        case ready(AVPlayer, retainedResource: AnyObject?)
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
        didSet { scheduleStoredScanPreferencesSave(); refreshGroupLimitForCurrentSource() }
    }
    @Published var sourceMode: PhotoSourceMode = .allPhotos {
        didSet { scheduleStoredScanPreferencesSave(); refreshGroupLimitForCurrentSource() }
    }
    @Published var selectedAlbumID: String? {
        didSet { scheduleStoredScanPreferencesSave(); refreshGroupLimitForCurrentSource() }
    }
    @Published var folderSelection: FolderSelection? {
        didSet { scheduleStoredScanPreferencesSave(); refreshGroupLimitForCurrentSource() }
    }
    @Published var recentFolders: [FolderSelection] = [] {
        didSet { scheduleStoredScanPreferencesSave() }
    }
    @Published var folderRecursiveScan = true {
        didSet { scheduleStoredScanPreferencesSave(); refreshGroupLimitForCurrentSource() }
    }
    @Published var moveKeptItemsToKeepFolder = false {
        didSet { scheduleStoredScanPreferencesSave() }
    }

    @Published var useDateRange = false {
        didSet { scheduleStoredScanPreferencesSave(); refreshGroupLimitForCurrentSource() }
    }
    @Published var rangeStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() {
        didSet { scheduleStoredScanPreferencesSave(); refreshGroupLimitForCurrentSource() }
    }
    @Published var rangeEndDate = Date() {
        didSet { scheduleStoredScanPreferencesSave(); refreshGroupLimitForCurrentSource() }
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
    @Published var groupLimitEnabled = false {
        didSet { groupLimit = min(max(groupLimit, 1), 10_000) }
    }
    @Published var groupLimit = 100 {
        didSet {
            let clamped = min(max(groupLimit, 1), 10_000)
            if groupLimit != clamped {
                groupLimit = clamped
                return
            }
            scheduleStoredScanPreferencesSave()
        }
    }
    @Published var showLargeSelectionWarning = false
    @Published var estimatedScanScopeCount = 0

    @Published var isScanning = false
    @Published private(set) var isPreparingScan = false
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
    @Published private(set) var pendingPhotoItems: [PendingReviewItem] = []
    @Published private(set) var photoLibraryNeedsRecheck = false
    @Published var showPhotoQueue = false
    @Published var showReviewModeResetConfirmation = false
    @Published var showSourceResetConfirmation = false
    @Published var showBatchRestartConfirmation = false
    @Published private(set) var batchRestartConfirmationMessage = "Starting over clears saved batch progress."

    @Published var showDeleteConfirmation = false
    @Published var isDeleting = false
    @Published private(set) var isRecheckingPhotoQueue = false
    @Published var deletionArmed = false
    @Published var deletionMessage: String?
    @Published var errorMessage: String?
    @Published var editQueueMessage: String?
    @Published private(set) var isQueuingForEdit = false
    @Published private(set) var estimatedDiscardBytes: Int64 = 0
    @Published private(set) var isEstimatingDiscardBytes = false
    @Published private(set) var folderCommitPlan: FolderCommitPlan?
    @Published private(set) var folderCommitProgress: FolderCommitExecutionProgress?
    @Published private(set) var isCancellingFolderCommit = false

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
    private var photoReviewStore: SQLiteReviewStore?
    private let usesUserPersistence: Bool
    private var persistenceSetupError: String?
    private var photoAlbumBindings: [DestinationRole: PHAssetCollection] = [:]
    private var photoAlbumTitles: [DestinationRole: String] = [:]
    private var currentPhotoScopeID: String?
    private var photoGroupSnapshotsByID: [UUID: ReviewGroupSnapshot] = [:]
    private var pendingPhotoByID: [String: PendingReviewItem] = [:]

    private var scanTask: Task<Void, Never>?
    private var scanRequestTask: Task<Void, Never>?
    private var folderCommitTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var ignoreHoverUntilMouseMoves = false
    private var mouseLocationAtKeyboardNavigation: CGPoint = .zero
    private var sessionSaveTask: Task<Void, Never>?
    private var scanPreferencesSaveTask: Task<Void, Never>?
    private var sizeEstimateTask: Task<Void, Never>?
    private var editQueueMessageTask: Task<Void, Never>?
    private var photoLibraryRefreshTask: Task<Void, Never>?
    private var photoLibraryRecheckDeferredByBusyWork = false
    private var photoLibraryChangeGeneration: UInt64 = 0
    private var didRegisterPhotoObserver = false
    private var hasAttemptedSessionRestore = false
    private var hasAttemptedLegacyPhotoMigration = false
    private var hasStoredScanPreferences = false
    private let editAlbumTitle = "Files to Edit"
    private let manualDeleteAlbumTitle = "Files to Manually Delete"
    private let fullySortedAlbumTitle = "Fully Sorted"
    private let fixedSimilarityDistanceThreshold: Double = 12.0
    private let recommendedScopeThreshold = 2_000
    private let recentFolderLimit = 6
    private let reviewSessionFileStoreOverride: ReviewSessionFileStore?
    private let currentBundleIdentifierFallback = "com.sidelarklabs.photoslibrarysorthelper"
    private let previousBundleIdentifier = "com.jkfisher.photoslibrarysorthelper"
    private let legacyBundleIdentifier = "com.jkfisher.photosorthelper"
    private static let photoLibraryKey = "system-photo-library"
    private lazy var scanPreferencesStore = ScanPreferencesStore(
        bundleIdentifier: currentBundleIdentifier,
        legacyBundleIdentifier: previousBundleIdentifier,
        additionalLegacyBundleIdentifiers: [legacyBundleIdentifier]
    )
    private lazy var scanBatchStateStore = ScanBatchStateStore(
        fileURL: AppPaths.scanBatchStateURL(bundleIdentifier: currentBundleIdentifier)
    )
    private var batchCheckpoint: ScanBatchCheckpoint?
    private var pendingBatchRestartSettings: ScanSettings?
    private var pendingScanSettings: ScanSettings?
    private var pendingReviewMode: ReviewMode?
    private var pendingSourceKind: ReviewSourceKind?
    private var sessionGeneration = 0

    override convenience init() {
        self.init(photoReviewStore: nil, usesUserPersistence: true)
    }

    init(
        photoReviewStore: SQLiteReviewStore?,
        usesUserPersistence: Bool,
        reviewSessionFileStore: ReviewSessionFileStore? = nil
    ) {
        self.usesUserPersistence = usesUserPersistence
        self.reviewSessionFileStoreOverride = reviewSessionFileStore
        authorizationStatus = libraryService.currentAuthorizationStatus()
        if let photoReviewStore {
            self.photoReviewStore = photoReviewStore
        } else {
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? currentBundleIdentifierFallback
            if usesUserPersistence {
                do {
                    _ = try BundleIdentifierDataMigration(
                        currentBundleIdentifier: bundleIdentifier,
                        formerBundleIdentifiers: [previousBundleIdentifier, legacyBundleIdentifier]
                    ).migrateIfNeeded()
                } catch {
                    let message = "Local app data could not be prepared safely: \(error.localizedDescription)"
                    self.persistenceSetupError = message
                    self.errorMessage = message
                }
            }

            if persistenceSetupError == nil {
                do {
                    self.photoReviewStore = try SQLiteReviewStore(url: AppPaths.reviewDatabaseURL(
                        bundleIdentifier: bundleIdentifier
                    ))
                } catch {
                    let message = "Local Photos review storage could not be opened: \(error.localizedDescription)"
                    self.persistenceSetupError = message
                    self.errorMessage = message
                }
            }
        }
        super.init()
        if usesUserPersistence, persistenceSetupError == nil {
            migrateLegacyPersistenceIfNeeded()
            loadStoredScanPreferences()
            batchCheckpoint = scanBatchStateStore.load()
        }
        reloadPhotoPendingItems()
        refreshGroupLimitForCurrentSource()
    }

    deinit {
        scanTask?.cancel()
        scanRequestTask?.cancel()
        prefetchTask?.cancel()
        sessionSaveTask?.cancel()
        scanPreferencesSaveTask?.cancel()
        sizeEstimateTask?.cancel()
        editQueueMessageTask?.cancel()
        photoLibraryRefreshTask?.cancel()
        if didRegisterPhotoObserver { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    func bootstrap() async {
        guard persistenceSetupError == nil else { return }
        if isAuthorized {
            registerPhotoLibraryObserverIfNeeded()
            await refreshAlbums()
            recheckPhotoQueueIfBound()
        }
        await restoreReviewSessionIfAvailable()
    }

    func appDidBecomeActive() async {
        guard persistenceSetupError == nil else { return }
        authorizationStatus = libraryService.currentAuthorizationStatus()
        guard isAuthorized else { return }
        registerPhotoLibraryObserverIfNeeded()
        await refreshAlbums()
        recheckPhotoQueueIfBound()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.schedulePhotoLibraryRecheck()
        }
    }

    private func registerPhotoLibraryObserverIfNeeded() {
        guard isAuthorized, !didRegisterPhotoObserver else { return }
        PHPhotoLibrary.shared().register(self)
        didRegisterPhotoObserver = true
    }

    private func schedulePhotoLibraryRecheck() {
        photoLibraryChangeGeneration &+= 1
        photoLibraryNeedsRecheck = true
        guard isAuthorized else { return }
        guard !isDeleting, !isScanning, !isPreparingScan, !isRecheckingPhotoQueue else {
            photoLibraryRecheckDeferredByBusyWork = true
            return
        }
        photoLibraryRefreshTask?.cancel()
        photoLibraryRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            self.photoLibraryRefreshTask = nil
            guard !self.isDeleting,
                  !self.isScanning,
                  !self.isPreparingScan,
                  !self.isRecheckingPhotoQueue else {
                self.photoLibraryRecheckDeferredByBusyWork = true
                return
            }
            self.recheckPhotoQueueIfBound()
        }
    }

    private func resumePendingPhotoLibraryRecheckIfIdle() {
        guard photoLibraryNeedsRecheck,
              photoLibraryRecheckDeferredByBusyWork,
              !isDeleting,
              !isScanning,
              !isPreparingScan,
              !isRecheckingPhotoQueue else { return }
        photoLibraryRecheckDeferredByBusyWork = false
        schedulePhotoLibraryRecheck()
    }

    private func recheckPhotoQueueIfBound() {
        guard !isDeleting, !isScanning, !isPreparingScan, !isRecheckingPhotoQueue else {
            photoLibraryNeedsRecheck = true
            photoLibraryRecheckDeferredByBusyWork = true
            return
        }
        let observedGeneration = photoLibraryChangeGeneration
        guard isAuthorized, let photoReviewStore,
              let saved = try? photoReviewStore.albumBindings(libraryKey: Self.photoLibraryKey) else { return }
        let identifiers = Dictionary(uniqueKeysWithValues: saved.map { ($0.role, $0.localIdentifier) })
        guard Set(identifiers.keys) == Set(DestinationRole.allCases),
              Set(identifiers.values).count == DestinationRole.allCases.count else { return }
        do {
            try reconcileInterruptedPhotoCommits(using: identifiers)
            try reconcilePhotoPendingItems(using: identifiers)
            if photoLibraryChangeGeneration == observedGeneration {
                photoLibraryNeedsRecheck = false
                photoLibraryRecheckDeferredByBusyWork = false
            }
        } catch {
            deletionMessage = "Photos changed. The staged queue will be rechecked before scanning or commit."
        }
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
        selectedSourceKind == .photos ? currentGroup != nil : currentGroupIndex < groups.count - 1
    }

    var reviewedGroupCount: Int {
        if selectedSourceKind == .photos {
            return groups.filter { photoGroupSnapshotsByID[$0.id]?.state == .completed }.count
        }
        return reviewedGroupIDs.intersection(Set(groups.map(\.id))).count
    }

    var pendingPhotoCount: Int { pendingPhotoItems.count }
    var pendingPhotoConflictCount: Int { pendingPhotoItems.filter { $0.status == .conflict }.count }
    var pendingPhotoUnavailableCount: Int { pendingPhotoItems.filter { $0.status == .unavailable }.count }
    var photoCommitEligibleCount: Int { pendingPhotoItems.filter { $0.status == .pending }.count }

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
        if selectedSourceKind == .photos {
            return groups.reduce(0) { total, group in
                guard isGroupReviewed(group) else { return total }
                return total + group.itemIDs.filter { classification(assetID: $0, in: group).decision == .keep }.count
            }
        }
        return groups.reduce(0) { partial, group in
            guard reviewedGroupIDs.contains(group.id) else { return partial }
            return partial + group.itemIDs.filter { effectiveReviewState(for: $0, in: group) == .keep }.count
        }
    }

    var discardCountTotalReviewed: Int {
        if selectedSourceKind == .photos {
            return groups.reduce(0) { total, group in
                guard isGroupReviewed(group) else { return total }
                return total + group.itemIDs.filter { classification(assetID: $0, in: group).decision == .discard }.count
            }
        }
        return groups.reduce(0) { partial, group in
            guard reviewedGroupIDs.contains(group.id) else { return partial }
            return partial + group.itemIDs.filter { effectiveReviewState(for: $0, in: group) == .discard }.count
        }
    }

    var keepCountTotal: Int {
        if selectedSourceKind == .photos { return pendingPhotoItems.filter { $0.decision == .keep }.count }
        return explicitKeepItemIDs.count
    }

    var discardCountTotal: Int {
        if selectedSourceKind == .photos { return pendingPhotoItems.filter { $0.decision == .discard }.count }
        return explicitDiscardItemIDs.count
    }

    var implicitKeepCountTotal: Int {
        if selectedSourceKind == .photos {
            return pendingPhotoItems.filter { $0.decision == .keep && $0.origin == .completedDefault }.count
        }
        return implicitKeepItemIDs.count
    }

    var editQueueCountTotal: Int {
        if selectedSourceKind == .photos { return pendingPhotoItems.filter { $0.decision == .edit }.count }
        return groups.reduce(0) { partial, group in
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
            return "Commit All adds these locally staged classifications to their bound Photos albums. It never deletes photos."
        case (.photos, .keepFirst):
            return "Commit All adds these locally staged classifications to their bound Photos albums. It never deletes photos."
        case (.folder, .discardFirst):
            return "Review this preview before moving any files into sibling queue folders."
        case (.folder, .keepFirst):
            return "Review this preview before moving explicit keeps, discards, and edits into sibling queue folders."
        }
    }

    var summaryConfirmationText: String {
        switch (selectedSourceKind, reviewMode) {
        case (.photos, .discardFirst):
            return "I understand these choices will be added to their bound Photos albums. No photos will be deleted."
        case (.photos, .keepFirst):
            return "I understand these choices will be added to their bound Photos albums. No photos will be deleted."
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
        if selectedSourceKind == .photos {
            return "Staged choices are album classifications; no photos will be deleted."
        }
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
        !isDeleting && !isRecheckingPhotoQueue && !isScanning && !isPreparingScan && (
            hasPendingCommitActions
            || canFinalizeBatchWithoutActions
        )
    }

    var hasPendingCommitActions: Bool {
        switch selectedSourceKind {
        case .photos:
            return !pendingPhotoItems.isEmpty
        case .folder:
            return discardCountTotal > 0
                || keepCountTotal > 0
                || !queuedForEditItemIDs.isEmpty
                || (folderCommitPlan?.totalMoveCount ?? 0) > 0
        }
    }

    var canFinalizeBatchWithoutActions: Bool {
        guard let checkpoint = batchCheckpoint, !groups.isEmpty else { return false }
        return checkpoint.sourceKey == ScanBatcher.makeSourceKey(settings: buildScanSettings())
            && reviewedGroupCount == groups.count
            && !hasPendingCommitActions
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

    func requestSourceKindChange(_ newKind: ReviewSourceKind) {
        guard newKind != selectedSourceKind else { return }
        guard !isScanning, !isPreparingScan else { return }

        if hasActiveReviewSession {
            pendingSourceKind = newKind
            showSourceResetConfirmation = true
            return
        }

        applySourceKindChange(newKind)
    }

    func confirmSourceKindChange() {
        guard let pendingSourceKind else {
            showSourceResetConfirmation = false
            return
        }

        showSourceResetConfirmation = false
        applySourceKindChange(pendingSourceKind)
        self.pendingSourceKind = nil
    }

    func cancelSourceKindChange() {
        pendingSourceKind = nil
        showSourceResetConfirmation = false
    }

    func requestPhotoAccess() async {
        guard persistenceSetupError == nil else {
            errorMessage = persistenceSetupError
            return
        }
        authorizationStatus = libraryService.currentAuthorizationStatus()

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

    func refreshPhotoAuthorizationStatus() async {
        guard persistenceSetupError == nil else {
            errorMessage = persistenceSetupError
            return
        }
        authorizationStatus = libraryService.currentAuthorizationStatus()
        if isAuthorized {
            registerPhotoLibraryObserverIfNeeded()
            errorMessage = nil
            await refreshAlbums()
            await restoreReviewSessionIfAvailable()
            recheckPhotoQueueIfBound()
        } else {
            albums = []
            errorMessage = PhotoAuthorizationSupport.scanActionMessage(for: authorizationStatus)
        }
    }

    func openPhotoPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else {
            return
        }

        NSWorkspace.shared.open(url)
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
        guard !isScanning, !isPreparingScan else { return false }
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
        requestScan(preservingFolderReviewState: nil)
    }

    private func requestScan(preservingFolderReviewState snapshot: FolderReviewStateSnapshot?) {
        guard requirePersistenceReadyForScan() else { return }
        guard !isScanning, !isPreparingScan, !isDeleting, !isRecheckingPhotoQueue, scanRequestTask == nil else { return }
        let settings = buildScanSettings()
        if let checkpoint = batchCheckpoint,
           checkpoint.sourceKey == ScanBatcher.makeSourceKey(settings: settings) {
            pendingBatchRestartSettings = settings
            batchRestartConfirmationMessage = "Scanning from the beginning clears the saved batch position for this source."
            showBatchRestartConfirmation = true
            return
        }
        prepareScan(settings: settings, continuation: nil, preservingFolderReviewState: snapshot)
    }

    func requestNextBatch() {
        guard requirePersistenceReadyForScan() else { return }
        guard !isRecheckingPhotoQueue, canScanNextBatch, let checkpoint = batchCheckpoint else { return }
        let settings = buildScanSettings()
        guard checkpoint.groupingFingerprint == ScanBatcher.groupingFingerprint(settings: settings) else {
            pendingBatchRestartSettings = settings
            batchRestartConfirmationMessage = "Grouping settings changed after this batch series began. Start over to use the new settings."
            showBatchRestartConfirmation = true
            return
        }
        prepareScan(settings: settings, continuation: checkpoint)
    }

    var canScanNextBatch: Bool {
        guard groupLimitEnabled, let checkpoint = batchCheckpoint else { return false }
        return checkpoint.sourceKey == ScanBatcher.makeSourceKey(settings: buildScanSettings())
            && checkpoint.hasMore
            && checkpoint.readyForNextBatch
            && !isScanning
            && !isPreparingScan
    }

    private func requirePersistenceReadyForScan() -> Bool {
        guard let persistenceSetupError else { return true }
        errorMessage = persistenceSetupError
        return false
    }

    var primaryScanActionTitle: String {
        canScanNextBatch ? "Next \(groupLimit)" : "Scan from Beginning"
    }

    func confirmBatchRestart() {
        guard let settings = pendingBatchRestartSettings else {
            cancelBatchRestart()
            return
        }
        pendingBatchRestartSettings = nil
        showBatchRestartConfirmation = false
        batchCheckpoint = nil
        scanBatchStateStore.clear()
        prepareScan(settings: settings, continuation: nil)
    }

    func cancelBatchRestart() {
        pendingBatchRestartSettings = nil
        showBatchRestartConfirmation = false
    }

    private func prepareScan(
        settings: ScanSettings,
        continuation: ScanBatchCheckpoint?,
        preservingFolderReviewState snapshot: FolderReviewStateSnapshot? = nil
    ) {
        guard requirePersistenceReadyForScan() else { return }
        guard !isScanning, !isPreparingScan, !isDeleting, !isRecheckingPhotoQueue, scanRequestTask == nil else { return }

        let requestGeneration = sessionGeneration
        isPreparingScan = true
        scanStatusMessage = "Preparing scan..."
        scanRequestTask = Task { [weak self] in
            guard let self else { return }

            defer {
                if self.sessionGeneration == requestGeneration {
                    self.isPreparingScan = false
                    self.scanRequestTask = nil
                    self.resumePendingPhotoLibraryRecheckIfIdle()
                }
            }

            if self.selectedSourceKind == .photos {
                let canScan = await self.ensureAuthorizationForScan()
                guard canScan, !Task.isCancelled, self.sessionGeneration == requestGeneration else { return }
            } else if self.folderSelection == nil {
                self.errorMessage = ReviewError.missingSourceFolder.localizedDescription
                return
            }

            self.errorMessage = nil
            self.deletionMessage = nil
            self.editQueueMessage = nil
            self.showLargeSelectionWarning = false
            self.pendingScanSettings = nil

            if settings.selectedSourceKind == .photos, continuation == nil {
                do {
                    let estimatedCount = try self.libraryService.estimateAssetCount(settings: settings)
                    guard !Task.isCancelled, self.sessionGeneration == requestGeneration else { return }
                    self.estimatedScanScopeCount = estimatedCount
                    if estimatedCount > self.recommendedScopeThreshold {
                        self.pendingScanSettings = settings
                        self.showLargeSelectionWarning = true
                        self.isPreparingScan = false
                        self.scanRequestTask = nil
                        return
                    }
                } catch {
                    self.errorMessage = error.localizedDescription
                    return
                }
            }

            guard !Task.isCancelled, self.sessionGeneration == requestGeneration else { return }
            self.isPreparingScan = false
            self.scanRequestTask = nil
            self.startScan(
                with: settings,
                continuation: continuation,
                preservingFolderReviewState: snapshot
            )
        }
    }

    func continueScanAfterLargeScopeWarning() {
        guard !isScanning, let pendingScanSettings else {
            showLargeSelectionWarning = false
            return
        }

        showLargeSelectionWarning = false
        self.pendingScanSettings = nil
        startScan(with: pendingScanSettings, continuation: nil)
    }

    func stopScan() {
        if isPreparingScan {
            sessionGeneration &+= 1
            scanRequestTask?.cancel()
            scanRequestTask = nil
            isPreparingScan = false
            scanStatusMessage = "Scan cancelled."
            return
        }

        guard isScanning else { return }
        scanStatusMessage = "Stopping scan..."
        scanTask?.cancel()
    }

    func previousGroup() {
        guard currentGroupIndex > 0 else { return }
        currentGroupIndex -= 1
        cancelPrefetchAndMaintainCaches()
        scheduleSessionSave()
    }

    func nextGroup() {
        guard let group = currentGroup else { return }
        if selectedSourceKind == .photos {
            guard completePhotoGroup(group) else { return }
            currentGroupIndex = min(currentGroupIndex + 1, groups.count)
        } else {
            guard currentGroupIndex < groups.count - 1 else { return }
            currentGroupIndex += 1
        }
        schedulePrefetchAndCacheMaintenance()
        scheduleSessionSave()
    }

    func isGroupReviewed(_ group: ReviewGroup) -> Bool {
        if selectedSourceKind == .photos {
            return photoGroupSnapshot(for: group)?.state == .completed
        }
        return reviewedGroupIDs.contains(group.id)
    }

    func skipCurrentGroup() {
        guard selectedSourceKind == .photos, let group = currentGroup,
              let snapshot = photoGroupSnapshot(for: group),
              let photoReviewStore else { return }
        let nextIndex = min(currentGroupIndex + 1, groups.count)
        do {
            if snapshot.state == .completed {
                try photoReviewStore.save(position: makePhotoScopePosition(groupIndex: nextIndex))
            } else {
                try photoReviewStore.skipGroup(snapshot, nextPosition: makePhotoScopePosition(groupIndex: nextIndex))
            }
            refreshPhotoGroupSnapshots()
            currentGroupIndex = nextIndex
            schedulePrefetchAndCacheMaintenance()
        } catch {
            errorMessage = "This group could not be skipped safely: \(error.localizedDescription)"
        }
    }

    func classification(assetID: String, in group: ReviewGroup) -> (decision: ReviewDecision, origin: DecisionOrigin?) {
        if selectedSourceKind == .photos {
            if let row = pendingPhotoByID[assetID] {
                return (row.decision, row.origin)
            }
            return (reviewMode == .keepFirst ? .keep : .discard, nil)
        }
        if queuedForEditItemIDs.contains(assetID) { return (.edit, .explicit) }
        if isExplicitKeep(assetID: assetID, in: group) { return (.keep, .explicit) }
        if isExplicitDiscard(assetID: assetID, in: group) { return (.discard, .explicit) }
        let decision: ReviewDecision = isKept(assetID: assetID, in: group) ? .keep : .discard
        return (decision, reviewedGroupIDs.contains(group.id) ? .completedDefault : nil)
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
        persistPhotoChoices(for: group)
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func keepAll(in group: ReviewGroup) {
        var decisions = decisions(for: group)
        decisions.explicitKeepIDs = Set(group.itemIDs)
        decisions.explicitDiscardIDs = []
        reviewDecisionsByGroup[group.id] = decisions
        persistPhotoChoices(for: group)
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
        persistPhotoChoices(for: group)
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func isKept(assetID: String, in group: ReviewGroup) -> Bool {
        if selectedSourceKind == .photos { return classification(assetID: assetID, in: group).decision == .keep }
        return effectiveReviewState(for: assetID, in: group) == .keep
    }

    func isExplicitKeep(assetID: String, in group: ReviewGroup) -> Bool {
        if selectedSourceKind == .photos {
            let state = classification(assetID: assetID, in: group)
            return state.decision == .keep && state.origin == .explicit
        }
        return explicitKeepIDs(for: group).contains(assetID)
    }

    func isExplicitDiscard(assetID: String, in group: ReviewGroup) -> Bool {
        if selectedSourceKind == .photos {
            let state = classification(assetID: assetID, in: group)
            return state.decision == .discard && state.origin == .explicit
        }
        return explicitDiscardIDs(for: group).contains(assetID)
    }

    func isImplicitKeep(assetID: String, in group: ReviewGroup) -> Bool {
        if selectedSourceKind == .photos {
            let state = classification(assetID: assetID, in: group)
            return state.decision == .keep && state.origin != .explicit
        }
        return implicitKeepIDs(for: group).contains(assetID)
    }

    func isQueuedForEdit(assetID: String) -> Bool {
        if selectedSourceKind == .photos {
            return pendingPhotoByID[assetID]?.decision == .edit
        }
        return queuedForEditItemIDs.contains(assetID)
    }

    func reviewStatusLabel(assetID: String, in group: ReviewGroup) -> String {
        if selectedSourceKind == .photos {
            return classification(assetID: assetID, in: group).decision.rawValue.uppercased()
        }
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
        if selectedSourceKind == .photos {
            let state = classification(assetID: assetID, in: group)
            let label = state.decision.rawValue.capitalized
            switch state.origin {
            case .explicit: return "Explicit \(label)"
            case .completedDefault: return "Staged default \(label)"
            case nil: return "Default \(label), not staged"
            }
        }
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

        if selectedSourceKind == .photos {
            let current = classification(assetID: assetID, in: group).decision
            decisions.explicitKeepIDs.remove(assetID)
            decisions.explicitDiscardIDs.remove(assetID)
            queuedForEditItemIDs.remove(assetID)
            if current == .keep {
                decisions.explicitDiscardIDs.insert(assetID)
            } else {
                decisions.explicitKeepIDs.insert(assetID)
            }
            reviewDecisionsByGroup[group.id] = decisions
            persistPhotoChoices(for: group)
            scheduleEstimatedDiscardSizeRefresh()
            scheduleSessionSave()
            return
        }

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
        persistPhotoChoices(for: group)
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
        guard selectedSourceKind == .folder else { return }
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

        if isQueuedForEdit(assetID: highlighted) {
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
        persistPhotoChoices(for: group)
        scheduleSessionSave()

        scheduleEstimatedDiscardSizeRefresh()
    }

    func thumbnail(
        for assetID: String,
        side: CGFloat = 320,
        contentMode: PHImageContentMode = .aspectFill,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }

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
            thumbnail = await folderLibraryService.thumbnail(
                for: item,
                maxPixel: side,
                sourceFolderURL: resolvedSourceFolderURL
            )
        }

        guard !Task.isCancelled else { return nil }

        if let thumbnail {
            thumbnailCache.setObject(thumbnail, forKey: cacheKey)
            thumbnailKeysByItemID[assetID, default: []].insert(cacheKey as String)
        }

        return thumbnail
    }

    func isVideo(assetID: String) -> Bool {
        itemLookup[assetID]?.isVideo == true
    }

    func isPhotosAsset(assetID: String) -> Bool {
        guard let item = itemLookup[assetID] else { return false }
        if case .photoAsset = item.source { return true }
        return false
    }

    func isLivePhoto(assetID: String) -> Bool {
        guard isPhotosAsset(assetID: assetID), let asset = photoAsset(for: assetID) else { return false }
        return asset.mediaSubtypes.contains(.photoLive)
    }

    func itemTitle(assetID: String) -> String {
        itemLookup[assetID]?.displayName ?? "Photo"
    }

    func setReviewDecision(_ decision: ReviewDecision, assetID: String, in group: ReviewGroup) {
        guard selectedSourceKind == .photos, group.itemIDs.contains(assetID) else { return }
        var decisions = decisions(for: group)
        switch decision {
        case .keep:
            decisions.explicitKeepIDs.insert(assetID)
            decisions.explicitDiscardIDs.remove(assetID)
            queuedForEditItemIDs.remove(assetID)
        case .discard:
            decisions.explicitDiscardIDs.insert(assetID)
            decisions.explicitKeepIDs.remove(assetID)
            queuedForEditItemIDs.remove(assetID)
        case .edit:
            decisions.explicitKeepIDs.insert(assetID)
            decisions.explicitDiscardIDs.remove(assetID)
            queuedForEditItemIDs.insert(assetID)
        }
        reviewDecisionsByGroup[group.id] = decisions
        persistPhotoChoices(for: group)
        scheduleEstimatedDiscardSizeRefresh()
        scheduleSessionSave()
    }

    func previewPlayerResult(
        for assetID: String,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async -> VideoPreviewLoadResult {
        guard !Task.isCancelled else {
            return .unavailable("Video preview loading was cancelled.")
        }

        guard let item = itemLookup[assetID], item.isVideo else {
            return .unavailable("The selected item is not a video.")
        }

        switch item.source {
        case .photoAsset:
            guard let asset = photoAssetLookup[assetID], asset.mediaType == .video else {
                return .unavailable("The selected video is no longer available in Photos.")
            }

            let playerItemResult = await libraryService.requestPlayerItem(for: asset, progress: progress)
            guard !Task.isCancelled else {
                return .unavailable("Video preview loading was cancelled.")
            }

            switch playerItemResult {
            case .success(let playerItemBox):
                let player = AVPlayer(playerItem: playerItemBox.item)
                player.actionAtItemEnd = .pause
                return .ready(player, retainedResource: nil)

            case .unavailable(let message):
                let avAsset: AVAsset
                if let cached = videoAssetCache[assetID] {
                    avAsset = cached
                } else {
                    guard let avAssetBox = await libraryService.requestAVAsset(for: asset) else {
                        return .unavailable(message)
                    }
                    guard !Task.isCancelled else {
                        return .unavailable("Video preview loading was cancelled.")
                    }
                    avAsset = avAssetBox.asset
                    videoAssetCache[assetID] = avAsset
                }

                let player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                player.actionAtItemEnd = .pause
                return .ready(player, retainedResource: nil)
            }

        case .file:
            guard let preview = folderLibraryService.previewPlayer(
                for: item,
                sourceFolderURL: resolvedSourceFolderURL
            ) else {
                return .unavailable("The selected video could not be loaded.")
            }
            guard !Task.isCancelled else {
                return .unavailable("Video preview loading was cancelled.")
            }
            return .ready(preview.player, retainedResource: preview)
        }
    }

    func inspectionImage(
        for assetID: String,
        targetSize: CGSize,
        maximumSize: Bool,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> NSImage {
        guard let asset = photoAsset(for: assetID) else {
            throw ReviewError.albumNotFound
        }
        return try await libraryService.requestInspectionImage(
            for: asset,
            targetSize: targetSize,
            maximumSize: maximumSize,
            progress: progress
        )
    }

    func inspectionLivePhoto(
        for assetID: String,
        targetSize: CGSize,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> PHLivePhoto {
        guard let asset = photoAsset(for: assetID), asset.mediaSubtypes.contains(.photoLive) else {
            throw ReviewError.albumNotFound
        }
        return try await libraryService.requestInspectionLivePhoto(
            for: asset,
            targetSize: targetSize,
            progress: progress
        )
    }

    private func photoAsset(for assetID: String) -> PHAsset? {
        guard isPhotosAsset(assetID: assetID) else { return nil }
        if let asset = photoAssetLookup[assetID] { return asset }
        guard let asset = libraryService.fetchAssetsByLocalIdentifier([assetID])[assetID] else { return nil }
        photoAssetLookup[assetID] = asset
        return asset
    }

    func mediaBadges(for assetID: String) -> [String] {
        itemLookup[assetID]?.badgeLabels ?? []
    }

    func confirmQueueMarkedAssetsForManualDelete() {
        guard canOpenSummary else { return }

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
        invalidateActiveWork()
        folderSelection = selection
        selectedSourceKind = .folder
        rememberRecentFolder(selection)
        resetCurrentSessionState(clearMessages: true)
        scanStatusMessage = statusMessage
    }

    private func applySourceKindChange(_ newKind: ReviewSourceKind) {
        guard newKind != selectedSourceKind else { return }

        invalidateActiveWork()
        resetCurrentSessionState(clearMessages: true)
        selectedSourceKind = newKind
        scanStatusMessage = newKind == .photos
            ? "Photos library selected. Run a scan to load similar media groups."
            : (folderSelection == nil
                ? "Folder mode selected. Choose a source folder, then run a scan."
                : "Folder mode selected. Run a scan to load media from the selected folder.")
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
        if isAuthorized {
            registerPhotoLibraryObserverIfNeeded()
            return true
        }
        authorizationStatus = libraryService.currentAuthorizationStatus()
        if isAuthorized {
            registerPhotoLibraryObserverIfNeeded()
            await refreshAlbums()
            await restoreReviewSessionIfAvailable()
            return true
        }

        if authorizationStatus == .notDetermined {
            authorizationStatus = await libraryService.requestAuthorization()
            if isAuthorized {
                registerPhotoLibraryObserverIfNeeded()
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
            registerPhotoLibraryObserverIfNeeded()
            return true
        }
        authorizationStatus = libraryService.currentAuthorizationStatus()
        if isAuthorized {
            registerPhotoLibraryObserverIfNeeded()
            await refreshAlbums()
            return true
        }

        if authorizationStatus == .notDetermined {
            authorizationStatus = await libraryService.requestAuthorization()
            if isAuthorized {
                registerPhotoLibraryObserverIfNeeded()
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
            let range = PhotoDateRange(from: rangeStartDate, through: rangeEndDate)
            return (range.startInclusive, range.endExclusive)
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
            similarityDistanceThreshold: Float(fixedSimilarityDistanceThreshold),
            groupLimit: groupLimitEnabled ? groupLimit : nil
        )
    }

    private func refreshGroupLimitForCurrentSource() {
        guard !isScanning, !isPreparingScan else { return }
        guard let checkpoint = batchCheckpoint else {
            groupLimitEnabled = false
            return
        }
        groupLimitEnabled = checkpoint.sourceKey == ScanBatcher.makeSourceKey(settings: buildScanSettings())
    }

    private func startScan(
        with settings: ScanSettings,
        continuation: ScanBatchCheckpoint?,
        preservingFolderReviewState snapshot: FolderReviewStateSnapshot? = nil
    ) {
        sessionGeneration &+= 1
        let scanGeneration = sessionGeneration
        scanTask?.cancel()
        resetCurrentSessionState(
            clearMessages: false,
            clearPersistedFolderSession: snapshot == nil
        )
        errorMessage = nil
        pendingScanSettings = nil
        showLargeSelectionWarning = false
        isScanning = true
        scanProgress = 0
        scanStatusMessage = "Starting scan..."

        scanTask = Task { [weak self] in
            guard let self else { return }

            var finishedSuccessfully = false
            do {
                var excludedPhotoIDs: Set<String> = []
                if settings.selectedSourceKind == .photos {
                    let bindings = try await self.preparePhotoDestinationBindings(requireAll: true)
                    try self.reconcileInterruptedPhotoCommits(using: bindings)
                    try self.reconcilePhotoPendingItems(using: bindings)
                    excludedPhotoIDs = try self.photoExcludedAssetIDs(using: bindings)
                }
                let result = try await self.scanner.scan(
                    settings: settings,
                    continuation: continuation,
                    photosExcludedItemIDs: excludedPhotoIDs
                ) { [weak self] progress in
                    guard let self, self.sessionGeneration == scanGeneration else { return }
                    self.scanProgress = progress.fractionCompleted
                    self.scanStatusMessage = progress.message
                }

                guard self.sessionGeneration == scanGeneration else { return }

                self.scannedAssetCount = result.scannedItemCount
                self.temporalClusterCount = result.temporalClusterCount
                self.skippedHiddenCount = result.skippedHiddenCount
                self.skippedUnsupportedCount = result.skippedUnsupportedCount
                self.skippedPackageCount = result.skippedPackageCount
                self.skippedSymlinkDirectoryCount = result.skippedSymlinkDirectoryCount
                self.itemLookup = result.itemLookup
                self.photoAssetLookup = result.photoAssetLookup
                self.groups = result.groups
                if settings.selectedSourceKind == .photos {
                    try self.restorePhotoGroups(for: settings)
                } else {
                    self.currentPhotoScopeID = nil
                    self.photoGroupSnapshotsByID = [:]
                }
                if var checkpoint = result.continuation {
                    checkpoint.readyForNextBatch = false
                    self.batchCheckpoint = checkpoint
                    self.scanBatchStateStore.save(checkpoint)
                    self.groupLimitEnabled = true
                } else if continuation == nil,
                          self.batchCheckpoint?.sourceKey == ScanBatcher.makeSourceKey(settings: settings) {
                    self.batchCheckpoint = nil
                    self.scanBatchStateStore.clear()
                }
                if settings.selectedSourceKind == .folder { self.currentGroupIndex = 0 }
                if settings.selectedSourceKind == .folder {
                    self.initializeDefaultSelections()
                    if let snapshot {
                        self.restoreFolderReviewState(snapshot, for: settings)
                    }
                }
                self.schedulePrefetchAndCacheMaintenance()
                self.scheduleEstimatedDiscardSizeRefresh()
                self.scheduleSessionSave()
                finishedSuccessfully = true

                if result.groups.isEmpty {
                    self.scanStatusMessage = "No similar groups found with current settings."
                } else {
                    self.scanStatusMessage = self.finishScanMessage(for: result)
                }
            } catch let reviewError as ReviewError where
                snapshot != nil
                    && settings.selectedSourceKind == .folder
                    && reviewError == .emptySourceFolder
            {
                guard self.sessionGeneration == scanGeneration else { return }
                self.errorMessage = nil
                self.scanStatusMessage = "Folder scan complete. No reviewable media remain."
                finishedSuccessfully = true
            } catch is CancellationError {
                guard self.sessionGeneration == scanGeneration else { return }
                if let previousSession = snapshot?.previousSession {
                    self.restoreFolderSessionInMemory(from: previousSession)
                    self.scanStatusMessage = "Folder scan cancelled. Previous review restored."
                } else {
                    self.scanStatusMessage = "Scan cancelled."
                }
            } catch {
                guard self.sessionGeneration == scanGeneration else { return }
                self.errorMessage = error.localizedDescription
                if let previousSession = snapshot?.previousSession {
                    self.restoreFolderSessionInMemory(from: previousSession)
                    self.scanStatusMessage = "Folder scan failed. Previous review restored."
                } else {
                    self.scanStatusMessage = "Scan failed."
                }
            }

            guard self.sessionGeneration == scanGeneration else { return }
            self.isScanning = false
            self.scanProgress = finishedSuccessfully ? max(self.scanProgress, 1.0) : min(self.scanProgress, 0.99)
            self.scanTask = nil
            if finishedSuccessfully, snapshot != nil {
                self.persistReviewSessionNow()
            }
            if !finishedSuccessfully, snapshot?.previousSession != nil {
                self.schedulePrefetchAndCacheMaintenance()
                self.scheduleEstimatedDiscardSizeRefresh()
            }
            self.resumePendingPhotoLibraryRecheckIfIdle()
        }
    }

    private func finishScanMessage(for result: ScanResult) -> String {
        var parts: [String]
        if let checkpoint = result.continuation {
            parts = ["Batch \(checkpoint.batchNumber): \(result.groups.count) review group(s) ready."]
            parts.append(checkpoint.hasMore ? "More items remain." : "Source scan complete.")
        } else {
            parts = ["Found \(result.groups.count) review group(s)."]
        }
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
        guard !isRecheckingPhotoQueue, !isScanning, !isPreparingScan, !isDeleting else {
            errorMessage = "Wait for the current Photos operation to finish before committing."
            return
        }
        guard let store = photoReviewStore else {
            errorMessage = "The local Photos review queue is unavailable. No Photos changes were made."
            return
        }
        guard pendingPhotoItems.contains(where: { $0.status == .pending }) else {
            errorMessage = "There are no conflict-free staged choices to commit. Review the staged queue first."
            return
        }

        errorMessage = nil
        deletionMessage = nil
        isDeleting = true
        let photoChangeGenerationAtCommitStart = photoLibraryChangeGeneration

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isDeleting = false
                self.resumePendingPhotoLibraryRecheckIfIdle()
            }

            do {
                guard await self.ensureAuthorizationForQueueing() else { return }
                let bindings = try await self.preparePhotoDestinationBindings(requireAll: true)
                try self.reconcileInterruptedPhotoCommits(using: bindings)
                try self.reconcilePhotoPendingItems(using: bindings)
                guard self.pendingPhotoItems.contains(where: { $0.status == .pending }) else {
                    self.deletionMessage = "Photos was rechecked. Revise any conflicts or unavailable items in the staged queue."
                    return
                }
                self.photoAlbumBindings = Dictionary(uniqueKeysWithValues: bindings.compactMap { role, identifier in
                    self.libraryService.destinationAlbumCandidates()
                        .first(where: { $0.localIdentifier == identifier })
                        .map { (role, $0) }
                })
                let wasFullyReviewed = !self.groups.isEmpty && self.reviewedGroupCount == self.groups.count
                let attempt = try store.beginCommit(libraryKey: Self.photoLibraryKey)
                let outcomes = try await self.libraryService.addPhotos(from: attempt, albumLocalIdentifiers: bindings)
                try store.reconcile(attemptID: attempt.id, outcomes: outcomes)
                self.reloadPhotoPendingItems()
                if self.photoLibraryChangeGeneration == photoChangeGenerationAtCommitStart {
                    self.photoLibraryNeedsRecheck = false
                    self.photoLibraryRecheckDeferredByBusyWork = false
                } else {
                    self.photoLibraryNeedsRecheck = true
                    self.photoLibraryRecheckDeferredByBusyWork = true
                }

                let committedIDs = Set(outcomes.compactMap { id, outcome in
                    outcome == .verifiedCommitted ? id : nil
                })
                if !committedIDs.isEmpty {
                    let count = committedIDs.count
                    self.applyCommittedPhotoItems(
                        committedIDs: committedIDs,
                        completionMessage: "Committed \(count) staged photo choice(s).",
                        statusMessage: "Photos albums updated. Continuing review."
                    )
                    self.deletionMessage = "Committed \(count) staged photo choice(s)."
                }

                let unresolved = self.pendingPhotoItems.filter { $0.status != .pending }.count
                if unresolved > 0 {
                    self.deletionMessage = "Some staged choices need review because Photos changed or an item is unavailable. The remaining intent is still saved."
                } else if committedIDs.isEmpty {
                    self.deletionMessage = "No staged choices were confirmed by Photos. They remain saved for retry."
                }

                self.showDeleteConfirmation = false
                self.deletionArmed = false
                self.scheduleSessionSave()
                if self.pendingPhotoItems.isEmpty {
                    self.markCurrentBatchCommitted(wasFullyReviewed: wasFullyReviewed)
                }
            } catch {
                self.errorMessage = "Commit could not be verified. Your staged choices remain saved: \(error.localizedDescription)"
            }
        }
    }

    func cancelFolderCommit() {
        guard let folderCommitTask, !isCancellingFolderCommit else { return }
        isCancellingFolderCommit = true
        if var progress = folderCommitProgress {
            progress.statusMessage = "Stopping after the current file..."
            folderCommitProgress = progress
        }
        folderCommitTask.cancel()
    }

    private func updateFolderCommitProgress(_ progress: FolderCommitExecutionProgress) {
        folderCommitProgress = progress
    }

    private func queueMarkedFolderItems() {
        guard !isDeleting, !isRecheckingPhotoQueue, !isScanning, !isPreparingScan else { return }
        guard let sourceFolderURL = try? folderLibraryService.resolveValidatedFolderURL(for: folderSelection) else {
            errorMessage = ReviewError.missingSourceFolder.localizedDescription
            return
        }

        let plan = buildFolderCommitPlan()
        let wasFullyReviewed = !groups.isEmpty && reviewedGroupCount == groups.count
        let reviewStateForRescan = isCurrentSourceBatchActive
            ? nil
            : captureFolderReviewStateForRescan(using: buildScanSettings())
        folderCommitPlan = plan
        guard let plan, plan.totalMoveCount > 0 else {
            if wasFullyReviewed {
                showDeleteConfirmation = false
                deletionArmed = false
                markCurrentBatchCommitted(wasFullyReviewed: true)
            } else {
                errorMessage = ReviewError.noReviewedItemsToCommit.localizedDescription
            }
            return
        }

        errorMessage = nil
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        if shouldPersistReviewSession {
            persistReviewSessionNow()
            guard errorMessage == nil else { return }
        }
        deletionMessage = nil
        folderCommitProgress = nil
        isCancellingFolderCommit = false
        isDeleting = true

        folderCommitTask = Task { [weak self] in
            guard let self else { return }
            var shouldRescanAfterCommit = false
            defer {
                self.isDeleting = false
                self.isCancellingFolderCommit = false
                self.folderCommitTask = nil
                self.resumePendingPhotoLibraryRecheckIfIdle()
                if shouldRescanAfterCommit {
                    self.requestScan(preservingFolderReviewState: reviewStateForRescan)
                }
            }

            do {
                let result = try await self.folderCommitService.execute(
                    plan: plan,
                    sourceFolderURL: sourceFolderURL,
                    progress: { [weak self] progress in
                        await self?.updateFolderCommitProgress(progress)
                    }
                )
                self.showDeleteConfirmation = false
                self.deletionArmed = false
                self.deletionMessage = self.folderCommitMessage(for: result)
                if self.isCurrentSourceBatchActive {
                    if !result.movedItemIDs.isEmpty {
                        self.applyCommittedPhotoItems(
                            committedIDs: result.movedItemIDs,
                            completionMessage: self.folderCommitMessage(for: result),
                            statusMessage: "Folder queues updated."
                        )
                    }
                    if !result.hasIssues {
                        self.markCurrentBatchCommitted(wasFullyReviewed: wasFullyReviewed)
                    }
                } else {
                    shouldRescanAfterCommit = true
                }
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

    private var isCurrentSourceBatchActive: Bool {
        guard let checkpoint = batchCheckpoint else { return false }
        return checkpoint.sourceKey == ScanBatcher.makeSourceKey(settings: buildScanSettings())
    }

    private func markCurrentBatchCommitted(wasFullyReviewed: Bool) {
        guard wasFullyReviewed, var checkpoint = batchCheckpoint, isCurrentSourceBatchActive else { return }
        checkpoint.readyForNextBatch = checkpoint.hasMore
        batchCheckpoint = checkpoint
        scanBatchStateStore.save(checkpoint)
        groupLimitEnabled = true
        if checkpoint.hasMore {
            scanStatusMessage = "Batch \(checkpoint.batchNumber) committed. Next \(groupLimit) ready."
        } else {
            scanStatusMessage = "Batch \(checkpoint.batchNumber) committed. Source scan complete."
        }
    }

    func photoQueuePlan() -> (keepIDs: Set<String>, discardIDs: Set<String>, editIDs: Set<String>) {
        var keepIDs: Set<String> = []
        var discardIDs: Set<String> = []
        var editIDs: Set<String> = []

        if selectedSourceKind == .photos {
            for item in pendingPhotoItems {
                switch item.decision {
                case .keep: keepIDs.insert(item.assetID)
                case .discard: discardIDs.insert(item.assetID)
                case .edit: editIDs.insert(item.assetID)
                }
            }
            return (keepIDs, discardIDs, editIDs)
        }

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

        if selectedSourceKind == .photos, let currentPhotoScopeID, let photoReviewStore {
            do {
                try photoReviewStore.removeItemsFromGroups(scopeID: currentPhotoScopeID, assetIDs: committedIDs)
                refreshPhotoGroupSnapshots()
            } catch {
                errorMessage = "Photos were added, but local group history could not be refreshed: \(error.localizedDescription)"
            }
        }

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

    private func captureFolderReviewStateForRescan(using settings: ScanSettings) -> FolderReviewStateSnapshot? {
        guard selectedSourceKind == .folder, settings.selectedSourceKind == .folder else { return nil }

        var explicitKeepIDs: Set<String> = []
        var explicitDiscardIDs: Set<String> = []
        var fileIdentityByItemID: [String: FolderFileIdentity] = [:]
        var reviewedGroupMemberships: Set<Set<String>> = []
        var highlightedItemsByGroupMembership: [Set<String>: String] = [:]

        for (itemID, item) in itemLookup {
            if let identity = FolderFileIdentity(item: item) {
                fileIdentityByItemID[itemID] = identity
            }
        }

        for group in groups {
            let membership = Set(group.itemIDs)
            let decisions = reviewDecisionsByGroup[group.id] ?? ReviewGroupDecisions()
            explicitKeepIDs.formUnion(decisions.explicitKeepIDs.intersection(membership))
            explicitDiscardIDs.formUnion(decisions.explicitDiscardIDs.intersection(membership))

            if reviewedGroupIDs.contains(group.id) {
                reviewedGroupMemberships.insert(membership)
            }
            if let highlighted = highlightedItemByGroup[group.id], membership.contains(highlighted) {
                highlightedItemsByGroupMembership[membership] = highlighted
            }
        }

        let focusedGroupMembership = groups.indices.contains(currentGroupIndex)
            ? Set(groups[currentGroupIndex].itemIDs)
            : nil
        return FolderReviewStateSnapshot(
            sourceKey: ScanBatcher.makeSourceKey(settings: settings),
            groupingFingerprint: ScanBatcher.groupingFingerprint(settings: settings),
            reviewMode: settings.reviewMode,
            fileIdentityByItemID: fileIdentityByItemID,
            explicitKeepIDs: explicitKeepIDs,
            explicitDiscardIDs: explicitDiscardIDs,
            queuedForEditItemIDs: queuedForEditItemIDs,
            reviewedGroupMemberships: reviewedGroupMemberships,
            highlightedItemsByGroupMembership: highlightedItemsByGroupMembership,
            focusedGroupMembership: focusedGroupMembership,
            previousSession: makeStoredReviewSession()
        )
    }

    private func restoreFolderReviewState(_ snapshot: FolderReviewStateSnapshot, for settings: ScanSettings) {
        guard settings.selectedSourceKind == .folder,
              snapshot.sourceKey == ScanBatcher.makeSourceKey(settings: settings),
              snapshot.groupingFingerprint == ScanBatcher.groupingFingerprint(settings: settings),
              snapshot.reviewMode == settings.reviewMode
        else { return }

        let availableItemIDs = Set(groups.flatMap(\.itemIDs))
        var identityMatchingItemIDs: Set<String> = []
        for (itemID, identity) in snapshot.fileIdentityByItemID {
            guard availableItemIDs.contains(itemID),
                  let currentItem = itemLookup[itemID],
                  identity.matches(currentItem)
            else { continue }
            identityMatchingItemIDs.insert(itemID)
        }
        queuedForEditItemIDs = snapshot.queuedForEditItemIDs.intersection(identityMatchingItemIDs)
        reviewedGroupIDs = []

        for group in groups {
            let membership = Set(group.itemIDs)
            reviewDecisionsByGroup[group.id] = ReviewGroupDecisions(
                explicitKeepIDs: snapshot.explicitKeepIDs
                    .intersection(membership)
                    .intersection(identityMatchingItemIDs),
                explicitDiscardIDs: snapshot.explicitDiscardIDs
                    .intersection(membership)
                    .intersection(identityMatchingItemIDs)
                    .subtracting(queuedForEditItemIDs)
            )

            if snapshot.reviewedGroupMemberships.contains(membership),
               membership.isSubset(of: identityMatchingItemIDs) {
                reviewedGroupIDs.insert(group.id)
            }
            if let highlighted = snapshot.highlightedItemsByGroupMembership[membership],
               membership.contains(highlighted),
               identityMatchingItemIDs.contains(highlighted) {
                highlightedItemByGroup[group.id] = highlighted
            }
        }

        if let focusedGroupMembership = snapshot.focusedGroupMembership,
           focusedGroupMembership.isSubset(of: identityMatchingItemIDs),
           let focusedIndex = groups.firstIndex(where: { Set($0.itemIDs) == focusedGroupMembership }) {
            currentGroupIndex = focusedIndex
        }
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
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await self.prefetchNextGroupItems()
        }
    }

    private func cancelPrefetchAndMaintainCaches() {
        prefetchTask?.cancel()
        prefetchTask = nil
        trimCachesForCurrentWindow()
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

    private var persistedFolderReviewSessionURL: URL {
        AppPaths.folderReviewSessionURL(bundleIdentifier: currentBundleIdentifier)
    }

    private var reviewSessionFileStore: ReviewSessionFileStore {
        if let reviewSessionFileStoreOverride {
            return reviewSessionFileStoreOverride
        }
        return ReviewSessionFileStore(
            legacyURL: persistedReviewSessionURL,
            folderURL: persistedFolderReviewSessionURL,
            fileManager: .default
        )
    }

    private var shouldPersistReviewSession: Bool {
        usesUserPersistence || reviewSessionFileStoreOverride != nil
    }

    private var currentBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? currentBundleIdentifierFallback
    }

    private func restoreFolderSessionInMemory(from stored: StoredReviewSession) {
        guard stored.selectedSourceKind == .folder else { return }

        let availableItems = folderLibraryService.existingItems(from: stored.items)
        let restored = sanitizedReviewSession(
            from: stored,
            availableItems: Dictionary(uniqueKeysWithValues: availableItems.map { ($0.id, $0) })
        )
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
        currentGroupIndex = anchoredGroupIndex(
            preferredGroupID: stored.currentGroupID,
            preferredItemID: stored.currentHighlightedItemID,
            in: groups
        ) ?? min(max(stored.currentGroupIndex, 0), max(0, groups.count - 1))
        deletionArmed = false
        scanProgress = 0
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
        guard persistenceSetupError == nil, !hasAttemptedSessionRestore else { return }

        let fileStore = reviewSessionFileStore
        let preferredEntry = fileStore.loadPreferred(
            selectedSourceKind: selectedSourceKind,
            hasStoredSourcePreference: hasStoredScanPreferences
        )
        let restoresFolderSession = preferredEntry?.session.selectedSourceKind == .folder
        migrateLegacyPhotoSessionIfNeeded(
            from: fileStore.loadLegacy(),
            whileRestoringFolder: restoresFolderSession
        )
        guard var entry = preferredEntry else {
            hasAttemptedSessionRestore = true
            return
        }
        if entry.url.standardizedFileURL == persistedReviewSessionURL.standardizedFileURL,
           entry.session.selectedSourceKind == .folder {
            do {
                entry = try fileStore.copyForwardLegacyFolder(entry)
            } catch {
                errorMessage = "The previous Folder session could not be copied to its new local file. The original remains available: \(error.localizedDescription)"
            }
        }

        hasAttemptedSessionRestore = true
        let stored = entry.session
        guard stored.selectedSourceKind == .folder else {
            return
        }
        applyStoredScanControls(stored)

        let availableItems = folderLibraryService.existingItems(from: stored.items)
        let restored = sanitizedReviewSession(from: stored, availableItems: Dictionary(uniqueKeysWithValues: availableItems.map { ($0.id, $0) }))
        guard !restored.groups.isEmpty else {
            // An empty dedicated Folder file is a reset marker. Keep it so an older
            // shared-path Folder session cannot reappear on the next launch.
            if entry.url.standardizedFileURL == persistedReviewSessionURL.standardizedFileURL {
                clearPersistedReviewSession()
            }
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

    private func migrateLegacyPhotoSessionIfNeeded(
        from entry: ReviewSessionFileStore.Entry?,
        whileRestoringFolder: Bool
    ) {
        guard !hasAttemptedLegacyPhotoMigration,
              let entry,
              entry.session.selectedSourceKind == .photos,
              entry.url.standardizedFileURL == persistedReviewSessionURL.standardizedFileURL else { return }
        hasAttemptedLegacyPhotoMigration = true
        guard let photoReviewStore else { return }

        let digest = SHA256.hash(data: entry.data).map { String(format: "%02x", $0) }.joined()
        let alreadyVerified = (try? photoReviewStore.isMigrationVerified(sourceDigest: digest)) == true
        let shouldRestoreLegacyControls = !whileRestoringFolder
            && selectedSourceKind == .photos
            && !hasStoredScanPreferences
        if alreadyVerified {
            if shouldRestoreLegacyControls {
                applyStoredScanControls(entry.session)
                persistStoredScanPreferences()
            }
            return
        }

        do {
            try migrateLegacyPhotoSession(entry.session, sourceData: entry.data)
            reloadPhotoPendingItems()
            if shouldRestoreLegacyControls {
                applyStoredScanControls(entry.session)
                persistStoredScanPreferences()
                scanStatusMessage = "Previous Photos choices are saved on this device. Run a scan to resume review."
            }
        } catch {
            errorMessage = "The previous Photos session could not be safely imported. The original file is preserved: \(error.localizedDescription)"
            if !whileRestoringFolder { scanStatusMessage = "Run a scan to continue." }
        }
    }

    private func migrateLegacyPhotoSession(_ stored: StoredReviewSession, sourceData: Data) throws {
        guard let photoReviewStore else {
            throw SQLiteReviewStoreError.open("The local review database is unavailable.")
        }
        let legacySettings = legacyPhotoScanSettings(stored)
        let scope = scopeID(for: legacySettings)
        let fingerprint = photoGroupingFingerprint(legacySettings)
        let snapshots = stored.groups.enumerated().map { index, group in
            ReviewGroupSnapshot(
                id: group.id.uuidString.lowercased(),
                scopeID: scope,
                position: index,
                itemIDs: group.itemIDs,
                startDate: group.startDate,
                endDate: group.endDate,
                groupingFingerprint: fingerprint,
                state: .unresolved
            )
        }
        let groupByUUID = Dictionary(uniqueKeysWithValues: stored.groups.map { ($0.id, $0) })
        var explicit: [ExplicitDecision] = []
        for (groupID, group) in groupByUUID {
            let decisions = stored.reviewDecisionsByGroup[groupID] ?? ReviewGroupDecisions()
            for assetID in group.itemIDs {
                let decision: ReviewDecision?
                if stored.queuedForEditItemIDs.contains(assetID) {
                    decision = .edit
                } else if decisions.explicitKeepIDs.contains(assetID) {
                    decision = .keep
                } else if decisions.explicitDiscardIDs.contains(assetID) {
                    decision = .discard
                } else {
                    decision = nil
                }
                if let decision {
                    explicit.append(ExplicitDecision(
                        assetID: assetID,
                        cloudIdentifier: nil,
                        decision: decision,
                        scopeID: scope,
                        groupID: group.id.uuidString.lowercased()
                    ))
                }
            }
        }
        let safeIndex = min(max(stored.currentGroupIndex, 0), snapshots.count)
        let preferredGroupID = stored.currentGroupID.flatMap { id in snapshots.contains(where: { $0.id == id.uuidString.lowercased() }) ? id.uuidString.lowercased() : nil }
        let safePosition = ScopePosition(
            id: scope,
            currentGroupID: preferredGroupID,
            currentItemID: stored.currentHighlightedItemID.flatMap { id in snapshots.contains(where: { $0.itemIDs.contains(id) }) ? id : nil },
            fallbackGroupIndex: safeIndex,
            groupingFingerprint: fingerprint,
            checkpointJSON: nil
        )
        let digest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let migration = LegacyReviewImport(
            sourceDigest: digest,
            libraryKey: Self.photoLibraryKey,
            scopePosition: safePosition,
            groups: snapshots,
            explicitDecisions: explicit
        )
        try photoReviewStore.importLegacy(migration)
    }

    private func legacyPhotoScanSettings(_ stored: StoredReviewSession) -> ScanSettings {
        let (dateFrom, dateTo): (Date?, Date?) = {
            guard stored.useDateRange else { return (nil, nil) }
            let range = PhotoDateRange(from: stored.rangeStartDate, through: stored.rangeEndDate)
            return (range.startInclusive, range.endExclusive)
        }()

        return ScanSettings(
            reviewMode: stored.reviewMode,
            selectedSourceKind: .photos,
            sourceMode: stored.sourceMode,
            selectedAlbumID: stored.selectedAlbumID,
            folderSelection: stored.folderSelection,
            folderRecursiveScan: stored.folderRecursiveScan,
            moveKeptItemsToKeepFolder: stored.moveKeptItemsToKeepFolder,
            dateFrom: dateFrom,
            dateTo: dateTo,
            includeVideos: stored.includeVideos,
            maxTimeGapSeconds: stored.maxTimeGapSeconds,
            similarityDistanceThreshold: Float(fixedSimilarityDistanceThreshold),
            groupLimit: nil
        )
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
        guard shouldPersistReviewSession, persistenceSetupError == nil, !isScanning else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistReviewSessionNow()
        }
    }

    private func persistReviewSessionNow() {
        guard shouldPersistReviewSession, persistenceSetupError == nil else { return }
        if selectedSourceKind == .photos {
            persistPhotoPosition()
            return
        }
        guard let snapshot = makeStoredReviewSession() else {
            clearPersistedReviewSession()
            return
        }

        guard let data = encodeReviewSession(snapshot) else { return }
        do {
            try reviewSessionFileStore.saveFolderData(data)
        } catch {
            errorMessage = "The Folder review session could not be saved locally: \(error.localizedDescription)"
        }
    }

    private func clearPersistedReviewSession() {
        guard shouldPersistReviewSession,
              persistenceSetupError == nil,
              selectedSourceKind == .folder
        else { return }
        guard let data = encodeReviewSession(makeClearedFolderSession()) else { return }
        do {
            // Keep an empty Folder session as a reset marker. This prevents an old
            // shared-path Folder file from reappearing while retaining it as a
            // read-only migration source.
            try reviewSessionFileStore.saveFolderData(data)
        } catch {
            errorMessage = "The Folder review reset could not be saved locally: \(error.localizedDescription)"
        }
    }

    private func encodeReviewSession(_ session: StoredReviewSession) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(session)
    }

    private func makeClearedFolderSession() -> StoredReviewSession {
        StoredReviewSession(
            items: [],
            groups: [],
            currentGroupIndex: 0,
            currentGroupID: nil,
            currentHighlightedItemID: nil,
            reviewMode: reviewMode,
            reviewDecisionsByGroup: [:],
            highlightedItemByGroup: [:],
            reviewedGroupIDs: [],
            queuedForEditItemIDs: [],
            scannedItemCount: 0,
            temporalClusterCount: 0,
            selectedSourceKind: .folder,
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
        hasStoredScanPreferences = true
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
        groupLimit = stored.groupLimit
    }

    private func scheduleStoredScanPreferencesSave() {
        guard usesUserPersistence, persistenceSetupError == nil else { return }
        scanPreferencesSaveTask?.cancel()
        scanPreferencesSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistStoredScanPreferences()
        }
    }

    private func persistStoredScanPreferences() {
        guard persistenceSetupError == nil else { return }
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
                maxAssetsToScan: maxAssetsToScan,
                groupLimit: groupLimit
            )
        )
    }

    private func resetCurrentSessionState(
        clearMessages: Bool,
        clearPersistedFolderSession: Bool = true
    ) {
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
        currentPhotoScopeID = nil
        photoGroupSnapshotsByID = [:]
        scannedAssetCount = 0
        temporalClusterCount = 0
        scanProgress = 0
        scanStatusMessage = "Ready to scan"
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

        if clearMessages {
            deletionMessage = nil
            editQueueMessage = nil
            errorMessage = nil
        }

        if clearPersistedFolderSession {
            // Keep a failed durable reset visible. Clearing old transient messages must
            // happen before attempting the Folder reset marker write.
            clearPersistedReviewSession()
        }
    }

    private func invalidateActiveWork() {
        sessionGeneration &+= 1
        scanRequestTask?.cancel()
        scanRequestTask = nil
        scanTask?.cancel()
        scanTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        isPreparingScan = false
        isScanning = false
        scanProgress = 0
    }
}

extension ReviewViewModel {
    private enum AlbumBindingChoice {
        case bind(String)
        case create
        case cancel
    }

    func reloadPhotoPendingItems() {
        guard let photoReviewStore else {
            pendingPhotoItems = []
            pendingPhotoByID = [:]
            return
        }
        do {
            pendingPhotoItems = try photoReviewStore.pendingItems(libraryKey: Self.photoLibraryKey)
            pendingPhotoByID = Dictionary(uniqueKeysWithValues: pendingPhotoItems.map { ($0.assetID, $0) })
        } catch {
            errorMessage = "Could not read the local Photos review queue: \(error.localizedDescription)"
        }
    }

    func setPendingPhotoDecision(_ decision: ReviewDecision, for assetID: String) {
        guard let photoReviewStore, let row = pendingPhotoByID[assetID] else { return }
        do {
            try photoReviewStore.setExplicitDecision(
                libraryKey: Self.photoLibraryKey,
                assetID: assetID,
                cloudIdentifier: row.cloudIdentifier,
                decision: decision,
                scopeID: row.scopeID ?? "revisited",
                groupID: row.groupID ?? "revisited"
            )
            let savedGroupID = row.groupID.flatMap(UUID.init(uuidString:))
            if let group = groups.first(where: { candidate in
                candidate.id == savedGroupID || candidate.itemIDs.contains(assetID)
            }) {
                var state = reviewDecisionsByGroup[group.id] ?? ReviewGroupDecisions()
                state.explicitKeepIDs.remove(assetID)
                state.explicitDiscardIDs.remove(assetID)
                queuedForEditItemIDs.remove(assetID)
                switch decision {
                case .keep: state.explicitKeepIDs.insert(assetID)
                case .discard: state.explicitDiscardIDs.insert(assetID)
                case .edit: queuedForEditItemIDs.insert(assetID)
                }
                reviewDecisionsByGroup[group.id] = state
            }
            reloadPhotoPendingItems()
            scheduleEstimatedDiscardSizeRefresh()
        } catch {
            errorMessage = "Could not update this staged choice: \(error.localizedDescription)"
        }
    }

    func openPhotoPendingQueue() {
        reloadPhotoPendingItems()
        showPhotoQueue = true
    }

    func recheckPhotoQueue() async {
        guard !isDeleting, !isRecheckingPhotoQueue, !isScanning, !isPreparingScan else {
            deletionMessage = "Wait for the active Photos operation to finish before rechecking the queue."
            return
        }
        isRecheckingPhotoQueue = true
        let observedGeneration = photoLibraryChangeGeneration
        defer {
            isRecheckingPhotoQueue = false
            resumePendingPhotoLibraryRecheckIfIdle()
        }
        guard await ensureAuthorizationForQueueing() else { return }
        do {
            let bindings = try await preparePhotoDestinationBindings(requireAll: true)
            try reconcileInterruptedPhotoCommits(using: bindings)
            try reconcilePhotoPendingItems(using: bindings)
            if photoLibraryChangeGeneration == observedGeneration {
                photoLibraryNeedsRecheck = false
                photoLibraryRecheckDeferredByBusyWork = false
            } else {
                photoLibraryNeedsRecheck = true
                photoLibraryRecheckDeferredByBusyWork = true
            }
            deletionMessage = photoLibraryNeedsRecheck
                ? "Photos changed again during the check. The staged queue will be checked once more."
                : "Photos album membership was checked again."
        } catch {
            errorMessage = "The staged queue could not be rechecked: \(error.localizedDescription)"
        }
    }

    func pendingPhotoTitle(for assetID: String) -> String {
        itemLookup[assetID]?.displayName ?? "Photos item · \(assetID.suffix(10))"
    }

    func scopeID(for settings: ScanSettings) -> String {
        ScanBatcher.makePhotoScopeID(settings: settings)
    }

    func photoExcludedAssetIDs(using albumIdentifiers: [DestinationRole: String]) throws -> Set<String> {
        guard let photoReviewStore else { throw SQLiteReviewStoreError.open("The local review database is unavailable.") }
        let queued = try photoReviewStore.queuedAssetIDs(libraryKey: Self.photoLibraryKey)
        let memberships = try libraryService.destinationMemberships(albumLocalIdentifiers: albumIdentifiers)
        return queued.union(memberships.values.reduce(into: Set<String>()) { $0.formUnion($1) })
    }

    func preparePhotoDestinationBindings(requireAll: Bool = true) async throws -> [DestinationRole: String] {
        guard let photoReviewStore else { throw SQLiteReviewStoreError.open("The local review database is unavailable.") }
        let candidates = libraryService.destinationAlbumCandidates()
        let saved = try photoReviewStore.albumBindings(libraryKey: Self.photoLibraryKey)
        var identifiers: [DestinationRole: String] = [:]
        photoAlbumBindings = [:]
        photoAlbumTitles = [:]

        for role in DestinationRole.allCases {
            let prior = saved.first(where: { $0.role == role })
            var selected = prior.flatMap { binding in candidates.first(where: { $0.localIdentifier == binding.localIdentifier }) }

            if selected == nil {
                let title = destinationTitle(for: role)
                let exactMatches = candidates.filter { $0.localizedTitle?.compare(title, options: .caseInsensitive) == .orderedSame }
                if prior == nil, exactMatches.count == 1 {
                    selected = exactMatches[0]
                } else if requireAll || !exactMatches.isEmpty {
                    switch chooseDestinationAlbum(
                        role: role,
                        candidates: candidates,
                        canCreate: requireAll && exactMatches.isEmpty
                    ) {
                    case .bind(let identifier):
                        selected = candidates.first(where: { $0.localIdentifier == identifier })
                    case .create:
                        selected = try await libraryService.createDestinationAlbum(named: title)
                    case .cancel:
                        if requireAll { throw CancellationError() }
                    }
                }
            }

            guard let album = selected, let title = album.localizedTitle else {
                if !requireAll { continue }
                throw SQLiteReviewStoreError.open("The \(destinationTitle(for: role)) destination album could not be resolved.")
            }
            identifiers[role] = album.localIdentifier
            photoAlbumBindings[role] = album
            photoAlbumTitles[role] = title
            try photoReviewStore.bindAlbum(DestinationAlbumBinding(
                libraryKey: Self.photoLibraryKey,
                role: role,
                localIdentifier: album.localIdentifier,
                cloudIdentifier: nil,
                title: title
            ))
        }

        guard Set(identifiers.values).count == identifiers.count,
              !requireAll || identifiers.count == DestinationRole.allCases.count else {
            throw SQLiteReviewStoreError.open("Each review role must use a different Photos album. Rebind the duplicated roles before scanning.")
        }
        return identifiers
    }

    private func reconcilePhotoPendingItems(using bindings: [DestinationRole: String]) throws {
        guard let photoReviewStore,
              Set(bindings.keys) == Set(DestinationRole.allCases) else { return }
        let memberships = try libraryService.destinationMemberships(albumLocalIdentifiers: bindings)
        let rows = try photoReviewStore.pendingItems(libraryKey: Self.photoLibraryKey)
        let assets = libraryService.fetchAssetsByLocalIdentifier(rows.map(\.assetID))
        var rolesByAsset: [String: Set<DestinationRole>] = [:]
        for (role, assetIDs) in memberships {
            for assetID in assetIDs { rolesByAsset[assetID, default: []].insert(role) }
        }
        for row in rows {
            let roles = rolesByAsset[row.assetID] ?? []
            let target = destinationRole(for: row.decision)
            let outcome: CommitItemOutcome
            if roles.count > 1 || (!roles.isEmpty && !roles.contains(target)) {
                outcome = .conflict
            } else if roles.contains(target) {
                outcome = .verifiedCommitted
            } else if assets[row.assetID] == nil {
                outcome = .unavailable
            } else {
                outcome = .retryable
            }
            try photoReviewStore.reconcileObservedMembership(
                libraryKey: Self.photoLibraryKey,
                assetID: row.assetID,
                revision: row.revision,
                outcome: outcome
            )
        }
        reloadPhotoPendingItems()
    }

    private func reconcileInterruptedPhotoCommits(using bindings: [DestinationRole: String]) throws {
        guard let photoReviewStore,
              Set(bindings.keys) == Set(DestinationRole.allCases) else { return }
        let attempts = try photoReviewStore.commitAttemptsNeedingRecovery()
        guard !attempts.isEmpty else { return }
        let memberships = try libraryService.destinationMemberships(albumLocalIdentifiers: bindings)
        let allIDs = Set(attempts.flatMap { $0.items.map(\.assetID) })
        let assets = libraryService.fetchAssetsByLocalIdentifier(Array(allIDs))
        var rolesByAsset: [String: Set<DestinationRole>] = [:]
        for (role, assetIDs) in memberships {
            for assetID in assetIDs { rolesByAsset[assetID, default: []].insert(role) }
        }
        for attempt in attempts {
            var outcomes: [String: CommitItemOutcome] = [:]
            for item in attempt.items {
                let roles = rolesByAsset[item.assetID] ?? []
                let target = destinationRole(for: item.decision)
                if roles.count > 1 || (!roles.isEmpty && !roles.contains(target)) {
                    outcomes[item.assetID] = .conflict
                } else if roles.contains(target) {
                    outcomes[item.assetID] = .verifiedCommitted
                } else if assets[item.assetID] == nil {
                    outcomes[item.assetID] = .unavailable
                } else {
                    outcomes[item.assetID] = .retryable
                }
            }
            try photoReviewStore.reconcile(attemptID: attempt.id, outcomes: outcomes)
        }
        reloadPhotoPendingItems()
    }

    private func destinationRole(for decision: ReviewDecision) -> DestinationRole {
        switch decision {
        case .keep: .fullySorted
        case .discard: .manualDelete
        case .edit: .edit
        }
    }

    func refreshPhotoGroupSnapshots() {
        guard let currentPhotoScopeID, let photoReviewStore,
              let snapshots = try? photoReviewStore.groups(scopeID: currentPhotoScopeID) else { return }
        photoGroupSnapshotsByID = snapshots.reduce(into: [:]) { result, snapshot in
            guard let id = UUID(uuidString: snapshot.id) else { return }
            result[id] = snapshot
        }
    }

    func restorePhotoGroups(for settings: ScanSettings) throws {
        guard let photoReviewStore else { throw SQLiteReviewStoreError.open("The local review database is unavailable.") }
        let scope = scopeID(for: settings)
        currentPhotoScopeID = scope
        let existing = try photoReviewStore.groups(scopeID: scope)
        let savedByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let savedByMembership = Dictionary(grouping: existing) { snapshot in
            snapshot.itemIDs.map { "\($0.utf8.count):\($0)" }.joined()
        }
        let currentGroupingFingerprint = photoGroupingFingerprint(settings)
        var legacyGroupIDMapping: [String: String] = [:]
        var previouslyKnownGroupIDs = Set(existing.map(\.id))
        var previouslyCompletedGroupIDs = Set(existing.filter { $0.state == .completed }.map(\.id))
        var newSnapshots: [ReviewGroupSnapshot] = []
        for (index, group) in groups.enumerated() {
            let identifier = group.id.uuidString.lowercased()
            let membershipKey = group.itemIDs.map { "\($0.utf8.count):\($0)" }.joined()
            let saved = savedByID[identifier] ?? savedByMembership[membershipKey]?.first(where: {
                $0.groupingFingerprint == currentGroupingFingerprint
            })
            if let saved, saved.id != identifier {
                legacyGroupIDMapping[saved.id] = identifier
                previouslyKnownGroupIDs.insert(identifier)
                if saved.state == .completed { previouslyCompletedGroupIDs.insert(identifier) }
            }
            let snapshot = ReviewGroupSnapshot(
                id: identifier,
                scopeID: scope,
                position: index,
                itemIDs: group.itemIDs,
                startDate: group.startDate,
                endDate: group.endDate,
                groupingFingerprint: currentGroupingFingerprint,
                state: saved?.state ?? .unresolved
            )
            try photoReviewStore.save(group: snapshot)
            newSnapshots.append(snapshot)
        }
        photoGroupSnapshotsByID = newSnapshots.reduce(into: [:]) { result, snapshot in
            guard let id = UUID(uuidString: snapshot.id) else { return }
            result[id] = snapshot
        }

        reviewDecisionsByGroup = [:]
        queuedForEditItemIDs = []
        for group in groups { reviewDecisionsByGroup[group.id] = ReviewGroupDecisions() }
        reloadPhotoPendingItems()
        let visibleGroupIDs = Set(groups.map { $0.id.uuidString.lowercased() })
        for row in pendingPhotoItems where row.scopeID == scope && row.origin == .explicit {
            guard let group = groups.first(where: { $0.itemIDs.contains(row.assetID) }),
                  visibleGroupIDs.contains(group.id.uuidString.lowercased()) else { continue }
            var state = reviewDecisionsByGroup[group.id] ?? ReviewGroupDecisions()
            switch row.decision {
            case .keep: state.explicitKeepIDs.insert(row.assetID)
            case .discard: state.explicitDiscardIDs.insert(row.assetID)
            case .edit: queuedForEditItemIDs.insert(row.assetID)
            }
            reviewDecisionsByGroup[group.id] = state
        }

        let position = try photoReviewStore.position(scopeID: scope)
        currentGroupIndex = ReviewFrontierPosition.resolve(
            groupIDs: groups.map { $0.id.uuidString.lowercased() },
            itemIDsByGroup: groups.map(\.itemIDs),
            previouslyKnownGroupIDs: previouslyKnownGroupIDs,
            previouslyCompletedGroupIDs: previouslyCompletedGroupIDs,
            currentGroupID: position?.currentGroupID.flatMap { legacyGroupIDMapping[$0] ?? $0 },
            currentItemID: position?.currentItemID,
            fallbackGroupIndex: position?.fallbackGroupIndex ?? 0
        )
        if let position {
            if let itemID = position.currentItemID,
               let group = groups.first(where: { $0.itemIDs.contains(itemID) }) {
                highlightedItemByGroup[group.id] = itemID
            }
        } else {
            currentGroupIndex = 0
        }
    }

    func persistPhotoPosition() {
        guard selectedSourceKind == .photos, let photoReviewStore, currentPhotoScopeID != nil else { return }
        do {
            try photoReviewStore.save(position: makePhotoScopePosition(groupIndex: currentGroupIndex))
        } catch {
            errorMessage = "Could not save the Photos review position: \(error.localizedDescription)"
        }
    }

    private func makePhotoScopePosition(groupIndex: Int) -> ScopePosition {
        let settings = buildScanSettings()
        let scope = currentPhotoScopeID ?? scopeID(for: settings)
        let boundedIndex = min(max(0, groupIndex), groups.count)
        let group = groups.indices.contains(boundedIndex) ? groups[boundedIndex] : nil
        let itemID = group.flatMap { highlightedAssetID(in: $0) }
        let checkpoint = batchCheckpoint.flatMap { try? JSONEncoder().encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
        return ScopePosition(
            id: scope,
            currentGroupID: group?.id.uuidString.lowercased(),
            currentItemID: itemID,
            fallbackGroupIndex: boundedIndex,
            groupingFingerprint: photoGroupingFingerprint(settings),
            checkpointJSON: checkpoint
        )
    }

    private func photoGroupSnapshot(for group: ReviewGroup) -> ReviewGroupSnapshot? {
        let identifier = group.id.uuidString.lowercased()
        if let cached = photoGroupSnapshotsByID[group.id] { return cached }
        guard let currentPhotoScopeID, let photoReviewStore,
              let existing = try? photoReviewStore.groups(scopeID: currentPhotoScopeID).first(where: { $0.id == identifier }) else {
            return nil
        }
        return existing
    }

    private func completePhotoGroup(_ group: ReviewGroup) -> Bool {
        guard let photoReviewStore, let snapshot = photoGroupSnapshot(for: group) else { return false }
        do {
            let defaultDecision: ReviewDecision = reviewMode == .keepFirst ? .keep : .discard
            try photoReviewStore.completeGroup(
                snapshot,
                defaultDecision: defaultDecision,
                libraryKey: Self.photoLibraryKey,
                nextPosition: makePhotoScopePosition(groupIndex: min(currentGroupIndex + 1, groups.count))
            )
            let completed = ReviewGroupSnapshot(
                id: snapshot.id,
                scopeID: snapshot.scopeID,
                position: snapshot.position,
                itemIDs: snapshot.itemIDs,
                startDate: snapshot.startDate,
                endDate: snapshot.endDate,
                groupingFingerprint: snapshot.groupingFingerprint,
                state: .completed
            )
            photoGroupSnapshotsByID[group.id] = completed
            reloadPhotoPendingItems()
            scheduleEstimatedDiscardSizeRefresh()
            return true
        } catch {
            errorMessage = "This group could not be staged safely: \(error.localizedDescription)"
            return false
        }
    }

    private func persistPhotoChoices(for group: ReviewGroup) {
        guard selectedSourceKind == .photos, let photoReviewStore,
              let scope = currentPhotoScopeID,
              let snapshot = photoGroupSnapshot(for: group) else { return }
        let decisions = reviewDecisionsByGroup[group.id] ?? ReviewGroupDecisions()
        do {
            for assetID in group.itemIDs {
                let existing = try photoReviewStore.pendingItem(libraryKey: Self.photoLibraryKey, assetID: assetID)
                let decision: ReviewDecision?
                if queuedForEditItemIDs.contains(assetID) {
                    decision = .edit
                } else if decisions.explicitKeepIDs.contains(assetID) {
                    decision = .keep
                } else if decisions.explicitDiscardIDs.contains(assetID) {
                    decision = .discard
                } else if existing?.origin == .completedDefault {
                    continue
                } else if existing?.origin == .explicit {
                    // A user toggled a prior explicit choice back to the active default.
                    // Keep the current intent journalable instead of erasing an in-flight revision.
                    decision = reviewMode == .keepFirst ? .keep : .discard
                } else {
                    continue
                }
                guard let decision else { continue }
                if existing?.origin == .explicit, existing?.decision == decision { continue }
                try photoReviewStore.setExplicitDecision(
                    libraryKey: Self.photoLibraryKey,
                    assetID: assetID,
                    cloudIdentifier: existing?.cloudIdentifier,
                    decision: decision,
                    scopeID: scope,
                    groupID: snapshot.id
                )
            }
            reloadPhotoPendingItems()
        } catch {
            errorMessage = "Could not save the staged Photos choice: \(error.localizedDescription)"
        }
    }

    private func photoGroupingFingerprint(_ settings: ScanSettings) -> String {
        "\(TemporalGrouping.fingerprint(maxGapSeconds: settings.maxTimeGapSeconds))|videos=\(settings.includeVideos)"
    }

    private func destinationTitle(for role: DestinationRole) -> String {
        switch role {
        case .fullySorted: fullySortedAlbumTitle
        case .manualDelete: manualDeleteAlbumTitle
        case .edit: editAlbumTitle
        }
    }

    private func chooseDestinationAlbum(
        role: DestinationRole,
        candidates: [PHAssetCollection],
        canCreate: Bool
    ) -> AlbumBindingChoice {
        let title = destinationTitle(for: role)
        let alert = NSAlert()
        alert.messageText = "Choose the \(title) Photos album"
        alert.informativeText = "Album names can be ambiguous across devices. Choose the intended album by its identity, or create the missing destination. Photos membership is used to keep sorted items out of future scans."
        var picker: NSPopUpButton?
        if !candidates.isEmpty {
            let control = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
            for album in candidates {
                let identifier = album.localIdentifier
                let suffix = String(identifier.suffix(12))
                control.addItem(withTitle: "\(album.localizedTitle ?? "Untitled") · \(suffix)")
                control.lastItem?.representedObject = identifier
            }
            alert.accessoryView = control
            picker = control
        }

        if candidates.isEmpty {
            alert.addButton(withTitle: "Create Album")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            return response == .alertFirstButtonReturn ? .create : .cancel
        }

        alert.addButton(withTitle: "Bind Selected")
        if canCreate { alert.addButton(withTitle: "Create Missing") }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let identifier = picker?.selectedItem?.representedObject as? String {
            return .bind(identifier)
        }
        if canCreate, response == .alertSecondButtonReturn { return .create }
        return .cancel
    }
}
