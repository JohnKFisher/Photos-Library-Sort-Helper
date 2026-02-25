import CoreImage
import Foundation
import Photos
import Vision

final class SimilarityScanner: @unchecked Sendable {
    private struct ImageStats {
        let meanLuma: Double
        let stdLuma: Double
        let colorfulness: Double
    }

    private struct FaceMetrics {
        let facePresence: Double
        let framing: Double
        let eyesOpen: Double
        let smile: Double
    }

    private struct SaliencyMetrics {
        let subjectProminence: Double
        let subjectCentering: Double
    }

    private struct FeatureSnapshot {
        let facePresence: Double
        let framing: Double
        let eyesOpen: Double
        let smile: Double
        let subjectProminence: Double
        let subjectCentering: Double
        let sharpness: Double
        let lighting: Double
        let color: Double
        let contrast: Double
    }

    private let libraryService: PhotoLibraryService
    private let ciContext = CIContext()

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
                bestAssetByGroupID: [:],
                suggestedDiscardAssetIDsByGroupID: [:],
                bestShotScoresByAssetID: [:],
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

            let imageCluster = cluster.filter { $0.mediaType == .image }
            let observations: [String: VNFeaturePrintObservation]
            if imageCluster.isEmpty {
                observations = [:]
            } else {
                observations = try await featurePrints(
                    for: imageCluster,
                    cache: &featurePrintCache
                )
            }

            let reviewGroups = try similarityComponents(
                in: cluster,
                observations: observations,
                threshold: settings.similarityDistanceThreshold
            )

            outputGroups.append(contentsOf: reviewGroups)
        }

        outputGroups.sort { lhs, rhs in
            lhs.startDate < rhs.startDate
        }

        var bestAssetByGroupID: [UUID: String] = [:]
        var suggestedDiscardAssetIDsByGroupID: [UUID: Set<String>] = [:]
        var bestShotScoresByAssetID: [String: BestShotScoreBreakdown] = [:]
        if settings.autoPickBestShot, !outputGroups.isEmpty {
            await progress(
                .init(
                    fractionCompleted: 0.94,
                    message: "Evaluating quality signals for best-shot suggestions..."
                )
            )
            let selections = try await bestShotSelections(
                groups: outputGroups,
                assetLookup: assetLookup,
                settings: settings,
                progress: progress
            )
            bestAssetByGroupID = selections.suggestions
            suggestedDiscardAssetIDsByGroupID = selections.suggestedDiscards
            bestShotScoresByAssetID = selections.scores
        }

        await progress(
            .init(
                fractionCompleted: 1.0,
                message: settings.autoPickBestShot
                    ? "Scan complete. Found \(outputGroups.count) review groups and suggested best shots."
                    : "Scan complete. Found \(outputGroups.count) review groups."
            )
        )

        return ScanResult(
            groups: outputGroups,
            bestAssetByGroupID: bestAssetByGroupID,
            suggestedDiscardAssetIDsByGroupID: suggestedDiscardAssetIDsByGroupID,
            bestShotScoresByAssetID: bestShotScoresByAssetID,
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
    ) throws -> [ReviewGroup] {
        var groups: [ReviewGroup] = []

        // Videos are always kept as single-item review groups.
        let videoAssets = cluster
            .filter { $0.mediaType == .video }
            .sorted { lhs, rhs in
                (lhs.creationDate ?? .distantPast) < (rhs.creationDate ?? .distantPast)
            }
        for video in videoAssets {
            let date = video.creationDate ?? .distantPast
            groups.append(
                ReviewGroup(
                    assetIDs: [video.localIdentifier],
                    startDate: date,
                    endDate: date
                )
            )
        }

        let imageAssets = cluster.filter { $0.mediaType == .image }
        guard !imageAssets.isEmpty else {
            return groups
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: imageAssets.map { ($0.localIdentifier, $0) })
        let allIDs = imageAssets.map(\.localIdentifier)

        var edges: [String: Set<String>] = [:]
        allIDs.forEach { edges[$0] = [] }

        for firstIndex in 0..<allIDs.count {
            if firstIndex.isMultiple(of: 12) {
                try Task.checkCancellation()
            }
            let idA = allIDs[firstIndex]
            guard let assetA = assetsByID[idA] else { continue }

            for secondIndex in (firstIndex + 1)..<allIDs.count {
                if secondIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
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
                (assetsByID[lhs]?.creationDate ?? .distantPast) < (assetsByID[rhs]?.creationDate ?? .distantPast)
            }

            // Split each connected component into stricter subgroups so every member
            // is directly similar to all others in that subgroup (not just connected by chain).
            let refinedComponents = try refineConnectedComponent(sortedIDs: sortedComponentIDs, edges: edges)

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
    ) throws -> [[String]] {
        var refined: [[String]] = []

        for (candidateIndex, candidateID) in sortedIDs.enumerated() {
            if candidateIndex.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
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

    private func bestShotSelections(
        groups: [ReviewGroup],
        assetLookup: [String: PHAsset],
        settings: ScanSettings,
        progress: @escaping @MainActor (ScanProgress) -> Void
    ) async throws -> (
        suggestions: [UUID: String],
        suggestedDiscards: [UUID: Set<String>],
        scores: [String: BestShotScoreBreakdown]
    ) {
        var suggestions: [UUID: String] = [:]
        var suggestedDiscards: [UUID: Set<String>] = [:]
        var scoreCache: [String: BestShotScoreBreakdown] = [:]
        var deepAestheticScoreCache: [String: Double] = [:]
        let total = max(1, groups.count)

        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()

            if index % 4 == 0 || index == total - 1 {
                let fraction = 0.94 + (Double(index) / Double(total)) * 0.05
                await progress(
                    .init(
                        fractionCompleted: min(0.99, fraction),
                        message: "Choosing best shot \(index + 1) of \(total)..."
                    )
                )
            }

            let imageIDs = group.assetIDs.filter { assetLookup[$0]?.mediaType == .image }
            if imageIDs.count == 1, let singletonImageID = imageIDs.first {
                if let cachedScore = scoreCache[singletonImageID] {
                    if shouldAutoDiscardSingleton(score: cachedScore) {
                        suggestedDiscards[group.id] = [singletonImageID]
                    }
                } else if let asset = assetLookup[singletonImageID] {
                    let score = await qualityScore(for: asset, settings: settings)
                    scoreCache[singletonImageID] = score

                    if shouldAutoDiscardSingleton(score: score) {
                        suggestedDiscards[group.id] = [singletonImageID]
                    }
                }
                continue
            }

            if let bestID = await bestShotAssetID(
                in: group,
                assetLookup: assetLookup,
                settings: settings,
                scoreCache: &scoreCache,
                deepAestheticScoreCache: &deepAestheticScoreCache
            ) {
                suggestions[group.id] = bestID
            }

            if index % 6 == 0 {
                await Task.yield()
            }
        }

        return (suggestions: suggestions, suggestedDiscards: suggestedDiscards, scores: scoreCache)
    }

    private func bestShotAssetID(
        in group: ReviewGroup,
        assetLookup: [String: PHAsset],
        settings: ScanSettings,
        scoreCache: inout [String: BestShotScoreBreakdown],
        deepAestheticScoreCache: inout [String: Double]
    ) async -> String? {
        let imageIDs = group.assetIDs.filter { assetLookup[$0]?.mediaType == .image }
        guard !imageIDs.isEmpty else {
            // Video-only groups do not receive auto-pick suggestions.
            return nil
        }

        var bestAssetID = imageIDs[0]
        var bestScore = -Double.infinity

        for assetID in imageIDs {
            let score: BestShotScoreBreakdown
            if let cached = scoreCache[assetID] {
                score = cached
            } else if let asset = assetLookup[assetID] {
                score = await qualityScore(for: asset, settings: settings)
                scoreCache[assetID] = score
            } else {
                continue
            }

            if score.totalScore > bestScore {
                bestScore = score.totalScore
                bestAssetID = assetID
            }
        }

        if settings.useDeepPassTieBreaker {
            let rankedIDs = imageIDs.sorted { lhs, rhs in
                (scoreCache[lhs]?.totalScore ?? -.infinity) > (scoreCache[rhs]?.totalScore ?? -.infinity)
            }

            if let topID = rankedIDs.first,
               let topScore = scoreCache[topID]?.totalScore {
                let closeCallIDs = Array(
                    rankedIDs
                        .filter { id in
                            guard let score = scoreCache[id]?.totalScore else {
                                return false
                            }
                            return (topScore - score) <= settings.deepPassCloseCallDelta
                        }
                )

                if closeCallIDs.count > 1 {
                    for assetID in closeCallIDs {
                        if deepAestheticScoreCache[assetID] != nil {
                            continue
                        }

                        guard let asset = assetLookup[assetID] else {
                            continue
                        }

                        if let deepScore = await deepAestheticScore(for: asset) {
                            deepAestheticScoreCache[assetID] = deepScore
                        }
                    }

                    let availableDeepIDs = closeCallIDs.filter { deepAestheticScoreCache[$0] != nil }
                    if availableDeepIDs.count > 1 {
                        var deepBestID = bestAssetID
                        var deepBestScore = -Double.infinity

                        for assetID in closeCallIDs {
                            guard var score = scoreCache[assetID] else {
                                continue
                            }

                            let deepScore = deepAestheticScoreCache[assetID]
                            if let deepScore {
                                score.aestheticsScore = deepScore
                                score.usedDeepPass = true
                                score.totalScore += settings.deepPassBlendWeight * (deepScore - 0.5)
                                scoreCache[assetID] = score
                            }

                            if score.totalScore > deepBestScore {
                                deepBestScore = score.totalScore
                                deepBestID = assetID
                            }
                        }

                        bestAssetID = deepBestID
                    }
                }
            }
        }

        return bestAssetID
    }

    private func qualityScore(
        for asset: PHAsset,
        settings: ScanSettings
    ) async -> BestShotScoreBreakdown {
        guard
            let cgImage = await libraryService.requestCGImage(
                for: asset,
                targetSize: CGSize(width: 720, height: 720),
                contentMode: .aspectFit
            )
        else {
            let fallbackFeatures = FeatureSnapshot(
                facePresence: 0.0,
                framing: 0.0,
                eyesOpen: 0.5,
                smile: 0.0,
                subjectProminence: 0.45,
                subjectCentering: 0.55,
                sharpness: 0.4,
                lighting: 0.4,
                color: 0.4,
                contrast: 0.4
            )
            let personalized = personalizedScore(
                baseHeuristicScore: 0.4,
                features: fallbackFeatures,
                settings: settings
            )
            return BestShotScoreBreakdown(
                totalScore: personalized.totalScore,
                baseHeuristicScore: 0.4,
                learnedPreferenceScore: personalized.learnedScore,
                learnedAdjustment: personalized.adjustment,
                facePresence: 0.0,
                framing: 0.0,
                eyesOpen: 0.5,
                smile: 0.0,
                subjectProminence: 0.45,
                subjectCentering: 0.55,
                sharpness: 0.4,
                lighting: 0.4,
                color: 0.4,
                contrast: 0.4,
                aestheticsScore: nil,
                usedDeepPass: false
            )
        }

        let ciImage = CIImage(cgImage: cgImage)
        let stats = imageStats(from: cgImage)
        let meanLuma = stats?.meanLuma ?? 0.5
        let lightingScore = clamp01(1.0 - (abs(meanLuma - 0.55) / 0.55))
        let contrastScore = clamp01((stats?.stdLuma ?? 0.14) / 0.22)
        let colorScore = clamp01((stats?.colorfulness ?? 0.11) / 0.35)
        let sharpnessScore = edgeSharpnessScore(for: ciImage)
        let saliencyMetrics = visionSaliencyMetrics(for: cgImage)
        let subjectProminenceScore = saliencyMetrics?.subjectProminence ?? 0.45
        let subjectCenteringScore = saliencyMetrics?.subjectCentering ?? 0.55

        let faceMetrics = visionFaceMetrics(for: cgImage)
        let resolvedFacePresence = faceMetrics?.facePresence ?? 0.0
        let resolvedFraming = faceMetrics?.framing ?? 0.0
        let resolvedEyesOpen = faceMetrics?.eyesOpen ?? 0.5
        let resolvedSmile = faceMetrics?.smile ?? 0.0

        let features = FeatureSnapshot(
            facePresence: resolvedFacePresence,
            framing: resolvedFraming,
            eyesOpen: resolvedEyesOpen,
            smile: resolvedSmile,
            subjectProminence: subjectProminenceScore,
            subjectCentering: subjectCenteringScore,
            sharpness: sharpnessScore,
            lighting: lightingScore,
            color: colorScore,
            contrast: contrastScore
        )

        let baseHeuristic: Double
        guard let faceMetrics else {
            baseHeuristic = 0.30 * sharpnessScore
                + 0.22 * lightingScore
                + 0.13 * contrastScore
                + 0.10 * colorScore
                + 0.15 * subjectProminenceScore
                + 0.10 * subjectCenteringScore
            let personalized = personalizedScore(
                baseHeuristicScore: baseHeuristic,
                features: features,
                settings: settings
            )

            return BestShotScoreBreakdown(
                totalScore: personalized.totalScore,
                baseHeuristicScore: baseHeuristic,
                learnedPreferenceScore: personalized.learnedScore,
                learnedAdjustment: personalized.adjustment,
                facePresence: resolvedFacePresence,
                framing: resolvedFraming,
                eyesOpen: resolvedEyesOpen,
                smile: resolvedSmile,
                subjectProminence: subjectProminenceScore,
                subjectCentering: subjectCenteringScore,
                sharpness: sharpnessScore,
                lighting: lightingScore,
                color: colorScore,
                contrast: contrastScore,
                aestheticsScore: nil,
                usedDeepPass: false
            )
        }

        baseHeuristic = 0.16 * faceMetrics.facePresence
            + 0.15 * faceMetrics.framing
            + 0.16 * faceMetrics.eyesOpen
            + 0.10 * faceMetrics.smile
            + 0.12 * sharpnessScore
            + 0.09 * lightingScore
            + 0.06 * colorScore
            + 0.02 * contrastScore
            + 0.07 * subjectProminenceScore
            + 0.07 * subjectCenteringScore
        let personalized = personalizedScore(
            baseHeuristicScore: baseHeuristic,
            features: features,
            settings: settings
        )

        return BestShotScoreBreakdown(
            totalScore: personalized.totalScore,
            baseHeuristicScore: baseHeuristic,
            learnedPreferenceScore: personalized.learnedScore,
            learnedAdjustment: personalized.adjustment,
            facePresence: faceMetrics.facePresence,
            framing: faceMetrics.framing,
            eyesOpen: faceMetrics.eyesOpen,
            smile: faceMetrics.smile,
            subjectProminence: subjectProminenceScore,
            subjectCentering: subjectCenteringScore,
            sharpness: sharpnessScore,
            lighting: lightingScore,
            color: colorScore,
            contrast: contrastScore,
            aestheticsScore: nil,
            usedDeepPass: false
        )
    }

    private func personalizedScore(
        baseHeuristicScore: Double,
        features: FeatureSnapshot,
        settings: ScanSettings
    ) -> (totalScore: Double, learnedScore: Double, adjustment: Double) {
        guard let personalization = settings.bestShotPersonalization,
              personalization.confidence > 0.0001 else {
            return (baseHeuristicScore, baseHeuristicScore, 0.0)
        }

        let learnedScore = weightedFeatureScore(features: features, weights: personalization.weights)
        let blendWeight = 0.35 * personalization.confidence
        let blendedTotal = clamp01((1.0 - blendWeight) * baseHeuristicScore + blendWeight * learnedScore)
        return (blendedTotal, learnedScore, blendedTotal - baseHeuristicScore)
    }

    private func weightedFeatureScore(
        features: FeatureSnapshot,
        weights: BestShotFeatureWeights
    ) -> Double {
        let normalized = weights.normalized()
        let score = normalized.facePresence * features.facePresence
            + normalized.framing * features.framing
            + normalized.eyesOpen * features.eyesOpen
            + normalized.smile * features.smile
            + normalized.subjectProminence * features.subjectProminence
            + normalized.subjectCentering * features.subjectCentering
            + normalized.sharpness * features.sharpness
            + normalized.lighting * features.lighting
            + normalized.color * features.color
            + normalized.contrast * features.contrast
        return clamp01(score)
    }

    private func deepAestheticScore(for asset: PHAsset) async -> Double? {
        guard #available(macOS 15.0, *) else {
            return nil
        }

        guard
            let cgImage = await libraryService.requestCGImage(
                for: asset,
                targetSize: CGSize(width: 960, height: 960),
                contentMode: .aspectFit
            )
        else {
            return nil
        }

        return visionAestheticScore(for: cgImage)
    }

    private func visionAestheticScore(for cgImage: CGImage) -> Double? {
        guard #available(macOS 15.0, *) else {
            return nil
        }

        let request = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else {
            return nil
        }

        let normalizedOverall = clamp01((Double(observation.overallScore) + 1.0) / 2.0)
        let utilityPenalty = observation.isUtility ? 0.08 : 0.0
        return clamp01(normalizedOverall - utilityPenalty)
    }

    private func shouldAutoDiscardSingleton(score: BestShotScoreBreakdown) -> Bool {
        // Conservative rule: only auto-discard when multiple quality signals are clearly poor.
        let veryLowBaseQuality = score.baseHeuristicScore < 0.24
        let veryBlurry = score.sharpness < 0.11
        let veryPoorLighting = score.lighting < 0.15
        let veryLowContrast = score.contrast < 0.08
        let nearBlackAccidental = score.lighting < 0.09 && score.color < 0.07 && score.contrast < 0.06
        let severeSignalCount = [veryBlurry, veryPoorLighting, veryLowContrast].filter { $0 }.count

        return nearBlackAccidental || (veryLowBaseQuality && severeSignalCount >= 2)
    }

    private func edgeSharpnessScore(for image: CIImage) -> Double {
        let edges = image.applyingFilter(
            "CIEdges",
            parameters: [kCIInputIntensityKey: 2.2]
        )
        let edgeLuma = averageLuma(for: edges) ?? 0.02
        return clamp01(edgeLuma / 0.12)
    }

    private func visionFaceMetrics(for cgImage: CGImage) -> FaceMetrics? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let faces = request.results, !faces.isEmpty else {
            return nil
        }

        let largestFaceAreaRatio = faces
            .map { Double($0.boundingBox.width * $0.boundingBox.height) }
            .max() ?? 0

        let framingScore = clamp01(1.0 - (abs(largestFaceAreaRatio - 0.18) / 0.18))
        let facePresenceScore = clamp01(Double(faces.count) / 3.0)

        var eyesTotal = 0.0
        var eyesCount = 0
        var smileTotal = 0.0
        var smileCount = 0

        for face in faces {
            guard let landmarks = face.landmarks else {
                continue
            }

            if let eyesScore = mergedEyeOpenScore(
                left: landmarks.leftEye,
                right: landmarks.rightEye
            ) {
                eyesTotal += eyesScore
                eyesCount += 1
            }

            if let smileScore = mouthSmileScore(
                for: landmarks.outerLips ?? landmarks.innerLips
            ) {
                smileTotal += smileScore
                smileCount += 1
            }
        }

        let eyesOpenScore = eyesCount > 0 ? eyesTotal / Double(eyesCount) : 0.5
        let smileScore = smileCount > 0 ? smileTotal / Double(smileCount) : 0.0

        return FaceMetrics(
            facePresence: facePresenceScore,
            framing: framingScore,
            eyesOpen: eyesOpenScore,
            smile: smileScore
        )
    }

    private func visionSaliencyMetrics(for cgImage: CGImage) -> SaliencyMetrics? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first,
              let salientObjects = observation.salientObjects,
              !salientObjects.isEmpty else {
            return nil
        }

        let rankedByArea = salientObjects.sorted { lhs, rhs in
            (lhs.boundingBox.width * lhs.boundingBox.height) > (rhs.boundingBox.width * rhs.boundingBox.height)
        }

        let primary = rankedByArea[0]
        let primaryArea = Double(primary.boundingBox.width * primary.boundingBox.height)
        let totalArea = rankedByArea.prefix(3).reduce(0.0) { partial, item in
            partial + Double(item.boundingBox.width * item.boundingBox.height)
        }

        let prominenceFromPrimary = clamp01(primaryArea / 0.30)
        let prominenceFromTotal = clamp01(totalArea / 0.55)
        let subjectProminence = max(prominenceFromPrimary, prominenceFromTotal)

        let centerX = Double(primary.boundingBox.midX)
        let centerY = Double(primary.boundingBox.midY)
        let dx = centerX - 0.5
        let dy = centerY - 0.5
        let normalizedDistance = min(1.0, sqrt((dx * dx) + (dy * dy)) / 0.70710678118)
        let subjectCentering = 1.0 - normalizedDistance

        return SaliencyMetrics(
            subjectProminence: subjectProminence,
            subjectCentering: subjectCentering
        )
    }

    private func mergedEyeOpenScore(
        left: VNFaceLandmarkRegion2D?,
        right: VNFaceLandmarkRegion2D?
    ) -> Double? {
        var eyeScores: [Double] = []

        if let leftScore = singleEyeOpenScore(for: left) {
            eyeScores.append(leftScore)
        }

        if let rightScore = singleEyeOpenScore(for: right) {
            eyeScores.append(rightScore)
        }

        guard !eyeScores.isEmpty else {
            return nil
        }

        let total = eyeScores.reduce(0, +)
        return total / Double(eyeScores.count)
    }

    private func singleEyeOpenScore(for eye: VNFaceLandmarkRegion2D?) -> Double? {
        guard let eye else {
            return nil
        }

        let points = landmarkPoints(eye)
        guard points.count >= 4 else {
            return nil
        }

        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for point in points {
            let x = Double(point.x)
            let y = Double(point.y)
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        let width = maxX - minX
        guard width > 0.0001 else {
            return nil
        }

        let height = maxY - minY
        let ratio = height / width
        return clamp01((ratio - 0.06) / 0.16)
    }

    private func mouthSmileScore(for mouth: VNFaceLandmarkRegion2D?) -> Double? {
        guard let mouth else {
            return nil
        }

        let points = landmarkPoints(mouth)
        guard points.count >= 6 else {
            return nil
        }

        let left = points.min(by: { $0.x < $1.x })!
        let right = points.max(by: { $0.x < $1.x })!
        let width = Double(right.x - left.x)
        guard width > 0.0001 else {
            return nil
        }

        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for point in points {
            let y = Double(point.y)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        let midX = (Double(left.x) + Double(right.x)) / 2.0
        let sortedByMid = points.sorted { lhs, rhs in
            abs(Double(lhs.x) - midX) < abs(Double(rhs.x) - midX)
        }
        let centerPoints = Array(sortedByMid.prefix(3))
        let centerY = centerPoints.map { Double($0.y) }.reduce(0, +) / Double(centerPoints.count)

        let cornersY = (Double(left.y) + Double(right.y)) / 2.0
        let curvature = (cornersY - centerY) / width
        let openness = (maxY - minY) / width

        let curveScore = clamp01((curvature + 0.01) / 0.10)
        let opennessScore = clamp01((openness - 0.02) / 0.20)
        return clamp01(0.75 * curveScore + 0.25 * opennessScore)
    }

    private func landmarkPoints(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
        let count = region.pointCount
        guard count > 0 else {
            return []
        }

        let pointsPointer = region.normalizedPoints
        var points: [CGPoint] = []
        points.reserveCapacity(count)

        for index in 0..<count {
            let point = pointsPointer[index]
            points.append(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
        }

        return points
    }

    private func averageLuma(for image: CIImage) -> Double? {
        guard let averageRGBA = averageRGBA(for: image) else {
            return nil
        }

        let r = averageRGBA.0
        let g = averageRGBA.1
        let b = averageRGBA.2
        return (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    }

    private func averageRGBA(for image: CIImage) -> (Double, Double, Double, Double)? {
        let extent = image.extent.integral
        guard !extent.isEmpty else {
            return nil
        }

        let averageImage = image.applyingFilter(
            "CIAreaAverage",
            parameters: [kCIInputExtentKey: CIVector(cgRect: extent)]
        )

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            averageImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return (
            Double(pixel[0]) / 255.0,
            Double(pixel[1]) / 255.0,
            Double(pixel[2]) / 255.0,
            Double(pixel[3]) / 255.0
        )
    }

    private func imageStats(from cgImage: CGImage, dimension: Int = 96) -> ImageStats? {
        let sampleSize = max(32, dimension)
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var data = [UInt8](repeating: 0, count: sampleSize * bytesPerRow)

        guard let context = CGContext(
            data: &data,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        let pixelCount = sampleSize * sampleSize
        guard pixelCount > 0 else {
            return nil
        }

        var lumaValues = [Double]()
        lumaValues.reserveCapacity(pixelCount)

        var rgValues = [Double]()
        rgValues.reserveCapacity(pixelCount)
        var ybValues = [Double]()
        ybValues.reserveCapacity(pixelCount)

        for pixelIndex in 0..<pixelCount {
            let byteIndex = pixelIndex * 4
            let r = Double(data[byteIndex]) / 255.0
            let g = Double(data[byteIndex + 1]) / 255.0
            let b = Double(data[byteIndex + 2]) / 255.0

            let luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
            lumaValues.append(luma)

            rgValues.append(r - g)
            ybValues.append(0.5 * (r + g) - b)
        }

        let meanLuma = mean(lumaValues)
        let stdLuma = stdDeviation(lumaValues, meanValue: meanLuma)

        let meanRG = mean(rgValues)
        let meanYB = mean(ybValues)
        let stdRG = stdDeviation(rgValues, meanValue: meanRG)
        let stdYB = stdDeviation(ybValues, meanValue: meanYB)
        let colorfulness = sqrt((stdRG * stdRG) + (stdYB * stdYB))
            + (0.3 * sqrt((meanRG * meanRG) + (meanYB * meanYB)))

        return ImageStats(
            meanLuma: meanLuma,
            stdLuma: stdLuma,
            colorfulness: colorfulness
        )
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let total = values.reduce(0, +)
        return total / Double(values.count)
    }

    private func stdDeviation(_ values: [Double], meanValue: Double) -> Double {
        guard values.count > 1 else {
            return 0
        }

        let variance = values.reduce(0) { partial, value in
            let diff = value - meanValue
            return partial + (diff * diff)
        } / Double(values.count)

        return sqrt(variance)
    }

    private func clamp01(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
