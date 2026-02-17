import Foundation
import Photos
import Vision

final class SimilarityScanner: @unchecked Sendable {
    private let libraryService: PhotoLibraryService

    init(libraryService: PhotoLibraryService) {
        self.libraryService = libraryService
    }

    func scan(
        settings: ScanSettings,
        progress: @escaping @MainActor (ScanProgress) -> Void
    ) async throws -> ScanResult {
        let assets = try libraryService.fetchAssets(settings: settings)

        if assets.isEmpty {
            await progress(.init(fractionCompleted: 1.0, message: "Not enough photos in scope to compare."))
            return ScanResult(
                groups: [],
                assetLookup: Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) }),
                scannedAssetCount: assets.count,
                temporalClusterCount: 0
            )
        }

        await progress(.init(fractionCompleted: 0.05, message: "Building time-near candidate groups..."))

        let temporalClusters = buildTemporalClusters(
            from: assets,
            maxGapSeconds: settings.maxTimeGapSeconds
        )

        var featurePrintCache: [String: VNFeaturePrintObservation] = [:]
        var outputGroups: [ReviewGroup] = []
        var assetLookup: [String: PHAsset] = [:]
        assets.forEach { assetLookup[$0.localIdentifier] = $0 }

        let clusterCount = max(1, temporalClusters.count)

        for (clusterIndex, cluster) in temporalClusters.enumerated() {
            try Task.checkCancellation()

            let fraction = 0.10 + (Double(clusterIndex) / Double(clusterCount)) * 0.80
            await progress(
                .init(
                    fractionCompleted: min(0.92, fraction),
                    message: "Analyzing group \(clusterIndex + 1) of \(clusterCount)..."
                )
            )

            if cluster.count == 1, let onlyAsset = cluster.first {
                let onlyDate = onlyAsset.creationDate ?? .distantPast
                outputGroups.append(
                    ReviewGroup(
                        assetIDs: [onlyAsset.localIdentifier],
                        startDate: onlyDate,
                        endDate: onlyDate
                    )
                )
                continue
            }

            let observations = try await featurePrints(
                for: cluster,
                cache: &featurePrintCache
            )

            let reviewGroups = similarityComponents(
                in: cluster,
                observations: observations,
                threshold: settings.similarityDistanceThreshold
            )

            outputGroups.append(contentsOf: reviewGroups)
        }

        outputGroups.sort { lhs, rhs in
            lhs.startDate < rhs.startDate
        }

        await progress(
            .init(
                fractionCompleted: 1.0,
                message: "Scan complete. Found \(outputGroups.count) review groups."
            )
        )

        return ScanResult(
            groups: outputGroups,
            assetLookup: assetLookup,
            scannedAssetCount: assets.count,
            temporalClusterCount: temporalClusters.count
        )
    }

    private func buildTemporalClusters(
        from assets: [PHAsset],
        maxGapSeconds: TimeInterval
    ) -> [[PHAsset]] {
        let sorted = assets.sorted { lhs, rhs in
            (lhs.creationDate ?? .distantPast) < (rhs.creationDate ?? .distantPast)
        }

        guard !sorted.isEmpty else {
            return []
        }

        var clusters: [[PHAsset]] = []
        var currentCluster: [PHAsset] = [sorted[0]]

        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let current = sorted[index]
            let previousDate = previous.creationDate ?? .distantPast
            let currentDate = current.creationDate ?? .distantFuture

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
        for assets: [PHAsset],
        cache: inout [String: VNFeaturePrintObservation]
    ) async throws -> [String: VNFeaturePrintObservation] {
        var output: [String: VNFeaturePrintObservation] = [:]
        output.reserveCapacity(assets.count)

        for asset in assets {
            try Task.checkCancellation()
            let id = asset.localIdentifier

            if let cached = cache[id] {
                output[id] = cached
                continue
            }

            guard
                let cgImage = await libraryService.requestCGImage(
                    for: asset,
                    targetSize: CGSize(width: 320, height: 320)
                )
            else {
                continue
            }

            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                continue
            }

            cache[id] = observation
            output[id] = observation
        }

        return output
    }

    private func similarityComponents(
        in cluster: [PHAsset],
        observations: [String: VNFeaturePrintObservation],
        threshold: Float
    ) -> [ReviewGroup] {
        let assetsByID = Dictionary(uniqueKeysWithValues: cluster.map { ($0.localIdentifier, $0) })
        let allIDs = cluster.map(\.localIdentifier)
        guard !allIDs.isEmpty else { return [] }

        var edges: [String: Set<String>] = [:]
        allIDs.forEach { edges[$0] = [] }

        for firstIndex in 0..<allIDs.count {
            let idA = allIDs[firstIndex]
            guard let assetA = assetsByID[idA] else { continue }

            for secondIndex in (firstIndex + 1)..<allIDs.count {
                let idB = allIDs[secondIndex]
                guard let assetB = assetsByID[idB] else { continue }

                let isSameBurst: Bool = {
                    guard let burstA = assetA.burstIdentifier, !burstA.isEmpty else { return false }
                    guard let burstB = assetB.burstIdentifier, !burstB.isEmpty else { return false }
                    return burstA == burstB
                }()

                if isSameBurst {
                    edges[idA, default: []].insert(idB)
                    edges[idB, default: []].insert(idA)
                    continue
                }

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
        var groups: [ReviewGroup] = []

        for startID in allIDs where !visited.contains(startID) {
            var stack: [String] = [startID]
            var componentIDs: [String] = []

            while let current = stack.popLast() {
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
                (assetsByID[lhs]?.creationDate ?? .distantPast) < (assetsByID[rhs]?.creationDate ?? .distantPast)
            }

            // Split each connected component into stricter subgroups so every member
            // is directly similar to all others in that subgroup (not just connected by chain).
            let refinedComponents = refineConnectedComponent(sortedIDs: sortedComponentIDs, edges: edges)

            for refinedIDs in refinedComponents {
                let componentAssets = refinedIDs.compactMap { assetsByID[$0] }.sorted { lhs, rhs in
                    (lhs.creationDate ?? .distantPast) < (rhs.creationDate ?? .distantPast)
                }

                guard let firstDate = componentAssets.first?.creationDate,
                      let lastDate = componentAssets.last?.creationDate else {
                    continue
                }

                groups.append(
                    ReviewGroup(
                        assetIDs: componentAssets.map(\.localIdentifier),
                        startDate: firstDate,
                        endDate: lastDate
                    )
                )
            }
        }

        return groups
    }

    private func refineConnectedComponent(
        sortedIDs: [String],
        edges: [String: Set<String>]
    ) -> [[String]] {
        var refined: [[String]] = []

        for candidateID in sortedIDs {
            let candidateNeighbors = edges[candidateID, default: []]
            var inserted = false

            for index in refined.indices {
                let existingGroup = refined[index]
                // Candidate can join only if it is directly similar to every existing member.
                if existingGroup.allSatisfy({ candidateNeighbors.contains($0) }) {
                    refined[index].append(candidateID)
                    inserted = true
                    break
                }
            }

            if !inserted {
                refined.append([candidateID])
            }
        }

        return refined
    }
}
