import Foundation
import Photos
import PhotosSortCore

/// Builds deterministic time groups. Media inspection is deliberately left to the
/// visible review surface; discovery never downloads thumbnails or ranks images.
final class SimilarityScanner: @unchecked Sendable {
    private let photoLibraryService: PhotoLibraryService
    private let folderLibraryService: FolderLibraryService

    init(photoLibraryService: PhotoLibraryService, folderLibraryService: FolderLibraryService) {
        self.photoLibraryService = photoLibraryService
        self.folderLibraryService = folderLibraryService
    }

    func scan(
        settings: ScanSettings,
        continuation: ScanBatchCheckpoint? = nil,
        photosExcludedItemIDs: Set<String> = [],
        progress: @escaping @MainActor (ScanProgress) -> Void
    ) async throws -> ScanResult {
        let sourceKey = ScanBatcher.makeSourceKey(settings: settings)
        let groupIdentityScope = ScanBatcher.makeGroupIdentityScope(settings: settings)
        let groupingFingerprint = ScanBatcher.groupingFingerprint(settings: settings)
        if let continuation {
            guard continuation.sourceKey == sourceKey,
                  continuation.groupingFingerprint == groupingFingerprint else {
                throw ScanBatchError.incompatibleContinuation
            }
        }

        var skippedHiddenCount = 0
        var skippedUnsupportedCount = 0
        var skippedPackageCount = 0
        var skippedSymlinkDirectoryCount = 0
        var photoAssetLookup: [String: PHAsset] = [:]
        let frozenItems: [ReviewItem]
        let itemLookup: [String: ReviewItem]

        if let continuation {
            switch settings.selectedSourceKind {
            case .photos:
                photoAssetLookup = photoLibraryService.fetchAssetsByLocalIdentifier(
                    continuation.frozenItems.compactMap(\.photoLocalIdentifier)
                )
                frozenItems = continuation.frozenItems.filter { item in
                    guard let identifier = item.photoLocalIdentifier else { return false }
                    return photoAssetLookup[identifier] != nil && !photosExcludedItemIDs.contains(identifier)
                }
            case .folder:
                frozenItems = folderLibraryService.existingItems(from: continuation.frozenItems)
            }
            itemLookup = Dictionary(uniqueKeysWithValues: frozenItems.map { ($0.id, $0) })
        } else {
            switch settings.selectedSourceKind {
            case .photos:
                let fetched = try photoLibraryService.fetchReviewItems(settings: settings)
                photoAssetLookup = fetched.1
                frozenItems = fetched.0.filter { !photosExcludedItemIDs.contains($0.id) }
                itemLookup = Dictionary(uniqueKeysWithValues: frozenItems.map { ($0.id, $0) })
                photoAssetLookup = photoAssetLookup.filter { itemLookup[$0.key] != nil }
            case .folder:
                let listing = try await folderLibraryService.loadReviewItems(
                    selection: settings.folderSelection,
                    recursive: settings.folderRecursiveScan,
                    includeVideos: settings.includeVideos
                )
                frozenItems = listing.items
                itemLookup = Dictionary(uniqueKeysWithValues: frozenItems.map { ($0.id, $0) })
                skippedHiddenCount = listing.skippedHiddenCount
                skippedUnsupportedCount = listing.skippedUnsupportedCount
                skippedPackageCount = listing.skippedPackageCount
                skippedSymlinkDirectoryCount = listing.skippedSymlinkDirectoryCount
            }
        }

        try Task.checkCancellation()
        await progress(.init(fractionCompleted: 0.08, message: "Ordering media by capture time…"))

        let availableIDs = Set(frozenItems.map(\.id))
        let allGroups: [ReviewGroup]
        if let continuation {
            let pendingIDs = Set(continuation.pendingGroups.flatMap(\.itemIDs))
            var groups: [ReviewGroup] = continuation.pendingGroups.compactMap { saved -> ReviewGroup? in
                let validIDs = saved.itemIDs.filter { availableIDs.contains($0) && pendingIDs.contains($0) }
                guard !validIDs.isEmpty else { return nil }
                return ReviewGroup(id: saved.id, itemIDs: validIDs, startDate: saved.startDate, endDate: saved.endDate)
            }
            let remainingSet = Set(continuation.remainingItemIDs).intersection(availableIDs)
            if !remainingSet.isEmpty {
                let metadata = frozenItems.filter { remainingSet.contains($0.id) }.map { item in
                    ReviewMediaMetadata(
                        id: item.id,
                        preferredDate: item.preferredDate,
                        isVideo: item.isVideo,
                        isLivePhoto: item.badgeLabels.contains("Live Photo")
                    )
                }
                groups.append(contentsOf: TemporalGrouping.groups(
                    from: metadata,
                    maxGapSeconds: settings.maxTimeGapSeconds,
                    scopeID: groupIdentityScope
                ).map { snapshot in
                    ReviewGroup(id: stableUUID(from: snapshot.id), itemIDs: snapshot.itemIDs, startDate: snapshot.startDate, endDate: snapshot.endDate)
                })
            }
            allGroups = groups.sorted(by: ScanBatcher.stableGroupOrder)
        } else {
            let metadata = frozenItems.map { item in
                ReviewMediaMetadata(
                    id: item.id,
                    // Photos groups by capture date; a filesystem modification date is
                    // useful for Folder mode when capture metadata is absent.
                    preferredDate: item.preferredDate,
                    isVideo: item.isVideo,
                    isLivePhoto: item.badgeLabels.contains("Live Photo")
                )
            }
            let snapshots = TemporalGrouping.groups(
                from: metadata,
                maxGapSeconds: settings.maxTimeGapSeconds,
                scopeID: groupIdentityScope
            )
            allGroups = snapshots.map { snapshot in
                ReviewGroup(
                    id: stableUUID(from: snapshot.id),
                    itemIDs: snapshot.itemIDs,
                    startDate: snapshot.startDate,
                    endDate: snapshot.endDate
                )
            }
        }

        try Task.checkCancellation()
        let batch: (selected: [ReviewGroup], pending: [ReviewGroup])
        if let limit = settings.validatedGroupLimit {
            batch = ScanBatcher.partition(groups: allGroups, limit: limit)
        } else {
            batch = (allGroups, [])
        }

        let hasMore = !batch.pending.isEmpty
        let checkpoint = settings.validatedGroupLimit.map { _ in
            ScanBatchCheckpoint(
                sourceKey: sourceKey,
                groupingFingerprint: groupingFingerprint,
                frozenItems: frozenItems.sorted(by: stableItemOrder),
                pendingGroups: batch.pending,
                remainingItemIDs: [],
                batchNumber: continuation.map { $0.batchNumber + 1 } ?? 1,
                hasMore: hasMore,
                readyForNextBatch: false
            )
        }

        await progress(.init(
            fractionCompleted: 1,
            message: hasMore
                ? "Prepared \(batch.selected.count) oldest review groups. More groups are ready."
                : "Prepared \(batch.selected.count) oldest review groups."
        ))

        return ScanResult(
            groups: batch.selected,
            itemLookup: itemLookup,
            photoAssetLookup: photoAssetLookup,
            scannedItemCount: frozenItems.count,
            temporalClusterCount: allGroups.count,
            skippedHiddenCount: skippedHiddenCount,
            skippedUnsupportedCount: skippedUnsupportedCount,
            skippedPackageCount: skippedPackageCount,
            skippedSymlinkDirectoryCount: skippedSymlinkDirectoryCount,
            didReachGroupLimit: hasMore,
            continuation: checkpoint
        )
    }

    private func stableUUID(from hex: String) -> UUID {
        let value = String(hex.prefix(32)).lowercased()
        guard value.count == 32 else { return UUID() }
        let formatted = "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    private func stableItemOrder(_ lhs: ReviewItem, _ rhs: ReviewItem) -> Bool {
        let leftDate = lhs.preferredDate ?? .distantPast
        let rightDate = rhs.preferredDate ?? .distantPast
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.id < rhs.id
    }
}
