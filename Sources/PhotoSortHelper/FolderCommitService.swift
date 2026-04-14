import Foundation

final class FolderCommitService: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func destinationPaths(for sourceFolderURL: URL) -> FolderCommitDestinationPaths {
        let destinationRootURL = sourceFolderURL.deletingLastPathComponent()
        return FolderCommitDestinationPaths(
            destinationRootURL: destinationRootURL,
            editQueueURL: destinationRootURL.appendingPathComponent(FolderCommitDestination.editQueue.folderName, isDirectory: true),
            manualDeleteQueueURL: destinationRootURL.appendingPathComponent(FolderCommitDestination.manualDeleteQueue.folderName, isDirectory: true),
            keepURL: destinationRootURL.appendingPathComponent(FolderCommitDestination.keep.folderName, isDirectory: true)
        )
    }

    func buildCommitPlan(
        itemLookup: [String: ReviewItem],
        groups: [ReviewGroup],
        reviewedGroupIDs: Set<UUID>,
        reviewMode: ReviewMode,
        reviewDecisionsByGroup: [UUID: ReviewGroupDecisions],
        queuedForEditItemIDs: Set<String>,
        moveKeptItemsToKeepFolder: Bool
    ) -> FolderCommitPlan {
        var operations: [FolderCommitOperation] = []
        var editQueueSamples: [String] = []
        var manualDeleteSamples: [String] = []
        var keepSamples: [String] = []
        var editQueueCount = 0
        var manualDeleteCount = 0
        var keepCount = 0

        for group in groups where reviewedGroupIDs.contains(group.id) {
            let decisions = reviewDecisionsByGroup[group.id] ?? ReviewGroupDecisions()
            let explicitKeeps = decisions.explicitKeepIDs.intersection(group.itemIDs).union(queuedForEditItemIDs.intersection(group.itemIDs))
            let explicitDiscards: Set<String> = {
                switch reviewMode {
                case .discardFirst:
                    let effectiveKeeps = explicitKeeps
                    return Set(group.itemIDs).subtracting(effectiveKeeps)
                case .keepFirst:
                    return decisions.explicitDiscardIDs.intersection(group.itemIDs).subtracting(queuedForEditItemIDs)
                }
            }()

            for itemID in group.itemIDs {
                guard
                    let item = itemLookup[itemID],
                    let sourcePath = item.absolutePath,
                    let relativePath = item.relativePath
                else {
                    continue
                }

                let destination: FolderCommitDestination?
                if queuedForEditItemIDs.contains(itemID) {
                    destination = .editQueue
                } else if explicitKeeps.contains(itemID) {
                    destination = moveKeptItemsToKeepFolder ? .keep : nil
                } else if explicitDiscards.contains(itemID) {
                    destination = .manualDeleteQueue
                } else {
                    destination = nil
                }

                guard let destination else {
                    continue
                }

                operations.append(
                    FolderCommitOperation(
                        itemID: itemID,
                        sourceURL: URL(fileURLWithPath: sourcePath),
                        relativePath: relativePath,
                        destination: destination
                    )
                )

                switch destination {
                case .editQueue:
                    editQueueCount += 1
                    if editQueueSamples.count < 5 {
                        editQueueSamples.append(relativePath)
                    }
                case .manualDeleteQueue:
                    manualDeleteCount += 1
                    if manualDeleteSamples.count < 5 {
                        manualDeleteSamples.append(relativePath)
                    }
                case .keep:
                    keepCount += 1
                    if keepSamples.count < 5 {
                        keepSamples.append(relativePath)
                    }
                }
            }
        }

        return FolderCommitPlan(
            operations: operations,
            reviewedGroupCount: reviewedGroupIDs.count,
            editQueueCount: editQueueCount,
            manualDeleteCount: manualDeleteCount,
            keepCount: keepCount,
            editQueueSamples: editQueueSamples,
            manualDeleteSamples: manualDeleteSamples,
            keepSamples: keepSamples
        )
    }

    func execute(
        plan: FolderCommitPlan,
        sourceFolderURL: URL,
        progress: @escaping @Sendable (FolderCommitExecutionProgress) async -> Void = { _ in }
    ) async throws -> FolderCommitExecutionResult {
        if plan.operations.isEmpty {
            throw ReviewError.noReviewedItemsToCommit
        }

        let destinationPaths = destinationPaths(for: sourceFolderURL)
        try fileManager.createDirectory(at: destinationPaths.editQueueURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationPaths.manualDeleteQueueURL, withIntermediateDirectories: true)
        if plan.keepCount > 0 {
            try fileManager.createDirectory(at: destinationPaths.keepURL, withIntermediateDirectories: true)
        }

        var movedItemIDs: Set<String> = []
        var movedToEditQueueCount = 0
        var movedToManualDeleteCount = 0
        var movedToKeepCount = 0
        var skippedMissingSources: [FolderCommitSkippedSourceDetail] = []
        var renamedItems: [FolderCommitRenamedItem] = []
        var failures: [FolderCommitFailureDetail] = []
        var processedCount = 0
        var wasCancelled = false
        var lastProcessedRelativePath: String?

        await progress(
            FolderCommitExecutionProgress(
                processedCount: processedCount,
                movedCount: movedItemIDs.count,
                totalCount: plan.totalMoveCount,
                currentRelativePath: nil,
                lastProcessedRelativePath: nil,
                statusMessage: "Prepared destination folders."
            )
        )

        for operation in plan.operations {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            let currentRelativePath = operation.relativePath
            await progress(
                FolderCommitExecutionProgress(
                    processedCount: processedCount,
                    movedCount: movedItemIDs.count,
                    totalCount: plan.totalMoveCount,
                    currentRelativePath: currentRelativePath,
                    lastProcessedRelativePath: lastProcessedRelativePath,
                    statusMessage: "Moving \(currentRelativePath)..."
                )
            )

            guard fileManager.fileExists(atPath: operation.sourceURL.path) else {
                skippedMissingSources.append(
                    FolderCommitSkippedSourceDetail(
                        sourcePath: operation.sourceURL.path,
                        relativePath: currentRelativePath,
                        destination: operation.destination,
                        destinationFolderPath: destinationPaths.url(for: operation.destination).path
                    )
                )
                processedCount += 1
                lastProcessedRelativePath = currentRelativePath
                continue
            }

            let destinationFolder = destinationPaths.url(for: operation.destination)
            let desiredDestination = destinationFolder.appendingPathComponent(currentRelativePath, isDirectory: false)
            let finalDestination = uniqueDestinationURL(for: desiredDestination)

            do {
                try fileManager.createDirectory(
                    at: finalDestination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if finalDestination.lastPathComponent != desiredDestination.lastPathComponent {
                    let finalRelativePath = finalDestination.path.replacingOccurrences(of: destinationFolder.path + "/", with: "")
                    renamedItems.append(
                        FolderCommitRenamedItem(
                            relativePath: currentRelativePath,
                            finalRelativePath: finalRelativePath,
                            destination: operation.destination,
                            destinationPath: finalDestination.path
                        )
                    )
                }

                try fileManager.moveItem(at: operation.sourceURL, to: finalDestination)
                movedItemIDs.insert(operation.itemID)

                switch operation.destination {
                case .editQueue:
                    movedToEditQueueCount += 1
                case .manualDeleteQueue:
                    movedToManualDeleteCount += 1
                case .keep:
                    movedToKeepCount += 1
                }
            } catch {
                failures.append(
                    FolderCommitFailureDetail(
                        sourcePath: operation.sourceURL.path,
                        relativePath: currentRelativePath,
                        destination: operation.destination,
                        destinationFolderPath: destinationFolder.path,
                        message: error.localizedDescription
                    )
                )
            }

            processedCount += 1
            lastProcessedRelativePath = currentRelativePath

            await progress(
                FolderCommitExecutionProgress(
                    processedCount: processedCount,
                    movedCount: movedItemIDs.count,
                    totalCount: plan.totalMoveCount,
                    currentRelativePath: nil,
                    lastProcessedRelativePath: lastProcessedRelativePath,
                    statusMessage: "Processed \(processedCount) of \(plan.totalMoveCount) items."
                )
            )

            await Task.yield()
        }

        await progress(
            FolderCommitExecutionProgress(
                processedCount: processedCount,
                movedCount: movedItemIDs.count,
                totalCount: plan.totalMoveCount,
                currentRelativePath: nil,
                lastProcessedRelativePath: lastProcessedRelativePath,
                statusMessage: wasCancelled ? "Commit cancelled. Already moved files remain moved." : "Commit finished."
            )
        )

        return FolderCommitExecutionResult(
            destinationPaths: destinationPaths,
            totalOperationCount: plan.totalMoveCount,
            processedCount: processedCount,
            wasCancelled: wasCancelled,
            movedItemIDs: movedItemIDs,
            movedToEditQueueCount: movedToEditQueueCount,
            movedToManualDeleteCount: movedToManualDeleteCount,
            movedToKeepCount: movedToKeepCount,
            skippedMissingSources: skippedMissingSources,
            renamedItems: renamedItems,
            failures: failures
        )
    }

    private func uniqueDestinationURL(for desiredURL: URL) -> URL {
        guard fileManager.fileExists(atPath: desiredURL.path) else {
            return desiredURL
        }

        let directory = desiredURL.deletingLastPathComponent()
        let fileName = desiredURL.lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension

        var suffix = 2
        while true {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(baseName) (\(suffix))"
            } else {
                candidateName = "\(baseName) (\(suffix)).\(fileExtension)"
            }

            let candidateURL = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }

            suffix += 1
        }
    }
}
