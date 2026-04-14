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
        progress: @escaping @MainActor (ScanProgress) -> Void
    ) async throws -> ScanResult {
        switch settings.selectedSourceKind {
        case .photos:
            let (items, photoAssetLookup) = try photoLibraryService.fetchReviewItems(settings: settings)
            return try await scan(
                items: items,
                photoAssetLookup: photoAssetLookup,
                skippedHiddenCount: 0,
                skippedUnsupportedCount: 0,
                skippedPackageCount: 0,
                skippedSymlinkDirectoryCount: 0,
                maxTimeGapSeconds: settings.maxTimeGapSeconds,
                similarityDistanceThreshold: settings.similarityDistanceThreshold,
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
                photoAssetLookup: [:],
                skippedHiddenCount: listing.skippedHiddenCount,
                skippedUnsupportedCount: listing.skippedUnsupportedCount,
                skippedPackageCount: listing.skippedPackageCount,
                skippedSymlinkDirectoryCount: listing.skippedSymlinkDirectoryCount,
                maxTimeGapSeconds: settings.maxTimeGapSeconds,
                similarityDistanceThreshold: settings.similarityDistanceThreshold,
                progress: progress
            )
        }
    }

    private func scan(
        items: [ReviewItem],
        photoAssetLookup: [String: PHAsset],
        skippedHiddenCount: Int,
        skippedUnsupportedCount: Int,
        skippedPackageCount: Int,
        skippedSymlinkDirectoryCount: Int,
        maxTimeGapSeconds: TimeInterval,
        similarityDistanceThreshold: Float,
        progress: @escaping @MainActor (ScanProgress) -> Void
    ) async throws -> ScanResult {
        if items.isEmpty {
            await progress(.init(fractionCompleted: 1.0, message: "Not enough media in scope to compare."))
            return ScanResult(
                groups: [],
                itemLookup: [:],
                photoAssetLookup: photoAssetLookup,
                scannedItemCount: 0,
                temporalClusterCount: 0,
                skippedHiddenCount: skippedHiddenCount,
                skippedUnsupportedCount: skippedUnsupportedCount,
                skippedPackageCount: skippedPackageCount,
                skippedSymlinkDirectoryCount: skippedSymlinkDirectoryCount
            )
        }

        await progress(.init(fractionCompleted: 0.05, message: "Building time-near candidate groups..."))

        let temporalClusters = buildTemporalClusters(
            from: items,
            maxGapSeconds: maxTimeGapSeconds
        )

        var featurePrintCache: [String: VNFeaturePrintObservation] = [:]
        var outputGroups: [ReviewGroup] = []
        let itemLookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let clusterCount = max(1, temporalClusters.count)

        for (clusterIndex, cluster) in temporalClusters.enumerated() {
            try Task.checkCancellation()

            let fraction = 0.10 + (Double(clusterIndex) / Double(clusterCount)) * 0.82
            await progress(
                .init(
                    fractionCompleted: min(0.96, fraction),
                    message: "Analyzing group \(clusterIndex + 1) of \(clusterCount)..."
                )
            )

            if cluster.count == 1, let onlyItem = cluster.first {
                let onlyDate = onlyItem.preferredDate
                outputGroups.append(
                    ReviewGroup(
                        itemIDs: [onlyItem.id],
                        startDate: onlyDate,
                        endDate: onlyDate
                    )
                )
                continue
            }

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

            let reviewGroups = try similarityComponents(
                in: cluster,
                observations: observations,
                threshold: similarityDistanceThreshold
            )

            outputGroups.append(contentsOf: reviewGroups)
        }

        outputGroups.sort { lhs, rhs in
            (lhs.startDate ?? .distantPast) < (rhs.startDate ?? .distantPast)
        }

        await progress(
            .init(
                fractionCompleted: 1.0,
                message: "Scan complete. Found \(outputGroups.count) review groups."
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
            skippedSymlinkDirectoryCount: skippedSymlinkDirectoryCount
        )
    }

    private func buildTemporalClusters(
        from items: [ReviewItem],
        maxGapSeconds: TimeInterval
    ) -> [[ReviewItem]] {
        let sorted = items.sorted { lhs, rhs in
            lhs.sortDate < rhs.sortDate
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
            .sorted { lhs, rhs in lhs.sortDate < rhs.sortDate }
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

                for neighbor in edges[current, default: []] where !visited.contains(neighbor) {
                    stack.append(neighbor)
                }
            }

            let sortedComponentIDs = componentIDs.sorted { lhs, rhs in
                (itemsByID[lhs]?.preferredDate ?? .distantPast) < (itemsByID[rhs]?.preferredDate ?? .distantPast)
            }

            let refinedComponents = try refineConnectedComponent(sortedIDs: sortedComponentIDs, edges: edges)

            for refinedIDs in refinedComponents {
                let componentItems = refinedIDs.compactMap { itemsByID[$0] }.sorted { lhs, rhs in
                    (lhs.preferredDate ?? .distantPast) < (rhs.preferredDate ?? .distantPast)
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
