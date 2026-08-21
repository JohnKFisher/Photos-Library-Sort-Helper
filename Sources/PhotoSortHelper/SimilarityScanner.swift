import Foundation
import Photos
import Vision

final class SimilarityScanner: @unchecked Sendable {
    private let photoLibraryService: PhotoLibraryService
    private let folderLibraryService: FolderLibraryService

    init(
        photoLibraryService: PhotoLibraryService,
        folderLibraryService: FolderLibraryService
    ) {
        self.photoLibraryService = photoLibraryService
        self.folderLibraryService = folderLibraryService
    }

    func scan(
        settings: ScanSettings,
        continuation: ScanBatchCheckpoint? = nil,
        progress: @escaping @MainActor (ScanProgress) -> Void
    ) async throws -> ScanResult {
        if let continuation {
            guard
                continuation.sourceKey == ScanBatcher.makeSourceKey(settings: settings),
                continuation.groupingFingerprint == ScanBatcher.groupingFingerprint(settings: settings)
            else {
                throw ScanBatchError.incompatibleContinuation
            }

            switch settings.selectedSourceKind {
            case .photos:
                let identifiers = continuation.frozenItems.compactMap(\.photoLocalIdentifier)
                let photoAssetLookup = photoLibraryService.fetchAssetsByLocalIdentifier(identifiers)
                let items = continuation.frozenItems.filter { item in
                    guard let identifier = item.photoLocalIdentifier else { return false }
                    return photoAssetLookup[identifier] != nil
                }
                return try await scan(
                    items: items,
                    frozenItems: continuation.frozenItems,
                    continuation: continuation,
                    photoAssetLookup: photoAssetLookup,
                    skippedHiddenCount: 0,
                    skippedUnsupportedCount: 0,
                    skippedPackageCount: 0,
                    skippedSymlinkDirectoryCount: 0,
                    maxTimeGapSeconds: settings.maxTimeGapSeconds,
                    similarityDistanceThreshold: settings.similarityDistanceThreshold,
                    groupLimit: settings.validatedGroupLimit,
                    sourceKey: ScanBatcher.makeSourceKey(settings: settings),
                    groupingFingerprint: ScanBatcher.groupingFingerprint(settings: settings),
                    progress: progress
                )

            case .folder:
                let existing = folderLibraryService.existingItems(from: continuation.frozenItems)
                let existingIDs = Set(existing.map(\.id))
                let items = continuation.frozenItems.filter { existingIDs.contains($0.id) }
                return try await scan(
                    items: items,
                    frozenItems: continuation.frozenItems,
                    continuation: continuation,
                    photoAssetLookup: [:],
                    skippedHiddenCount: 0,
                    skippedUnsupportedCount: 0,
                    skippedPackageCount: 0,
                    skippedSymlinkDirectoryCount: 0,
                    maxTimeGapSeconds: settings.maxTimeGapSeconds,
                    similarityDistanceThreshold: settings.similarityDistanceThreshold,
                    groupLimit: settings.validatedGroupLimit,
                    sourceKey: ScanBatcher.makeSourceKey(settings: settings),
                    groupingFingerprint: ScanBatcher.groupingFingerprint(settings: settings),
                    progress: progress
                )
            }
        }

        switch settings.selectedSourceKind {
        case .photos:
            let (items, photoAssetLookup) = try photoLibraryService.fetchReviewItems(settings: settings)
            return try await scan(
                items: items,
                frozenItems: items,
                continuation: nil,
                photoAssetLookup: photoAssetLookup,
                skippedHiddenCount: 0,
                skippedUnsupportedCount: 0,
                skippedPackageCount: 0,
                skippedSymlinkDirectoryCount: 0,
                maxTimeGapSeconds: settings.maxTimeGapSeconds,
                similarityDistanceThreshold: settings.similarityDistanceThreshold,
                groupLimit: settings.validatedGroupLimit,
                sourceKey: ScanBatcher.makeSourceKey(settings: settings),
                groupingFingerprint: ScanBatcher.groupingFingerprint(settings: settings),
                progress: progress
            )

        case .folder:
            let listing = try await folderLibraryService.loadReviewItems(
                selection: settings.folderSelection,
                recursive: settings.folderRecursiveScan,
                includeVideos: settings.includeVideos
            )

            return try await scan(
                items: listing.items,
                frozenItems: listing.items,
                continuation: nil,
                photoAssetLookup: [:],
                skippedHiddenCount: listing.skippedHiddenCount,
                skippedUnsupportedCount: listing.skippedUnsupportedCount,
                skippedPackageCount: listing.skippedPackageCount,
                skippedSymlinkDirectoryCount: listing.skippedSymlinkDirectoryCount,
                maxTimeGapSeconds: settings.maxTimeGapSeconds,
                similarityDistanceThreshold: settings.similarityDistanceThreshold,
                groupLimit: settings.validatedGroupLimit,
                sourceKey: ScanBatcher.makeSourceKey(settings: settings),
                groupingFingerprint: ScanBatcher.groupingFingerprint(settings: settings),
                progress: progress
            )
        }
    }

    private func scan(
        items: [ReviewItem],
        frozenItems: [ReviewItem],
        continuation: ScanBatchCheckpoint?,
        photoAssetLookup: [String: PHAsset],
        skippedHiddenCount: Int,
        skippedUnsupportedCount: Int,
        skippedPackageCount: Int,
        skippedSymlinkDirectoryCount: Int,
        maxTimeGapSeconds: TimeInterval,
        similarityDistanceThreshold: Float,
        groupLimit: Int?,
        sourceKey: String,
        groupingFingerprint: String,
        progress: @escaping @MainActor (ScanProgress) -> Void
    ) async throws -> ScanResult {
        if items.isEmpty {
            await progress(.init(fractionCompleted: 1.0, message: "Not enough media in scope to compare."))
            let emptyCheckpoint: ScanBatchCheckpoint? = groupLimit.map { _ in
                ScanBatchCheckpoint(
                    sourceKey: sourceKey,
                    groupingFingerprint: groupingFingerprint,
                    frozenItems: frozenItems,
                    pendingGroups: [],
                    remainingItemIDs: [],
                    batchNumber: continuation.map { $0.batchNumber + 1 } ?? 1,
                    hasMore: false,
                    readyForNextBatch: false
                )
            }
            return ScanResult(
                groups: [],
                itemLookup: [:],
                photoAssetLookup: photoAssetLookup,
                scannedItemCount: 0,
                temporalClusterCount: 0,
                skippedHiddenCount: skippedHiddenCount,
                skippedUnsupportedCount: skippedUnsupportedCount,
                skippedPackageCount: skippedPackageCount,
                skippedSymlinkDirectoryCount: skippedSymlinkDirectoryCount,
                didReachGroupLimit: false,
                continuation: emptyCheckpoint
            )
        }

        await progress(.init(fractionCompleted: 0.05, message: "Building time-near candidate groups..."))

        let availableIDs = Set(items.map(\.id))
        let remainingIDs = continuation.map { Set($0.remainingItemIDs) } ?? availableIDs
        let remainingItems = items.filter { remainingIDs.contains($0.id) }
        let temporalClusters = buildTemporalClusters(from: remainingItems, maxGapSeconds: maxTimeGapSeconds)
        var featurePrintCache: [String: VNFeaturePrintObservation] = [:]
        var outputGroups: [ReviewGroup] = []
        let itemLookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let clusterCount = max(1, temporalClusters.count)
        let limit = groupLimit.map { min(max($0, 1), 10_000) }
        var pendingGroups = (continuation?.pendingGroups ?? []).compactMap { group -> ReviewGroup? in
            let validIDs = group.itemIDs.filter { availableIDs.contains($0) }
            guard !validIDs.isEmpty else { return nil }
            return ScanBatcher.normalizedGroup(
                ReviewGroup(id: group.id, itemIDs: validIDs, startDate: group.startDate, endDate: group.endDate)
            )
        }.sorted(by: ScanBatcher.stableGroupOrder)
        var unprocessedItemIDs = temporalClusters.flatMap { $0.map(\.id) }

        if let limit, !pendingGroups.isEmpty {
            let pendingPartition = ScanBatcher.partition(groups: pendingGroups, limit: limit)
            outputGroups.append(contentsOf: pendingPartition.selected)
            pendingGroups = pendingPartition.pending
        }

        for (clusterIndex, cluster) in temporalClusters.enumerated() {
            try Task.checkCancellation()

            if let limit, outputGroups.count >= limit {
                break
            }

            let fraction = 0.10 + (Double(clusterIndex) / Double(clusterCount)) * 0.82
            await progress(
                .init(
                    fractionCompleted: min(0.96, fraction),
                    message: "Analyzing group \(clusterIndex + 1) of \(clusterCount)..."
                )
            )

            let reviewGroups: [ReviewGroup]
            if cluster.count == 1, let onlyItem = cluster.first {
                let onlyDate = onlyItem.preferredDate
                reviewGroups = [
                    ReviewGroup(
                        itemIDs: [onlyItem.id],
                        startDate: onlyDate,
                        endDate: onlyDate
                    )
                ]
            } else {
                let imageCluster = cluster.filter { $0.mediaKind == .image }
                let observations: [String: VNFeaturePrintObservation]
                if imageCluster.isEmpty {
                    observations = [:]
                } else {
                    observations = try await featurePrints(
                        for: imageCluster,
                        photoAssetLookup: photoAssetLookup,
                        cache: &featurePrintCache
                    )
                }

                reviewGroups = try similarityComponents(
                    in: cluster,
                    observations: observations,
                    threshold: similarityDistanceThreshold
                )
            }

            unprocessedItemIDs.removeAll { id in cluster.contains(where: { $0.id == id }) }
            let normalizedGroups = reviewGroups.map(ScanBatcher.normalizedGroup).sorted(by: ScanBatcher.stableGroupOrder)
            if let limit {
                let capacity = max(0, limit - outputGroups.count)
                let partition = ScanBatcher.partition(groups: normalizedGroups, limit: capacity)
                outputGroups.append(contentsOf: partition.selected)
                pendingGroups.append(contentsOf: partition.pending)
            } else {
                outputGroups.append(contentsOf: normalizedGroups)
            }

            if let limit, outputGroups.count >= limit {
                break
            }
        }

        outputGroups.sort(by: ScanBatcher.stableGroupOrder)
        let hasMore = !pendingGroups.isEmpty || !unprocessedItemIDs.isEmpty
        let batchNumber = continuation.map { $0.batchNumber + 1 } ?? 1
        let checkpoint: ScanBatchCheckpoint? = limit.map { _ in
            ScanBatchCheckpoint(
                sourceKey: sourceKey,
                groupingFingerprint: groupingFingerprint,
                frozenItems: frozenItems.sorted {
                    if $0.sortDate != $1.sortDate { return $0.sortDate < $1.sortDate }
                    return $0.id < $1.id
                },
                pendingGroups: pendingGroups,
                remainingItemIDs: unprocessedItemIDs,
                batchNumber: batchNumber,
                hasMore: hasMore,
                readyForNextBatch: false
            )
        }

        await progress(
            .init(
                fractionCompleted: 1.0,
                message: limit != nil
                    ? "Batch \(batchNumber) complete. Found \(outputGroups.count) review groups."
                    : "Scan complete. Found \(outputGroups.count) review groups."
            )
        )

        return ScanResult(
            groups: outputGroups,
            itemLookup: itemLookup,
            photoAssetLookup: photoAssetLookup,
            scannedItemCount: items.count,
            temporalClusterCount: temporalClusters.count,
            skippedHiddenCount: skippedHiddenCount,
            skippedUnsupportedCount: skippedUnsupportedCount,
            skippedPackageCount: skippedPackageCount,
            skippedSymlinkDirectoryCount: skippedSymlinkDirectoryCount,
            didReachGroupLimit: hasMore,
            continuation: checkpoint
        )
    }

    private func buildTemporalClusters(
        from items: [ReviewItem],
        maxGapSeconds: TimeInterval
    ) -> [[ReviewItem]] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.sortDate != rhs.sortDate { return lhs.sortDate < rhs.sortDate }
            return lhs.id < rhs.id
        }

        guard !sorted.isEmpty else {
            return []
        }

        var clusters: [[ReviewItem]] = []
        var currentCluster: [ReviewItem] = [sorted[0]]

        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let current = sorted[index]
            let previousDate = previous.preferredDate ?? .distantPast
            let currentDate = current.preferredDate ?? .distantFuture

            if currentDate.timeIntervalSince(previousDate) <= maxGapSeconds {
                currentCluster.append(current)
            } else {
                clusters.append(currentCluster)
                currentCluster = [current]
            }
        }

        clusters.append(currentCluster)
        return clusters
    }

    private func featurePrints(
        for items: [ReviewItem],
        photoAssetLookup: [String: PHAsset],
        cache: inout [String: VNFeaturePrintObservation]
    ) async throws -> [String: VNFeaturePrintObservation] {
        var output: [String: VNFeaturePrintObservation] = [:]
        output.reserveCapacity(items.count)

        for item in items {
            try Task.checkCancellation()

            if let cached = cache[item.id] {
                output[item.id] = cached
                continue
            }

            guard let cgImage = await featurePrintCGImage(for: item, photoAssetLookup: photoAssetLookup) else {
                continue
            }

            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                continue
            }

            cache[item.id] = observation
            output[item.id] = observation
        }

        return output
    }

    private func featurePrintCGImage(
        for item: ReviewItem,
        photoAssetLookup: [String: PHAsset]
    ) async -> CGImage? {
        switch item.source {
        case .photoAsset(let localIdentifier):
            guard let asset = photoAssetLookup[localIdentifier] else {
                return nil
            }
            return await photoLibraryService.requestCGImage(
                for: asset,
                targetSize: CGSize(width: 320, height: 320)
            )

        case .file:
            return await folderLibraryService.featurePrintCGImage(for: item)
        }
    }

    private func similarityComponents(
        in cluster: [ReviewItem],
        observations: [String: VNFeaturePrintObservation],
        threshold: Float
    ) throws -> [ReviewGroup] {
        var groups: [ReviewGroup] = []

        let videoItems = cluster
            .filter(\.isVideo)
            .sorted {
                if $0.sortDate != $1.sortDate { return $0.sortDate < $1.sortDate }
                return $0.id < $1.id
            }
        for videoItem in videoItems {
            let date = videoItem.preferredDate
            groups.append(
                ReviewGroup(
                    itemIDs: [videoItem.id],
                    startDate: date,
                    endDate: date
                )
            )
        }

        let imageItems = cluster.filter { $0.mediaKind == .image }
        guard !imageItems.isEmpty else {
            return groups
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: imageItems.map { ($0.id, $0) })
        let allIDs = imageItems.map(\.id)

        var edges: [String: Set<String>] = [:]
        allIDs.forEach { edges[$0] = [] }

        for firstIndex in 0..<allIDs.count {
            if firstIndex.isMultiple(of: 12) {
                try Task.checkCancellation()
            }
            let idA = allIDs[firstIndex]

            for secondIndex in (firstIndex + 1)..<allIDs.count {
                if secondIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let idB = allIDs[secondIndex]

                guard
                    let observationA = observations[idA],
                    let observationB = observations[idB]
                else {
                    continue
                }

                var distance: Float = 0
                do {
                    try observationA.computeDistance(&distance, to: observationB)
                } catch {
                    continue
                }

                if distance <= threshold {
                    edges[idA, default: []].insert(idB)
                    edges[idB, default: []].insert(idA)
                }
            }
        }

        var visited: Set<String> = []

        for (componentIndex, startID) in allIDs.enumerated() where !visited.contains(startID) {
            if componentIndex.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            var stack: [String] = [startID]
            var componentIDs: [String] = []

            while let current = stack.popLast() {
                if componentIDs.count.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                if visited.contains(current) {
                    continue
                }

                visited.insert(current)
                componentIDs.append(current)

                for neighbor in edges[current, default: []].sorted().reversed() where !visited.contains(neighbor) {
                    stack.append(neighbor)
                }
            }

            let sortedComponentIDs = componentIDs.sorted { lhs, rhs in
                let leftDate = itemsByID[lhs]?.preferredDate ?? .distantPast
                let rightDate = itemsByID[rhs]?.preferredDate ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return lhs < rhs
            }

            let refinedComponents = try refineConnectedComponent(sortedIDs: sortedComponentIDs, edges: edges)

            for refinedIDs in refinedComponents {
                let componentItems = refinedIDs.compactMap { itemsByID[$0] }.sorted { lhs, rhs in
                    let leftDate = lhs.preferredDate ?? .distantPast
                    let rightDate = rhs.preferredDate ?? .distantPast
                    if leftDate != rightDate { return leftDate < rightDate }
                    return lhs.id < rhs.id
                }

                groups.append(
                    ReviewGroup(
                        itemIDs: componentItems.map(\.id),
                        startDate: componentItems.first?.preferredDate,
                        endDate: componentItems.last?.preferredDate
                    )
                )
            }
        }

        return groups
    }

    private func refineConnectedComponent(
        sortedIDs: [String],
        edges: [String: Set<String>]
    ) throws -> [[String]] {
        var refined: [[String]] = []

        for (candidateIndex, candidateID) in sortedIDs.enumerated() {
            if candidateIndex.isMultiple(of: 32) {
                try Task.checkCancellation()
            }

            if let existingIndex = refined.firstIndex(where: { existing in
                existing.contains(where: { edges[$0, default: []].contains(candidateID) || $0 == candidateID })
            }) {
                refined[existingIndex].append(candidateID)
            } else {
                refined.append([candidateID])
            }
        }

        return refined
    }
}
