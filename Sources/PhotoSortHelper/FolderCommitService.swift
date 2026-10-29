import Darwin
import Foundation

final class FolderCommitService: @unchecked Sendable {
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
                        destination: destination,
                        expectedDeviceNumber: item.fileDeviceNumber,
                        expectedInodeNumber: item.fileInodeNumber
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

        let sourceRoot = sourceFolderURL.standardizedFileURL
        let destinationPaths = destinationPaths(for: sourceRoot)
        let sourceRootFD = try openDirectory(path: sourceRoot.path)
        defer { Darwin.close(sourceRootFD) }
        let destinationRootFD = try openDirectory(path: destinationPaths.destinationRootURL.path)
        defer { Darwin.close(destinationRootFD) }

        var destinationFDs: [FolderCommitDestination: Int32] = [:]
        defer {
            for descriptor in destinationFDs.values {
                Darwin.close(descriptor)
            }
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
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            do {
                guard operation.sourceURL.standardizedFileURL.path == sourceRoot
                    .appending(path: currentRelativePath)
                    .standardizedFileURL.path
                else {
                    throw POSIXError(.EINVAL)
                }

                let sourceComponents = try validatedRelativeComponents(currentRelativePath)
                guard let sourceName = sourceComponents.last else {
                    throw POSIXError(.EINVAL)
                }
                let sourceParentFD = try openDirectoryComponents(
                    Array(sourceComponents.dropLast()),
                    startingAt: sourceRootFD,
                    create: false
                )
                defer { Darwin.close(sourceParentFD) }

                var sourceInfo = stat()
                let sourceStatus = sourceName.withCString { name in
                    fstatat(sourceParentFD, name, &sourceInfo, AT_SYMLINK_NOFOLLOW)
                }
                if sourceStatus != 0 {
                    let code = errno
                    if code == ENOENT {
                        skippedMissingSources.append(
                            FolderCommitSkippedSourceDetail(
                                sourcePath: operation.sourceURL.path,
                                relativePath: currentRelativePath,
                                destination: operation.destination,
                                destinationFolderPath: destinationPaths.url(for: operation.destination).path
                            )
                        )
                    } else {
                        throw posixError(code)
                    }
                    processedCount += 1
                    lastProcessedRelativePath = currentRelativePath
                    continue
                }

                guard (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
                    throw POSIXError(.EINVAL)
                }
                if let expectedDeviceNumber = operation.expectedDeviceNumber,
                   UInt64(sourceInfo.st_dev) != expectedDeviceNumber {
                    throw POSIXError(.ESTALE)
                }
                if let expectedInodeNumber = operation.expectedInodeNumber,
                   UInt64(sourceInfo.st_ino) != expectedInodeNumber {
                    throw POSIXError(.ESTALE)
                }

                let destinationFolderFD: Int32
                if let existingFD = destinationFDs[operation.destination] {
                    destinationFolderFD = existingFD
                } else {
                    let queueRootFD = try openDirectoryComponent(
                        operation.destination.folderName,
                        startingAt: destinationRootFD,
                        create: true
                    )
                    destinationFDs[operation.destination] = queueRootFD
                    destinationFolderFD = queueRootFD
                }

                let destinationComponents = try validatedRelativeComponents(currentRelativePath)
                guard let destinationName = destinationComponents.last else {
                    throw POSIXError(.EINVAL)
                }
                let destinationParentFD = try openDirectoryComponents(
                    Array(destinationComponents.dropLast()),
                    startingAt: destinationFolderFD,
                    create: true
                )
                defer { Darwin.close(destinationParentFD) }

                let finalName = try renameExclusively(
                    sourceParentFD: sourceParentFD,
                    sourceName: sourceName,
                    destinationParentFD: destinationParentFD,
                    desiredName: destinationName
                )
                movedItemIDs.insert(operation.itemID)

                switch operation.destination {
                case .editQueue:
                    movedToEditQueueCount += 1
                case .manualDeleteQueue:
                    movedToManualDeleteCount += 1
                case .keep:
                    movedToKeepCount += 1
                }

                if finalName != destinationName {
                    let finalRelativePath = (Array(destinationComponents.dropLast()) + [finalName]).joined(separator: "/")
                    renamedItems.append(
                        FolderCommitRenamedItem(
                            relativePath: currentRelativePath,
                            finalRelativePath: finalRelativePath,
                            destination: operation.destination,
                            destinationPath: destinationPaths.url(for: operation.destination)
                                .appending(path: finalRelativePath).path
                        )
                    )
                }
            } catch {
                failures.append(
                    FolderCommitFailureDetail(
                        sourcePath: operation.sourceURL.path,
                        relativePath: currentRelativePath,
                        destination: operation.destination,
                        destinationFolderPath: destinationPaths.url(for: operation.destination).path,
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

        if Task.isCancelled, processedCount < plan.totalMoveCount {
            wasCancelled = true
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

    private func validatedRelativeComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw POSIXError(.EINVAL)
        }
        return components
    }

    private func openDirectory(path: String) throws -> Int32 {
        let standardizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        let descriptor = Darwin.open(standardizedPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    private func openDirectoryComponents(
        _ components: [String],
        startingAt rootFD: Int32,
        create: Bool
    ) throws -> Int32 {
        guard !components.isEmpty else {
            let duplicate = dup(rootFD)
            guard duplicate >= 0 else { throw posixError() }
            return duplicate
        }
        var currentFD = dup(rootFD)
        guard currentFD >= 0 else { throw posixError() }
        do {
            for component in components {
                let nextFD = try openDirectoryComponent(component, startingAt: currentFD, create: create)
                Darwin.close(currentFD)
                currentFD = nextFD
            }
            return currentFD
        } catch {
            Darwin.close(currentFD)
            throw error
        }
    }

    private func openDirectoryComponent(
        _ component: String,
        startingAt parentFD: Int32,
        create: Bool
    ) throws -> Int32 {
        guard !component.isEmpty, component != ".", component != "..", !component.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        if create {
            let mkdirResult = component.withCString { mkdirat(parentFD, $0, mode_t(0o755)) }
            if mkdirResult != 0, errno != EEXIST {
                throw posixError()
            }
        }
        let descriptor = component.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    private func renameExclusively(
        sourceParentFD: Int32,
        sourceName: String,
        destinationParentFD: Int32,
        desiredName: String
    ) throws -> String {
        let fileExtension = (desiredName as NSString).pathExtension
        let baseName = (desiredName as NSString).deletingPathExtension
        var suffix = 1
        while true {
            let candidate: String
            if suffix == 1 {
                candidate = desiredName
            } else if fileExtension.isEmpty {
                candidate = "\(baseName) (\(suffix))"
            } else {
                candidate = "\(baseName) (\(suffix)).\(fileExtension)"
            }
            let result = sourceName.withCString { source in
                candidate.withCString { destination in
                    renameatx_np(sourceParentFD, source, destinationParentFD, destination, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return candidate }
            let code = errno
            if code != EEXIST { throw posixError(code) }
            guard suffix < Int.max else { throw POSIXError(.EOVERFLOW) }
            suffix += 1
        }
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
