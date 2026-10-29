@preconcurrency import AVFoundation
@preconcurrency import Photos
@preconcurrency import UIKit
import Combine
import Foundation
import PhotosSortCore

enum PhotosAppScreen {
    case home
    case albumBinding
    case review
    case pending
    case pendingReview
    case conflicts
}

enum PhotosReviewMode: String, CaseIterable, Identifiable, Hashable {
    case discardFirst
    case keepFirst

    var id: String { rawValue }
    var defaultDecision: ReviewDecision { self == .keepFirst ? .keep : .discard }
    var title: String { self == .keepFirst ? "Keep-first" : "Discard-first" }
    var shortDefault: String { self == .keepFirst ? "Default Keep" : "Default Discard" }
}

enum PhotosSourceMode: String, CaseIterable, Identifiable, Hashable {
    case allPhotos
    case album

    var id: String { rawValue }
    var title: String { self == .allPhotos ? "All Photos" : "Album" }
}

struct PhotoAlbumChoice: Identifiable, Hashable {
    let localIdentifier: String
    let title: String
    var id: String { localIdentifier }
}

private struct PhotosScopeSnapshot: Equatable {
    let sourceMode: PhotosSourceMode
    let selectedAlbumID: String?
    let includeDateRange: Bool
    let dateFrom: Date
    let dateToExclusive: Date
    let includeVideos: Bool
    let id: String
}

struct AlbumBindingStep: Identifiable {
    let role: DestinationRole
    let title: String
    let candidates: [PhotoAlbumChoice]
    let needsRebind: Bool
    var id: String { role.rawValue }
}

@MainActor
final class PhotosReviewModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    private static let libraryKey = "local-photos-library"
    private static let roleTitles: [DestinationRole: String] = [
        .fullySorted: "Fully Sorted",
        .manualDelete: "Files to Manually Delete",
        .edit: "Files to Edit"
    ]
    private static let defaultGap: TimeInterval = 8

    @Published var screen: PhotosAppScreen = .home
    @Published var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var albums: [PhotoAlbumChoice] = []
    @Published var bindingStep: AlbumBindingStep?
    @Published var boundAlbumTitles: [DestinationRole: String] = [:]
    @Published var sourceMode: PhotosSourceMode = PhotosSourceMode(
        rawValue: UserDefaults.standard.string(forKey: "photosReview.sourceMode") ?? ""
    ) ?? .allPhotos {
        didSet { UserDefaults.standard.set(sourceMode.rawValue, forKey: "photosReview.sourceMode") }
    }
    @Published var selectedAlbumID: String? = UserDefaults.standard.string(forKey: "photosReview.selectedAlbumID") {
        didSet {
            if let selectedAlbumID { UserDefaults.standard.set(selectedAlbumID, forKey: "photosReview.selectedAlbumID") }
            else { UserDefaults.standard.removeObject(forKey: "photosReview.selectedAlbumID") }
        }
    }
    @Published var includeDateRange = UserDefaults.standard.bool(forKey: "photosReview.includeDateRange") {
        didSet { UserDefaults.standard.set(includeDateRange, forKey: "photosReview.includeDateRange") }
    }
    @Published var dateFrom = (UserDefaults.standard.object(forKey: "photosReview.dateFrom") as? Date)
        ?? (Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()) {
        didSet { UserDefaults.standard.set(dateFrom, forKey: "photosReview.dateFrom") }
    }
    @Published var dateTo = (UserDefaults.standard.object(forKey: "photosReview.dateTo") as? Date) ?? Date() {
        didSet { UserDefaults.standard.set(dateTo, forKey: "photosReview.dateTo") }
    }
    @Published var includeVideos = (UserDefaults.standard.object(forKey: "photosReview.includeVideos") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(includeVideos, forKey: "photosReview.includeVideos") }
    }
    @Published var reviewMode: PhotosReviewMode = PhotosReviewMode(rawValue: UserDefaults.standard.string(forKey: "reviewMode") ?? "discardFirst") ?? .discardFirst {
        didSet { UserDefaults.standard.set(reviewMode.rawValue, forKey: "reviewMode") }
    }
    @Published var groups: [ReviewGroupSnapshot] = []
    @Published var currentGroupIndex = 0
    @Published var selectedAssetID: String?
    @Published var pendingRows: [PendingReviewItem] = []
    @Published var pendingSelection: PendingReviewItem?
    @Published var isScanning = false
    @Published var isRecheckingPhotos = false
    @Published var scanProgress = 0.0
    @Published var scanStatus = ""
    @Published var isCommitting = false
    @Published var commitProgress = ""
    @Published var iCloudProgress = 0.0
    @Published var isLoadingMedia = false
    @Published var libraryChanged = false
    @Published var currentThumbnail: UIImage?
    @Published var currentVideoPlayer: AVPlayer?
    @Published var currentLivePhoto: PHLivePhoto?
    @Published var alertMessage = ""
    @Published var showAlert = false
    @Published var statusMessage: String?
    @Published var showCommitSummary = false
    @Published var showInspector = false
    @Published var isComparing = false
    @Published var compareAssetIDs: Set<String> = []
    @Published var comparisonSelectedAssetID: String?
    @Published var sceneIsActive = true

    private let store: SQLiteReviewStore?
    private var assetsByID: [String: PHAsset] = [:]
    private var resolvedAlbums: [DestinationRole: PHAssetCollection] = [:]
    private var duplicateBindingRoles: Set<DestinationRole> = []
    private var duplicateBindingAlbumIDs: Set<String> = []
    private var thumbnails = NSCache<NSString, UIImage>()
    private var previewTask: Task<Void, Never>?
    private var workflowTask: Task<Void, Never>?
    private var workflowGeneration = 0
    private var statusGeneration = 0
    private var didRegisterObserver = false
    private var activeScopeID: String?
    private var photoLibraryRefreshTask: Task<Void, Never>?
    private var photoLibraryChangeGeneration = 0

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dbURL = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.sidelarklabs.photoslibrarysorthelper.ios", isDirectory: true)
            .appendingPathComponent("review-state.sqlite")
        store = try? SQLiteReviewStore(url: dbURL)
        super.init()
        if store == nil {
            alertMessage = "Local review storage could not be opened. Your pending decisions are not available, so review cannot begin safely."
            showAlert = true
        }
    }

    var isAuthorized: Bool { authorizationStatus == .authorized }
    var isLimited: Bool { authorizationStatus == .limited }
    var currentGroup: ReviewGroupSnapshot? { groups.indices.contains(currentGroupIndex) ? groups[currentGroupIndex] : nil }
    var currentGroupCount: Int { groups.count }
    var hasPreviousGroup: Bool { currentGroupIndex > 0 }
    var hasNextGroup: Bool { currentGroupIndex + 1 < groups.count }
    var unresolvedConflictCount: Int { pendingRows.filter { $0.status == .conflict }.count }
    var unavailableCount: Int { pendingRows.filter { $0.status == .unavailable }.count }
    var keepCount: Int { pendingRows.filter { $0.decision == .keep }.count }
    var discardCount: Int { pendingRows.filter { $0.decision == .discard }.count }
    var editCount: Int { pendingRows.filter { $0.decision == .edit }.count }
    var commitEligibleCount: Int { pendingRows.filter { $0.status == .pending }.count }
    var selectedAlbumTitle: String {
        albums.first(where: { $0.localIdentifier == selectedAlbumID })?.title ?? "Choose an album"
    }

    var albumBindingSteps: [AlbumBindingStep] {
        DestinationRole.allCases.compactMap { role in
            guard resolvedAlbums[role] == nil else { return nil }
            let exact = albums.filter { $0.title.compare(Self.roleTitles[role] ?? "", options: .caseInsensitive) == .orderedSame }
            let storedBindings = (try? store?.albumBindings(libraryKey: Self.libraryKey)) ?? []
            let oldBindingExists = storedBindings.contains(where: { $0.role == role })
            return AlbumBindingStep(
                role: role,
                title: Self.roleTitles[role] ?? role.rawValue,
                candidates: albums.filter { canBindAlbum($0.localIdentifier, for: role) },
                needsRebind: oldBindingExists || exact.count > 1 || duplicateBindingRoles.contains(role)
            )
        }
    }

    var canCreateCurrentRoleAlbum: Bool {
        guard let role = bindingStep?.role else { return false }
        let title = Self.roleTitles[role] ?? role.rawValue
        return !albums.contains { $0.title.compare(title, options: .caseInsensitive) == .orderedSame }
    }

    func canBindAlbum(_ localIdentifier: String, for role: DestinationRole) -> Bool {
        guard !duplicateBindingAlbumIDs.contains(localIdentifier) else { return false }
        let storedBindings = (try? store?.albumBindings(libraryKey: Self.libraryKey)) ?? []
        guard storedBindings.allSatisfy({ $0.role == role || $0.localIdentifier != localIdentifier }) else { return false }
        return resolvedAlbums.allSatisfy { $0.key == role || $0.value.localIdentifier != localIdentifier }
    }

    func refreshLocalState() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        reloadPending()
    }

    func reloadPending() {
        guard let store else { return }
        do {
            pendingRows = try store.pendingItems(libraryKey: Self.libraryKey)
        } catch {
            presentError("Could not read the local pending queue: \(error.localizedDescription)")
        }
    }

    func loadAlbumsForScope() {
        Task {
            authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if authorizationStatus == .notDetermined {
                authorizationStatus = await withCheckedContinuation { continuation in
                    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in continuation.resume(returning: status) }
                }
            }
            guard authorizationStatus == .authorized else {
                presentError("Full Photos access is required to choose an album scope. Your local queue is unchanged.")
                return
            }
            let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            albums = (0..<fetch.count).compactMap { index in
                let album = fetch.object(at: index)
                guard let title = album.localizedTitle, !title.isEmpty else { return nil }
                return PhotoAlbumChoice(localIdentifier: album.localIdentifier, title: title)
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func startFromHome() {
        startOwnedWorkflow(scope: captureScope(), requestAuthorization: true)
    }

    func scanCurrentScope() {
        guard !isRecheckingPhotos else {
            presentError("Wait for the Photos membership check to finish before rescanning.")
            return
        }
        guard !isCommitting else {
            presentError("Wait for the Photos commit to finish before rescanning.")
            return
        }
        startOwnedWorkflow(scope: captureScope(), requestAuthorization: false)
    }

    private func startOwnedWorkflow(scope: PhotosScopeSnapshot, requestAuthorization: Bool) {
        guard !isCommitting, !isRecheckingPhotos else { return }
        workflowTask?.cancel()
        workflowGeneration &+= 1
        let generation = workflowGeneration
        isScanning = true
        scanProgress = 0
        scanStatus = requestAuthorization ? "Preparing Photos review…" : "Refreshing the Photos scope…"
        workflowTask = Task { [weak self] in
            guard let self else { return }
            await self.runPhotosWorkflow(scope: scope, generation: generation, requestAuthorization: requestAuthorization)
            guard self.workflowGeneration == generation else { return }
            self.workflowTask = nil
        }
    }

    private func isCurrentWorkflow(_ generation: Int, scope: PhotosScopeSnapshot) -> Bool {
        !Task.isCancelled && workflowGeneration == generation && scope.id == scopeID
    }

    private func runPhotosWorkflow(
        scope: PhotosScopeSnapshot,
        generation: Int,
        requestAuthorization: Bool
    ) async {
        guard store != nil else {
            if workflowGeneration == generation { isScanning = false }
            return
        }
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if requestAuthorization && authorizationStatus == .notDetermined {
            authorizationStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in continuation.resume(returning: status) }
            }
        }
        guard isCurrentWorkflow(generation, scope: scope) else { return }
        guard authorizationStatus == .authorized else {
            isScanning = false
            if authorizationStatus == .limited {
                presentError("This workflow needs full Photos access to check every review album and identify unsorted items. Your local pending choices are saved. Change access to Full Access in Settings, then return here.")
            } else {
                presentError("Photos access is needed to start a review. You can change access in Settings; your local pending choices remain saved.")
            }
            return
        }
        if !didRegisterObserver {
            PHPhotoLibrary.shared().register(self)
            didRegisterObserver = true
        }
        await prepareAlbumBindings()
        guard isCurrentWorkflow(generation, scope: scope) else { return }
        if albumBindingSteps.isEmpty {
            await performScopeScan(scope: scope, generation: generation)
        } else {
            isScanning = false
            bindingStep = albumBindingSteps.first
            screen = .albumBinding
        }
    }

    private func prepareAlbumBindings() async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorizationStatus == .authorized else { return }
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var choices: [PhotoAlbumChoice] = []
        var collections: [String: PHAssetCollection] = [:]
        for index in 0..<fetch.count {
            let album = fetch.object(at: index)
            guard let title = album.localizedTitle, !title.isEmpty else { continue }
            choices.append(PhotoAlbumChoice(localIdentifier: album.localIdentifier, title: title))
            collections[album.localIdentifier] = album
        }
        albums = choices.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        resolvedAlbums = [:]
        let storedBindings = (try? store?.albumBindings(libraryKey: Self.libraryKey)) ?? []
        let bindingsByAlbumID = Dictionary(grouping: storedBindings, by: \.localIdentifier)
        duplicateBindingAlbumIDs = Set(bindingsByAlbumID.compactMap { id, bindings in bindings.count > 1 ? id : nil })
        duplicateBindingRoles = Set(storedBindings.compactMap { binding in
            duplicateBindingAlbumIDs.contains(binding.localIdentifier) ? binding.role : nil
        })
        for role in DestinationRole.allCases {
            guard !duplicateBindingRoles.contains(role) else { continue }
            if let binding = storedBindings.first(where: { $0.role == role }) {
                if let existing = collections[binding.localIdentifier] {
                    resolvedAlbums[role] = existing
                    boundAlbumTitles[role] = existing.localizedTitle ?? binding.title
                }
                continue
            }
            let matches = choices.filter { $0.title.compare(Self.roleTitles[role] ?? "", options: .caseInsensitive) == .orderedSame }
            if matches.count == 1, let collection = collections[matches[0].localIdentifier] {
                resolvedAlbums[role] = collection
                boundAlbumTitles[role] = collection.localizedTitle ?? matches[0].title
                persistBinding(role: role, album: collection)
            }
        }
    }

    func bindCurrentRole(to localIdentifier: String) {
        guard let role = bindingStep?.role else { return }
        guard canBindAlbum(localIdentifier, for: role) else {
            presentError("Each review role must use a different Photos album. Choose an album that is not bound to another role.")
            return
        }
        let fetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let album = fetch.firstObject else {
            presentError("That album is no longer available. Refresh the album list and choose again.")
            return
        }
        resolvedAlbums[role] = album
        boundAlbumTitles[role] = album.localizedTitle ?? Self.roleTitles[role]
        persistBinding(role: role, album: album)
        Task {
            await prepareAlbumBindings()
            continueAlbumBinding()
        }
    }

    func createCurrentRoleAlbum() {
        guard let role = bindingStep?.role else { return }
        let title = Self.roleTitles[role] ?? role.rawValue
        guard canCreateCurrentRoleAlbum else {
            presentError("An album with this name already exists. Choose the intended album instead of creating a duplicate.")
            refreshAlbumChoices()
            return
        }
        Task {
            do {
                let existing = fetchAlbums(named: title)
                guard existing.isEmpty else {
                    await prepareAlbumBindings()
                    bindingStep = albumBindingSteps.first(where: { $0.role == role }) ?? albumBindingSteps.first
                    presentError("An album with this name already exists. Choose the intended album instead of creating a duplicate.")
                    return
                }
                try await performPhotoChanges {
                    PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                }
                let created = fetchAlbums(named: title)
                guard created.count == 1, let album = created.first else {
                    await MainActor.run { self.presentError("Photos created the album, but its identity is ambiguous. Choose the exact album to bind before continuing.") }
                    await MainActor.run { self.prepareAlbumBindingsAfterCreation(role: role) }
                    return
                }
                await MainActor.run {
                    self.resolvedAlbums[role] = album
                    self.boundAlbumTitles[role] = album.localizedTitle ?? title
                    self.persistBinding(role: role, album: album)
                    self.continueAlbumBinding()
                }
            } catch {
                await MainActor.run { self.presentError("Could not create the \(title) album: \(error.localizedDescription)") }
            }
        }
    }

    private func fetchAlbums(named title: String) -> [PHAssetCollection] {
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        return (0..<fetch.count).map { fetch.object(at: $0) }
            .filter { $0.localizedTitle?.compare(title, options: .caseInsensitive) == .orderedSame }
    }

    private func prepareAlbumBindingsAfterCreation(role: DestinationRole) {
        Task {
            await prepareAlbumBindings()
            bindingStep = albumBindingSteps.first(where: { $0.role == role }) ?? albumBindingSteps.first
            screen = albumBindingSteps.isEmpty ? .home : .albumBinding
        }
    }

    func refreshAlbumChoices() {
        Task { await prepareAlbumBindings(); bindingStep = albumBindingSteps.first }
    }

    func continueAlbumBinding() {
        bindingStep = albumBindingSteps.first
        if bindingStep == nil { scanCurrentScope() }
    }

    private func persistBinding(role: DestinationRole, album: PHAssetCollection) {
        do {
            try store?.bindAlbum(DestinationAlbumBinding(
                libraryKey: Self.libraryKey,
                role: role,
                localIdentifier: album.localIdentifier,
                cloudIdentifier: nil,
                title: album.localizedTitle ?? Self.roleTitles[role] ?? role.rawValue
            ))
        } catch {
            presentError("The album binding could not be saved locally: \(error.localizedDescription)")
        }
    }

    func scopeDescription() -> String {
        switch sourceMode {
        case .allPhotos: return includeDateRange ? "All Photos · Date range" : "All Photos"
        case .album: return albums.first(where: { $0.localIdentifier == selectedAlbumID })?.title ?? "Choose an album"
        }
    }

    var scopeID: String {
        let album = sourceMode == .album ? selectedAlbumID ?? "missing" : "all"
        let range = normalizedDateRange
        let from = range?.startInclusive.timeIntervalSince1970 ?? -1
        let to = range?.endExclusive.timeIntervalSince1970 ?? -1
        return "photos|\(sourceMode.rawValue)|\(album)|from=\(from)|to=\(to)|videos=\(includeVideos)"
    }

    private var normalizedDateRange: PhotoDateRange? {
        guard includeDateRange else { return nil }
        return PhotoDateRange(from: dateFrom, through: dateTo)
    }

    private func captureScope() -> PhotosScopeSnapshot {
        let range = normalizedDateRange
        return PhotosScopeSnapshot(
            sourceMode: sourceMode,
            selectedAlbumID: selectedAlbumID,
            includeDateRange: includeDateRange,
            dateFrom: range?.startInclusive ?? dateFrom,
            dateToExclusive: range?.endExclusive ?? .distantFuture,
            includeVideos: includeVideos,
            id: scopeID
        )
    }

    private func performScopeScan(scope: PhotosScopeSnapshot, generation: Int) async {
        guard isCurrentWorkflow(generation, scope: scope) else { return }
        guard authorizationStatus == .authorized, store != nil else {
            isScanning = false
            return
        }
        guard scope.sourceMode != .album || scope.selectedAlbumID != nil else {
            isScanning = false
            presentError("Choose a Photos album before scanning this scope.")
            return
        }

        let refreshGenerationAtStart = photoLibraryChangeGeneration
        scanProgress = 0
        scanStatus = "Checking the review albums…"
        libraryChanged = false
        defer {
            if workflowGeneration == generation {
                isScanning = false
                if photoLibraryChangeGeneration != refreshGenerationAtStart {
                    schedulePhotosRefresh()
                }
            }
        }
        do {
            // Resolve the saved identifiers again before reading memberships. A deleted
            // collection must never look like an empty destination album.
            await prepareAlbumBindings()
            guard isCurrentWorkflow(generation, scope: scope) else { throw CancellationError() }
            guard resolvedAlbums.count == DestinationRole.allCases.count else {
                isScanning = false
                bindingStep = albumBindingSteps.first
                if bindingStep != nil { screen = .albumBinding }
                return
            }

            let membership = try fetchAllDestinationMembership()
            try Task.checkCancellation()
            guard isCurrentWorkflow(generation, scope: scope), photoLibraryChangeGeneration == refreshGenerationAtStart else {
                throw CancellationError()
            }
            try recoverInterruptedCommits(using: membership)
            try reconcilePending(with: membership)
            let queuedIDs = try store?.queuedAssetIDs(libraryKey: Self.libraryKey) ?? []
            let source = try fetchScopeAssets(for: scope)
            var assets: [PHAsset] = []
            var metadata: [ReviewMediaMetadata] = []
            assets.reserveCapacity(source.count)
            metadata.reserveCapacity(source.count)
            let statusIDs = Set(membership.values.flatMap { $0 })
            for index in 0..<source.count {
                if index.isMultiple(of: 300) {
                    try Task.checkCancellation()
                    guard isCurrentWorkflow(generation, scope: scope), photoLibraryChangeGeneration == refreshGenerationAtStart else {
                        throw CancellationError()
                    }
                    scanProgress = source.count == 0 ? 0 : Double(index) / Double(source.count)
                    scanStatus = "Reading photo details · \(index.formatted()) of \(source.count.formatted())"
                    await Task.yield()
                }
                let asset = source.object(at: index)
                guard asset.mediaType == .image || asset.mediaType == .video else { continue }
                if asset.mediaType == .video && !scope.includeVideos { continue }
                let effectiveDate = asset.creationDate ?? asset.modificationDate
                if scope.includeDateRange, let effectiveDate,
                   (effectiveDate < scope.dateFrom || effectiveDate >= scope.dateToExclusive) { continue }
                if scope.includeDateRange, effectiveDate == nil { continue }
                let id = asset.localIdentifier
                guard !statusIDs.contains(id), !queuedIDs.contains(id) else { continue }
                assets.append(asset)
                metadata.append(ReviewMediaMetadata(
                    id: id,
                    preferredDate: effectiveDate,
                    isVideo: asset.mediaType == .video,
                    isLivePhoto: asset.mediaSubtypes.contains(.photoLive)
                ))
            }
            try Task.checkCancellation()
            guard isCurrentWorkflow(generation, scope: scope), photoLibraryChangeGeneration == refreshGenerationAtStart else {
                throw CancellationError()
            }
            let newGroups = TemporalGrouping.groups(from: metadata, maxGapSeconds: Self.defaultGap, scopeID: scope.id)
            let prior = try store?.groups(scopeID: scope.id) ?? []
            let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
            let nextGroups = try newGroups.map { group in
                var snapshot = group
                if let old = priorByID[group.id], old.itemIDs == group.itemIDs {
                    snapshot.state = old.state
                }
                try store?.save(group: snapshot)
                return snapshot
            }
            guard isCurrentWorkflow(generation, scope: scope), photoLibraryChangeGeneration == refreshGenerationAtStart else {
                throw CancellationError()
            }

            assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
            groups = nextGroups
            activeScopeID = scope.id
            let saved = try store?.position(scopeID: scope.id)
            currentGroupIndex = ReviewFrontierPosition.resolve(
                groupIDs: groups.map(\.id),
                itemIDsByGroup: groups.map(\.itemIDs),
                previouslyKnownGroupIDs: Set(prior.map(\.id)),
                previouslyCompletedGroupIDs: Set(prior.filter { $0.state == .completed }.map(\.id)),
                currentGroupID: saved?.currentGroupID,
                currentItemID: saved?.currentItemID,
                fallbackGroupIndex: saved?.fallbackGroupIndex ?? 0
            )
            selectedAssetID = currentGroup.flatMap { group in
                let savedItem = saved?.currentItemID
                return savedItem.flatMap { group.itemIDs.contains($0) ? $0 : nil } ?? group.itemIDs.first
            }
            compareAssetIDs = []
            isComparing = false
            reloadPending()
            scanProgress = 1
            scanStatus = groups.isEmpty ? "No unsorted photos remain in this scope." : "\(assets.count.formatted()) unsorted items · \(groups.count.formatted()) review groups"
            screen = .review
            saveCurrentPosition()
            await loadSelectedThumbnail()
            guard isCurrentWorkflow(generation, scope: scope) else { return }
            if photoLibraryChangeGeneration == refreshGenerationAtStart { libraryChanged = false }
        } catch is CancellationError {
            if workflowGeneration == generation {
                scanStatus = "Review preparation cancelled. Your pending choices are saved."
            }
        } catch {
            if workflowGeneration == generation {
                presentError("Could not prepare this Photos scope: \(error.localizedDescription)")
            }
        }
    }

    private func fetchScopeAssets(for scope: PhotosScopeSnapshot) throws -> PHFetchResult<PHAsset> {
        if scope.sourceMode == .album, let selectedAlbumID = scope.selectedAlbumID {
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [selectedAlbumID], options: nil)
            guard let album = collections.firstObject else { throw PhotosReviewError.sourceAlbumUnavailable }
            return PHAsset.fetchAssets(in: album, options: photoFetchOptions())
        }
        guard scope.sourceMode == .allPhotos else { throw PhotosReviewError.sourceAlbumUnavailable }
        return PHAsset.fetchAssets(with: photoFetchOptions())
    }

    private func photoFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    func cancelScan() {
        workflowGeneration &+= 1
        workflowTask?.cancel()
        workflowTask = nil
        isScanning = false
        scanStatus = "Review preparation cancelled. Your pending choices are saved."
    }

    private func invalidateWorkflow() {
        workflowGeneration &+= 1
        workflowTask?.cancel()
        workflowTask = nil
        isScanning = false
    }

    private func fetchAllDestinationMembership() throws -> [DestinationRole: Set<String>] {
        var result: [DestinationRole: Set<String>] = [:]
        for role in DestinationRole.allCases {
            guard let album = resolvedAlbums[role] else { throw PhotosReviewError.albumUnavailable(role) }
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            var ids: Set<String> = []
            for index in 0..<assets.count { ids.insert(assets.object(at: index).localIdentifier) }
            result[role] = ids
        }
        return result
    }

    private func reconcilePending(with membership: [DestinationRole: Set<String>]) throws {
        guard let store else { return }
        let rows = try store.pendingItems(libraryKey: Self.libraryKey)
        let allIDs = rows.map(\.assetID)
        let found = PHAsset.fetchAssets(withLocalIdentifiers: allIDs, options: nil)
        let foundIDs = Set((0..<found.count).map { found.object(at: $0).localIdentifier })
        var roleByID: [String: Set<DestinationRole>] = [:]
        for (role, ids) in membership {
            for id in ids { roleByID[id, default: []].insert(role) }
        }
        for row in rows {
            let roles = roleByID[row.assetID] ?? []
            let outcome = PhotoCommitReconciliation.outcome(
                for: row.decision,
                memberships: roles,
                assetAvailable: foundIDs.contains(row.assetID)
            )
            try store.reconcileObservedMembership(
                libraryKey: Self.libraryKey,
                assetID: row.assetID,
                revision: row.revision,
                outcome: outcome
            )
        }
        reloadPending()
    }

    func currentDecision(for assetID: String) -> ReviewDecision {
        if let row = pendingRows.first(where: { $0.assetID == assetID }) { return row.decision }
        return reviewMode.defaultDecision
    }

    func currentOrigin(for assetID: String) -> DecisionOrigin? {
        pendingRows.first(where: { $0.assetID == assetID })?.origin
    }

    func statusDescription(for assetID: String) -> String {
        if let row = pendingRows.first(where: { $0.assetID == assetID }) {
            let title = decisionTitle(row.decision)
            return row.origin == .completedDefault ? "Staged · Default \(title)" : "Staged · \(title)"
        }
        return "Default · \(decisionTitle(reviewMode.defaultDecision)) · not staged"
    }

    func setDecision(_ decision: ReviewDecision, for assetID: String) {
        guard let group = currentGroup, group.itemIDs.contains(assetID), let store else { return }
        do {
            try store.setExplicitDecision(
                libraryKey: Self.libraryKey,
                assetID: assetID,
                decision: decision,
                scopeID: group.scopeID,
                groupID: group.id
            )
            reloadPending()
            saveCurrentPosition()
        } catch {
            presentError("Could not save this choice locally: \(error.localizedDescription)")
        }
    }

    func selectItem(_ assetID: String) {
        guard currentGroup?.itemIDs.contains(assetID) == true else { return }
        selectedAssetID = assetID
        currentThumbnail = nil
        currentVideoPlayer = nil
        currentLivePhoto = nil
        saveCurrentPosition()
        previewTask?.cancel()
        previewTask = Task { await loadSelectedThumbnail() }
    }

    private func loadSelectedThumbnail() async {
        guard let id = selectedAssetID, let asset = assetForID(id) else { return }
        let image = await thumbnail(for: asset, size: CGSize(width: 1_100, height: 900))
        guard !Task.isCancelled, selectedAssetID == id else { return }
        currentThumbnail = image
    }

    func thumbnail(for assetID: String, size: CGSize = CGSize(width: 220, height: 220)) async -> UIImage? {
        guard let asset = assetForID(assetID) else { return nil }
        return await thumbnail(for: asset, size: size)
    }

    private func thumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        let key = "\(asset.localIdentifier)|\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let image = await PhotoKitMediaLoader.image(
            for: asset,
            targetSize: size,
            deliveryMode: .opportunistic,
            progress: { [weak self] progress in
                Task { @MainActor in self?.iCloudProgress = progress }
            }
        )
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    func moveGroup(by delta: Int) {
        let target = currentGroupIndex + delta
        guard groups.indices.contains(target) else { return }
        currentGroupIndex = target
        selectedAssetID = currentGroup?.itemIDs.first
        currentThumbnail = nil
        currentVideoPlayer = nil
        currentLivePhoto = nil
        saveCurrentPosition()
        previewTask?.cancel()
        previewTask = Task { await loadSelectedThumbnail() }
    }

    func skipCurrentGroup() {
        guard let group = currentGroup, let store else { return }
        do {
            let nextIndex = min(currentGroupIndex + 1, groups.count)
            let nextGroup = groups.indices.contains(nextIndex) ? groups[nextIndex] : nil
            try store.skipGroup(group, nextPosition: ScopePosition(
                id: group.scopeID,
                currentGroupID: nextGroup?.id,
                currentItemID: nextGroup?.itemIDs.first,
                fallbackGroupIndex: nextIndex,
                groupingFingerprint: group.groupingFingerprint
            ))
            var updated = group
            updated.state = .skipped
            groups[currentGroupIndex] = updated
            currentGroupIndex = nextIndex
            selectedAssetID = groups.indices.contains(nextIndex) ? groups[nextIndex].itemIDs.first : nil
        } catch { presentError("Could not save this skipped group: \(error.localizedDescription)") }
    }

    func completeCurrentGroup() {
        guard let group = currentGroup, let store else { return }
        do {
            let nextIndex = min(currentGroupIndex + 1, groups.count)
            let nextGroup = groups.indices.contains(nextIndex) ? groups[nextIndex] : nil
            try store.completeGroup(
                group,
                defaultDecision: reviewMode.defaultDecision,
                libraryKey: Self.libraryKey,
                nextPosition: ScopePosition(
                    id: group.scopeID,
                    currentGroupID: nextGroup?.id,
                    currentItemID: nextGroup?.itemIDs.first,
                    fallbackGroupIndex: nextIndex,
                    groupingFingerprint: group.groupingFingerprint
                )
            )
            var updated = group
            updated.state = .completed
            groups[currentGroupIndex] = updated
            reloadPending()
            currentGroupIndex = nextIndex
            if groups.indices.contains(nextIndex) {
                selectedAssetID = groups[nextIndex].itemIDs.first
                currentThumbnail = nil
                previewTask?.cancel()
                previewTask = Task { await loadSelectedThumbnail() }
            } else {
                selectedAssetID = nil
                currentThumbnail = nil
            }
        } catch { presentError("Could not save this completed group: \(error.localizedDescription)") }
    }

    private func saveCurrentPosition() {
        guard let group = currentGroup, let store else { return }
        do {
            try store.save(position: ScopePosition(
                id: group.scopeID,
                currentGroupID: group.id,
                currentItemID: selectedAssetID,
                fallbackGroupIndex: currentGroupIndex,
                groupingFingerprint: group.groupingFingerprint
            ))
        } catch { presentError("Could not save review position: \(error.localizedDescription)") }
    }

    func openPendingQueue() {
        reloadPending()
        screen = .pending
    }

    func openPendingItem(_ row: PendingReviewItem) {
        pendingSelection = row
        screen = .pendingReview
    }

    func classifyPending(_ decision: ReviewDecision) {
        guard let row = pendingSelection, let store else { return }
        do {
            try store.setExplicitDecision(
                libraryKey: row.libraryKey,
                assetID: row.assetID,
                cloudIdentifier: row.cloudIdentifier,
                decision: decision,
                scopeID: row.scopeID ?? "revisited",
                groupID: row.groupID ?? "revisited"
            )
            reloadPending()
            pendingSelection = pendingRows.first(where: { $0.assetID == row.assetID })
            presentMessage("Saved \(decisionTitle(decision)) for this staged item.")
        } catch { presentError("Could not update the staged choice: \(error.localizedDescription)") }
    }

    func assetForID(_ assetID: String) -> PHAsset? {
        if let asset = assetsByID[assetID] { return asset }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        assetsByID[assetID] = asset
        return asset
    }

    func openInspector(for assetID: String) {
        if assetForID(assetID) != nil {
            selectedAssetID = assetID
            showInspector = true
            previewTask?.cancel()
        }
    }

    func closeInspector() {
        showInspector = false
        previewTask?.cancel()
        currentVideoPlayer?.pause()
    }

    func beginComparison() {
        guard currentGroup != nil else { return }
        if compareAssetIDs.count < 2, let first = selectedAssetID {
            compareAssetIDs.insert(first)
        }
        isComparing = true
        if compareAssetIDs.count == 2 { comparisonSelectedAssetID = compareAssetIDs.first }
    }

    func toggleCompareAsset(_ assetID: String) {
        if compareAssetIDs.contains(assetID) {
            compareAssetIDs.remove(assetID)
        } else if compareAssetIDs.count < 2 {
            compareAssetIDs.insert(assetID)
        } else {
            compareAssetIDs.remove(compareAssetIDs.first!)
            compareAssetIDs.insert(assetID)
        }
        if comparisonSelectedAssetID.map({ !compareAssetIDs.contains($0) }) ?? true {
            comparisonSelectedAssetID = compareAssetIDs.first
        }
    }

    func commitAll() {
        showCommitSummary = false
        guard !pendingRows.isEmpty else { presentMessage("There are no staged choices to commit."); return }
        Task { await performCommit() }
    }

    private func performCommit() async {
        guard let store else { return }
        guard !isCommitting, !isScanning, !isRecheckingPhotos else {
            presentError("Wait for the current Photos operation to finish before committing.")
            return
        }
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorizationStatus == .authorized else {
            presentError("Full Photos access is required before commit. Your staged choices remain saved.")
            return
        }
        isCommitting = true
        let refreshGenerationAtStart = photoLibraryChangeGeneration
        defer {
            isCommitting = false
            if photoLibraryChangeGeneration != refreshGenerationAtStart {
                schedulePhotosRefresh()
            }
        }
        do {
            await prepareAlbumBindings()
            guard resolvedAlbums.count == DestinationRole.allCases.count else {
                bindingStep = albumBindingSteps.first
                screen = .albumBinding
                presentError("Bind all three review albums before committing. No Photos changes were made and your staged choices are still saved.")
                return
            }
            try recoverInterruptedCommits(using: fetchAllDestinationMembership())
            reloadPending()
            let attempt = try store.beginCommit(libraryKey: Self.libraryKey)
            commitProgress = "Checking albums and photo memberships…"

            let assetIDs = attempt.items.map(\.assetID)
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            var currentAssets: [String: PHAsset] = [:]
            for index in 0..<fetch.count {
                let asset = fetch.object(at: index)
                currentAssets[asset.localIdentifier] = asset
            }
            let membership = try fetchMembership(for: Set(assetIDs))
            var outcomes: [String: CommitItemOutcome] = [:]
            var additions: [DestinationRole: [PHAsset]] = [:]
            for item in attempt.items {
                let roles = membership[item.assetID] ?? []
                let outcome = PhotoCommitReconciliation.outcome(
                    for: item.decision,
                    memberships: roles,
                    assetAvailable: currentAssets[item.assetID] != nil
                )
                if outcome == .retryable, let asset = currentAssets[item.assetID] {
                    additions[PhotoCommitReconciliation.destination(for: item.decision), default: []].append(asset)
                } else {
                    outcomes[item.assetID] = outcome
                }
            }

            if !additions.isEmpty {
                commitProgress = "Adding items to the selected Photos albums…"
                let albumsToMutate = resolvedAlbums
                do {
                    try await performPhotoChanges {
                        for role in DestinationRole.allCases {
                            guard let assets = additions[role], !assets.isEmpty,
                                  let album = albumsToMutate[role],
                                  let request = PHAssetCollectionChangeRequest(for: album) else { continue }
                            request.addAssets(assets as NSArray)
                        }
                    }
                } catch {
                    // Reconcile actual membership below even when PhotoKit reports an error.
                }
            }

            commitProgress = "Verifying Photos changes…"
            let after = try fetchMembership(for: Set(assetIDs))
            for item in attempt.items {
                let roles = after[item.assetID] ?? []
                outcomes[item.assetID] = PhotoCommitReconciliation.outcome(
                    for: item.decision,
                    memberships: roles,
                    assetAvailable: currentAssets[item.assetID] != nil
                )
            }
            try store.reconcile(attemptID: attempt.id, outcomes: outcomes)
            reloadPending()
            commitProgress = ""
            if unresolvedConflictCount > 0 {
                presentError("Photos was rechecked, but \(unresolvedConflictCount) conflicting item(s) remain staged. Review them in Staged Choices before retrying.")
            } else if !pendingRows.isEmpty {
                presentError("Verified items were committed. \(pendingRows.count) item(s) remain staged for retry or recovery.")
            } else {
                presentStatus("All staged choices were verified in Photos.")
            }
            if photoLibraryChangeGeneration == refreshGenerationAtStart {
                libraryChanged = false
            }
        } catch {
            commitProgress = ""
            presentError("Commit stopped before the pending queue was cleared: \(error.localizedDescription)")
        }
    }

    private func fetchMembership(for assetIDs: Set<String>) throws -> [String: Set<DestinationRole>] {
        guard !assetIDs.isEmpty else { return [:] }
        var result: [String: Set<DestinationRole>] = [:]
        for role in DestinationRole.allCases {
            guard let album = resolvedAlbums[role] else { throw PhotosReviewError.albumUnavailable(role) }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "localIdentifier IN %@", Array(assetIDs))
            let members = PHAsset.fetchAssets(in: album, options: options)
            for index in 0..<members.count {
                result[members.object(at: index).localIdentifier, default: []].insert(role)
            }
        }
        return result
    }

    private func recoverInterruptedCommits(using membership: [DestinationRole: Set<String>]) throws {
        guard let store else { return }
        let attempts = try store.commitAttemptsNeedingRecovery()
        guard !attempts.isEmpty else { return }
        let assetIDs = Set(attempts.flatMap { $0.items.map(\.assetID) })
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(assetIDs), options: nil)
        let availableIDs = Set((0..<fetch.count).map { fetch.object(at: $0).localIdentifier })
        var rolesByID: [String: Set<DestinationRole>] = [:]
        for (role, ids) in membership {
            for id in ids { rolesByID[id, default: []].insert(role) }
        }
        for attempt in attempts {
            let outcomes = Dictionary(uniqueKeysWithValues: attempt.items.map { item in
                (item.assetID, PhotoCommitReconciliation.outcome(
                    for: item.decision,
                    memberships: rolesByID[item.assetID] ?? [],
                    assetAvailable: availableIDs.contains(item.assetID)
                ))
            })
            try store.reconcile(attemptID: attempt.id, outcomes: outcomes)
        }
    }

    private func destination(for decision: ReviewDecision) -> DestinationRole {
        PhotoCommitReconciliation.destination(for: decision)
    }

    func decisionTitle(_ decision: ReviewDecision) -> String {
        switch decision {
        case .keep: "Keep"
        case .discard: "Discard"
        case .edit: "Edit"
        }
    }

    func destinationTitle(_ role: DestinationRole) -> String {
        Self.roleTitles[role] ?? role.rawValue
    }

    func openConflictReview() {
        reloadPending()
        screen = .conflicts
    }

    func recheckConflicts() {
        guard !isCommitting, !isScanning, !isRecheckingPhotos else {
            presentError("Wait for the current Photos operation to finish before rechecking memberships.")
            return
        }
        isRecheckingPhotos = true
        let refreshGenerationAtStart = photoLibraryChangeGeneration
        Task {
            defer {
                isRecheckingPhotos = false
                if photoLibraryChangeGeneration != refreshGenerationAtStart {
                    schedulePhotosRefresh()
                }
            }
            do {
                let generation = photoLibraryChangeGeneration
                authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                guard authorizationStatus == .authorized else { throw PhotosReviewError.fullAccessRequired }
                await prepareAlbumBindings()
                guard resolvedAlbums.count == DestinationRole.allCases.count else {
                    bindingStep = albumBindingSteps.first
                    screen = .albumBinding
                    presentError("Bind all three review albums before checking conflicts. Your staged choices remain saved.")
                    return
                }
                let membership = try fetchAllDestinationMembership()
                try reconcilePending(with: membership)
                if generation == photoLibraryChangeGeneration { libraryChanged = false }
                presentMessage("Photos membership was refreshed. Staged conflicts were retained for any item that still disagrees.")
            } catch { presentError("Could not recheck review albums: \(error.localizedDescription)") }
        }
    }

    func returnHome() {
        guard !isCommitting else {
            presentError("Wait for the Photos commit to finish before leaving the review.")
            return
        }
        invalidateWorkflow()
        screen = .home
        reloadPending()
    }
    func onForeground() {
        sceneIsActive = true
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorizationStatus == .authorized, screen != .home {
            schedulePhotosRefresh()
        } else if authorizationStatus != .authorized {
            libraryChanged = false
        }
        reloadPending()
    }
    func onBackground() {
        sceneIsActive = false
        invalidateWorkflow()
        photoLibraryRefreshTask?.cancel()
        previewTask?.cancel()
        currentVideoPlayer?.pause()
    }
    func selectNextPending() {
        guard !pendingRows.isEmpty else { return }
        let currentID = pendingSelection?.assetID
        let index = currentID.flatMap { id in pendingRows.firstIndex(where: { $0.assetID == id }) } ?? -1
        let next = pendingRows[(index + 1) % pendingRows.count]
        openPendingItem(next)
    }
    func target(for decision: ReviewDecision) -> DestinationRole { destination(for: decision) }
    func presentError(_ message: String) { alertMessage = message; showAlert = true }
    func presentMessage(_ message: String) { alertMessage = message; showAlert = true }
    func presentStatus(_ message: String) {
        statusGeneration &+= 1
        let generation = statusGeneration
        statusMessage = message
        UIAccessibility.post(notification: .announcement, argument: message)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.statusGeneration == generation else { return }
            self.statusMessage = nil
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.schedulePhotosRefresh() }
    }

    private func schedulePhotosRefresh() {
        photoLibraryChangeGeneration &+= 1
        libraryChanged = true
        guard sceneIsActive, authorizationStatus == .authorized, screen != .home else { return }
        photoLibraryRefreshTask?.cancel()
        photoLibraryRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.sceneIsActive else { return }
            guard !self.isScanning, !self.isCommitting, !self.isRecheckingPhotos else { return }
            await self.refreshAfterPhotosChange()
        }
    }

    private func refreshAfterPhotosChange() async {
        let generation = photoLibraryChangeGeneration
        switch screen {
        case .home:
            return
        case .review:
            scanCurrentScope()
        case .albumBinding:
            await prepareAlbumBindings()
            bindingStep = albumBindingSteps.first
            if generation == photoLibraryChangeGeneration { libraryChanged = false }
        case .pending, .pendingReview, .conflicts:
            await prepareAlbumBindings()
            guard resolvedAlbums.count == DestinationRole.allCases.count else {
                bindingStep = albumBindingSteps.first
                screen = .albumBinding
                return
            }
            do {
                try reconcilePending(with: fetchAllDestinationMembership())
                if let selectedID = pendingSelection?.assetID {
                    pendingSelection = pendingRows.first(where: { $0.assetID == selectedID })
                }
                if generation == photoLibraryChangeGeneration {
                    libraryChanged = false
                } else {
                    schedulePhotosRefresh()
                }
            } catch {
                presentError("Photos changed, but the staged queue could not be reconciled: \(error.localizedDescription)")
            }
        }
    }

    private func performPhotoChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: PhotosReviewError.photoChangeFailed) }
            }
        }
    }
}

enum PhotosReviewError: LocalizedError {
    case fullAccessRequired
    case albumUnavailable(DestinationRole)
    case sourceAlbumUnavailable
    case photoChangeFailed

    var errorDescription: String? {
        switch self {
        case .fullAccessRequired: "Full Photos access is required for this operation."
        case .albumUnavailable(let role): "The \(role.rawValue) review album is unavailable. Rebind it before continuing."
        case .sourceAlbumUnavailable: "The selected source album is unavailable. Choose another album and scan again."
        case .photoChangeFailed: "Photos could not complete the requested album update."
        }
    }
}
