import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct OpenDirectoryIdentity: Equatable {
    var device: dev_t
    var inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

final class DescriptorAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let fileDescriptor: Int32
    private let contentLength: Int64
    private let contentType: String
    let callbackQueue = DispatchQueue(label: "PhotosLibrarySortHelper.DescriptorAssetResourceLoader")

    init(sourceFileDescriptor: Int32, contentLength: Int64, contentType: String) throws {
        let duplicate = dup(sourceFileDescriptor)
        guard duplicate >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        fileDescriptor = duplicate
        self.contentLength = max(0, contentLength)
        self.contentType = contentType
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = request.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = contentLength
            information.isByteRangeAccessSupported = true
        }

        if let dataRequest = request.dataRequest {
            let requestedStart = max(0, dataRequest.requestedOffset)
            var offset = max(requestedStart, max(0, dataRequest.currentOffset))
            let requestedEnd: Int64
            if dataRequest.requestsAllDataToEndOfResource {
                requestedEnd = contentLength
            } else {
                let (end, overflow) = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
                requestedEnd = overflow ? contentLength : min(contentLength, max(requestedStart, end))
            }

            while offset < requestedEnd {
                guard !request.isCancelled else { return false }
                let byteCount = Int(min(1_048_576, requestedEnd - offset))
                var bytes = [UInt8](repeating: 0, count: byteCount)
                let readCount = bytes.withUnsafeMutableBytes { buffer in
                    pread(fileDescriptor, buffer.baseAddress, byteCount, off_t(offset))
                }
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else {
                    let code = readCount < 0 ? errno : EIO
                    request.finishLoading(with: NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
                    return true
                }
                dataRequest.respond(with: Data(bytes.prefix(readCount)))
                offset += Int64(readCount)
            }
        }

        guard !request.isCancelled else { return false }
        request.finishLoading()
        return true
    }
}

final class FolderVideoPreviewLease {
    let player: AVPlayer
    private let asset: AVURLAsset
    private let resourceLoader: DescriptorAssetResourceLoader

    init(asset: AVURLAsset, resourceLoader: DescriptorAssetResourceLoader) {
        self.asset = asset
        self.resourceLoader = resourceLoader
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .pause
    }
}

struct FolderScanListing: Sendable {
    var items: [ReviewItem]
    var skippedHiddenCount: Int
    var skippedUnsupportedCount: Int
    var skippedPackageCount: Int
    var skippedSymlinkDirectoryCount: Int
}

final class FolderLibraryService: @unchecked Sendable {
    private static let packageExtensions: Set<String> = [
        "app", "appex", "appiconset", "band", "bundle", "colorset", "component", "dataset",
        "framework", "garageband", "imageset", "imovielibrary", "launchimage",
        "kext", "logicx", "mdimporter", "numbers", "pages", "photolibrary", "photoslibrary",
        "pkg", "playground", "plugin", "prefPane", "qlgenerator", "rtfd", "saver", "scnassets",
        "scptd", "sparsebundle", "sparseimage", "spriteatlas", "stickerpack", "symbolset", "vst",
        "workflow", "xcassets", "xcodeproj", "xcworkspace"
    ]
    private let fileManager: FileManager
    private let beforeMetadataRead: (@Sendable () async -> Void)?

    init(
        fileManager: FileManager = .default,
        beforeMetadataRead: (@Sendable () async -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.beforeMetadataRead = beforeMetadataRead
    }

    @MainActor
    func chooseFolder(attachedTo window: NSWindow?, initialSelection: FolderSelection?) async -> FolderSelection? {
        let panel = NSOpenPanel()
        panel.title = "Choose Media Source Folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if let initialSelection,
           let initialURL = resolvedURL(for: initialSelection, allowStale: true),
           fileManager.fileExists(atPath: initialURL.path) {
            panel.directoryURL = initialURL
        }

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { result in
                    continuation.resume(returning: result)
                }
            }
        } else {
            response = panel.runModal()
        }

        guard response == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            return nil
        }

        return makeSelection(from: selectedURL)
    }

    func makeSelection(from url: URL) -> FolderSelection {
        let bookmarkData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FolderSelection(
            resolvedPath: url.path,
            bookmarkDataBase64: bookmarkData?.base64EncodedString()
        )
    }

    func isDirectoryURL(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func resolveValidatedFolderURL(for selection: FolderSelection?) throws -> URL {
        guard let selection else {
            throw ReviewError.missingSourceFolder
        }

        let resolvedURL = resolvedURL(for: selection, allowStale: false)
            ?? URL(fileURLWithPath: selection.resolvedPath, isDirectory: true).standardizedFileURL

        if selection.bookmarkDataBase64 != nil, resolvedURL.path != selection.resolvedPath {
            // If a security-scoped bookmark now points somewhere else, make the user re-confirm it.
            throw ReviewError.staleSourceFolderBookmark
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory) else {
            throw ReviewError.sourceFolderDoesNotExist
        }

        var rootFileInfo = stat()
        guard lstat(resolvedURL.path, &rootFileInfo) == 0 else {
            throw ReviewError.sourceFolderDoesNotExist
        }
        guard (rootFileInfo.st_mode & S_IFMT) != S_IFLNK else {
            throw ReviewError.sourceFolderIsSymbolicLink
        }

        guard isDirectory.boolValue else {
            throw ReviewError.sourceFolderNotDirectory
        }

        let reservedFolderNames = FolderCommitDestination.allCases.map(\.folderName)
        if reservedFolderNames.contains(where: { $0.caseInsensitiveCompare(resolvedURL.lastPathComponent) == .orderedSame }) {
            throw ReviewError.sourceFolderConflictsWithDestination
        }

        return resolvedURL
    }

    func loadReviewItems(
        selection: FolderSelection?,
        recursive: Bool,
        includeVideos: Bool
    ) async throws -> FolderScanListing {
        try Task.checkCancellation()
        let sourceFolderURL = try resolveValidatedFolderURL(for: selection)
        let rootDescriptor = try openDirectoryDescriptor(at: sourceFolderURL.path)
        defer { Darwin.close(rootDescriptor) }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0 else {
            throw ReviewError.unreadableSourceFolder
        }

        var items: [ReviewItem] = []
        var skippedHiddenCount = 0
        var skippedUnsupportedCount = 0
        var skippedPackageCount = 0
        var skippedSymlinkDirectoryCount = 0

        try await walkDirectory(
            root: sourceFolderURL,
            rootDescriptor: rootDescriptor,
            currentDescriptor: rootDescriptor,
            directoryComponents: [],
            directoryChain: [OpenDirectoryIdentity(rootInfo)],
            recursive: recursive,
            includeVideos: includeVideos,
            items: &items,
            skippedHiddenCount: &skippedHiddenCount,
            skippedUnsupportedCount: &skippedUnsupportedCount,
            skippedPackageCount: &skippedPackageCount,
            skippedSymlinkDirectoryCount: &skippedSymlinkDirectoryCount
        )

        try Task.checkCancellation()
        let sortedItems = items.sorted(by: folderSortPredicate)
        guard !sortedItems.isEmpty else {
            throw ReviewError.emptySourceFolder
        }

        return FolderScanListing(
            items: sortedItems,
            skippedHiddenCount: skippedHiddenCount,
            skippedUnsupportedCount: skippedUnsupportedCount,
            skippedPackageCount: skippedPackageCount,
            skippedSymlinkDirectoryCount: skippedSymlinkDirectoryCount
        )
    }

    private func walkDirectory(
        root: URL,
        rootDescriptor: Int32,
        currentDescriptor: Int32,
        directoryComponents: [String],
        directoryChain: [OpenDirectoryIdentity],
        recursive: Bool,
        includeVideos: Bool,
        items: inout [ReviewItem],
        skippedHiddenCount: inout Int,
        skippedUnsupportedCount: inout Int,
        skippedPackageCount: inout Int,
        skippedSymlinkDirectoryCount: inout Int
    ) async throws {
        try Task.checkCancellation()
        guard directoryChainIsAttached(
            root: root,
            rootDescriptor: rootDescriptor,
            directoryComponents: directoryComponents,
            expectedChain: directoryChain,
            currentDescriptor: currentDescriptor
        ) else {
            throw ReviewError.unreadableSourceFolder
        }
        let contents = try directoryEntryNamesWithoutFollowingSymlinks(at: currentDescriptor)

        for name in contents.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            try Task.checkCancellation()
            guard directoryChainIsAttached(
                root: root,
                rootDescriptor: rootDescriptor,
                directoryComponents: directoryComponents,
                expectedChain: directoryChain,
                currentDescriptor: currentDescriptor
            ) else {
                throw ReviewError.unreadableSourceFolder
            }

            var entryInfo = stat()
            let entryStatus = name.withCString { entryName in
                fstatat(currentDescriptor, entryName, &entryInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard entryStatus == 0 else {
                if errno == ENOENT { continue }
                throw ReviewError.unreadableSourceFolder
            }

            if (entryInfo.st_mode & S_IFMT) == S_IFLNK {
                skippedSymlinkDirectoryCount += 1
                continue
            }

            let isHidden = name.hasPrefix(".") || (entryInfo.st_flags & UInt32(UF_HIDDEN)) != 0
            if isHidden {
                skippedHiddenCount += 1
                continue
            }

            let entryKind = entryInfo.st_mode & S_IFMT
            if entryKind == S_IFDIR {
                if isPackageDirectory(name: name) {
                    skippedPackageCount += 1
                    continue
                }

                if recursive {
                    let childDescriptor = name.withCString { entryName in
                        openat(
                            currentDescriptor,
                            entryName,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                    guard childDescriptor >= 0 else {
                        if errno == ENOENT || errno == ELOOP { continue }
                        throw ReviewError.unreadableSourceFolder
                    }
                    defer { Darwin.close(childDescriptor) }
                    var childInfo = stat()
                    guard fstat(childDescriptor, &childInfo) == 0,
                          (childInfo.st_mode & S_IFMT) == S_IFDIR,
                          childInfo.st_dev == entryInfo.st_dev,
                          childInfo.st_ino == entryInfo.st_ino
                    else { continue }

                    try await walkDirectory(
                        root: root,
                        rootDescriptor: rootDescriptor,
                        currentDescriptor: childDescriptor,
                        directoryComponents: directoryComponents + [name],
                        directoryChain: directoryChain + [OpenDirectoryIdentity(childInfo)],
                        recursive: recursive,
                        includeVideos: includeVideos,
                        items: &items,
                        skippedHiddenCount: &skippedHiddenCount,
                        skippedUnsupportedCount: &skippedUnsupportedCount,
                        skippedPackageCount: &skippedPackageCount,
                        skippedSymlinkDirectoryCount: &skippedSymlinkDirectoryCount
                    )
                }

                continue
            }

            guard entryKind == S_IFREG else {
                continue
            }

            let fileDescriptor = name.withCString { entryName in
                openat(
                    currentDescriptor,
                    entryName,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard fileDescriptor >= 0 else {
                if errno == ENOENT || errno == ELOOP { continue }
                skippedUnsupportedCount += 1
                continue
            }
            defer { Darwin.close(fileDescriptor) }

            var scannedFileInfo = stat()
            guard fstat(fileDescriptor, &scannedFileInfo) == 0,
                  (scannedFileInfo.st_mode & S_IFMT) == S_IFREG,
                  scannedFileInfo.st_dev == entryInfo.st_dev,
                  scannedFileInfo.st_ino == entryInfo.st_ino
            else { continue }

            let fileURL = URL(fileURLWithPath: name)
            let fileExtension = fileURL.pathExtension
            let contentType = UTType(filenameExtension: fileExtension)
            let mediaKind: MediaKind? = {
                guard let contentType else { return nil }
                if contentType.conforms(to: .image) { return .image }
                if contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) {
                    return .video
                }
                return nil
            }()

            guard
                let mediaKind,
                includeVideos || mediaKind != .video,
                contentType != nil
            else {
                skippedUnsupportedCount += 1
                continue
            }

            let fallbackCreationDate = date(from: scannedFileInfo.st_birthtimespec)
            let fallbackModificationDate = date(from: scannedFileInfo.st_mtimespec)
            let fallbackDate = fallbackCreationDate ?? fallbackModificationDate
            await beforeMetadataRead?()
            let (captureDate, dateSource) = await captureDate(
                fileDescriptor: fileDescriptor,
                fileExtension: fileExtension,
                contentTypeIdentifier: contentType!.identifier,
                fileSize: Int64(scannedFileInfo.st_size),
                mediaKind: mediaKind
            )
            try Task.checkCancellation()

            // Keep discovery attached to the opened tree and file. AVFoundation may
            // suspend while video metadata is loading, so recheck both names afterward.
            var currentFileInfo = stat()
            let currentFileStatus = name.withCString { entryName in
                fstatat(currentDescriptor, entryName, &currentFileInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard directoryChainIsAttached(
                    root: root,
                    rootDescriptor: rootDescriptor,
                    directoryComponents: directoryComponents,
                    expectedChain: directoryChain,
                    currentDescriptor: currentDescriptor
                  ),
                  currentFileStatus == 0,
                  (currentFileInfo.st_mode & S_IFMT) == S_IFREG,
                  currentFileInfo.st_dev == scannedFileInfo.st_dev,
                  currentFileInfo.st_ino == scannedFileInfo.st_ino
            else {
                skippedUnsupportedCount += 1
                continue
            }

            let standardizedURL = root
                .appending(path: (directoryComponents + [name]).joined(separator: "/"))
                .standardizedFileURL

            let resolvedDateSource: String = {
                if let dateSource {
                    return dateSource
                }
                if fallbackCreationDate != nil {
                    return "File created"
                }
                if fallbackModificationDate != nil {
                    return "File modified"
                }
                return "Date unavailable"
            }()

            let relativePath = (directoryComponents + [name]).joined(separator: "/")
            let badges = badges(for: mediaKind, pathExtension: standardizedURL.pathExtension)
            items.append(
                ReviewItem(
                    id: standardizedURL.path,
                    source: .file(path: standardizedURL.path, relativePath: relativePath),
                    displayName: name,
                    mediaKind: mediaKind,
                    primaryDate: captureDate,
                    fallbackDate: fallbackDate,
                    byteSize: Int64(scannedFileInfo.st_size),
                    badgeLabels: badges,
                    detailLabel: resolvedDateSource,
                    fileDeviceNumber: UInt64(scannedFileInfo.st_dev),
                    fileInodeNumber: UInt64(scannedFileInfo.st_ino)
                )
            )
        }
    }

    @MainActor
    func thumbnail(for item: ReviewItem, maxPixel: CGFloat, sourceFolderURL: URL?) async -> NSImage? {
        guard let sourceFolderURL,
              let fileDescriptor = openItemDescriptor(for: item, under: sourceFolderURL)
        else { return nil }
        defer { Darwin.close(fileDescriptor) }

        var fileInfo = stat()
        guard fstat(fileDescriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG
        else { return nil }

        switch item.mediaKind {
        case .image:
            return imageThumbnail(fileDescriptor: fileDescriptor, maxPixel: maxPixel)
        case .video:
            let fileExtension = item.absolutePath.map { URL(fileURLWithPath: $0).pathExtension } ?? ""
            guard let contentType = UTType(filenameExtension: fileExtension),
                  contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent)
            else { return nil }
            guard let assetParts = descriptorBackedVideoAsset(
                fileDescriptor: fileDescriptor,
                fileExtension: fileExtension,
                contentTypeIdentifier: contentType.identifier,
                fileSize: Int64(fileInfo.st_size)
            ) else { return nil }
            let generator = AVAssetImageGenerator(asset: assetParts.0)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            do {
                let generated = try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600))
                withExtendedLifetime(assetParts.1) {}
                let image = generated.image
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            } catch {
                withExtendedLifetime(assetParts.1) {}
                return nil
            }
        }
    }

    func previewPlayer(for item: ReviewItem, sourceFolderURL: URL?) -> FolderVideoPreviewLease? {
        guard item.isVideo,
              let sourceFolderURL,
              let path = item.absolutePath,
              let fileDescriptor = openItemDescriptor(for: item, under: sourceFolderURL)
        else { return nil }
        defer { Darwin.close(fileDescriptor) }

        var fileInfo = stat()
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard let contentType = UTType(filenameExtension: fileExtension),
              contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent)
        else { return nil }
        guard fstat(fileDescriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              let assetParts = descriptorBackedVideoAsset(
                fileDescriptor: fileDescriptor,
                fileExtension: fileExtension,
                contentTypeIdentifier: contentType.identifier,
                fileSize: Int64(fileInfo.st_size)
              )
        else { return nil }

        return FolderVideoPreviewLease(asset: assetParts.0, resourceLoader: assetParts.1)
    }

    func existingItems(from storedItems: [ReviewItem]) -> [ReviewItem] {
        storedItems.filter { item in
            guard let path = item.absolutePath else {
                return false
            }
            return fileManager.fileExists(atPath: path)
        }
    }

    private func resolvedURL(for selection: FolderSelection, allowStale: Bool) -> URL? {
        guard let bookmarkDataBase64 = selection.bookmarkDataBase64,
              let bookmarkData = Data(base64Encoded: bookmarkDataBase64)
        else {
            return URL(fileURLWithPath: selection.resolvedPath, isDirectory: true).standardizedFileURL
        }

        var isStale = false
        let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale && !allowStale {
            return nil
        }

        return resolved?.standardizedFileURL
    }

    private func badges(for mediaKind: MediaKind, pathExtension: String) -> [String] {
        var badges: [String] = [mediaKind == .video ? "VIDEO" : "IMAGE"]
        if !pathExtension.isEmpty {
            badges.append(pathExtension.uppercased())
        }
        return badges
    }

    private func captureDate(
        fileDescriptor: Int32,
        fileExtension: String,
        contentTypeIdentifier: String,
        fileSize: Int64,
        mediaKind: MediaKind
    ) async -> (Date?, String?) {
        switch mediaKind {
        case .image:
            if let date = imageCaptureDate(fileDescriptor: fileDescriptor) {
                return (date, "Taken")
            }
        case .video:
            if let date = await videoCaptureDate(
                fileDescriptor: fileDescriptor,
                fileExtension: fileExtension,
                contentTypeIdentifier: contentTypeIdentifier,
                fileSize: fileSize
            ) {
                return (date, "Captured")
            }
        }

        return (nil, nil)
    }

    private func imageCaptureDate(fileDescriptor: Int32) -> Date? {
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(fileDescriptor)")
        guard
            let source = CGImageSourceCreateWithURL(descriptorURL as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }

        if
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            let parsed = parseEXIFDate(value)
        {
            return parsed
        }

        if
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
            let value = tiff[kCGImagePropertyTIFFDateTime] as? String,
            let parsed = parseEXIFDate(value)
        {
            return parsed
        }

        return nil
    }

    private func videoCaptureDate(
        fileDescriptor: Int32,
        fileExtension: String,
        contentTypeIdentifier: String,
        fileSize: Int64
    ) async -> Date? {
        guard let (asset, resourceLoader) = descriptorBackedVideoAsset(
            fileDescriptor: fileDescriptor,
            fileExtension: fileExtension,
            contentTypeIdentifier: contentTypeIdentifier,
            fileSize: fileSize
        ) else { return nil }

        if let metadataDate = try? await asset.load(.creationDate) {
            if let loadedDate = try? await metadataDate.load(.dateValue) {
                withExtendedLifetime(resourceLoader) {}
                return loadedDate
            }

            if
                let loadedString = try? await metadataDate.load(.stringValue),
                let parsed = parseFlexibleDate(loadedString)
            {
                withExtendedLifetime(resourceLoader) {}
                return parsed
            }
        }

        withExtendedLifetime(resourceLoader) {}
        return nil
    }

    private func descriptorBackedVideoAsset(
        fileDescriptor: Int32,
        fileExtension: String,
        contentTypeIdentifier: String,
        fileSize: Int64
    ) -> (AVURLAsset, DescriptorAssetResourceLoader)? {
        guard !contentTypeIdentifier.isEmpty else { return nil }
        guard let resourceLoader = try? DescriptorAssetResourceLoader(
            sourceFileDescriptor: fileDescriptor,
            contentLength: fileSize,
            contentType: contentTypeIdentifier
        ) else { return nil }

        var components = URLComponents()
        components.scheme = "photos-sort-descriptor"
        components.host = UUID().uuidString.lowercased()
        components.path = "/asset\(fileExtension.isEmpty ? "" : ".\(fileExtension)" )"
        guard let url = components.url else { return nil }

        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.callbackQueue)
        return (asset, resourceLoader)
    }

    private func parseEXIFDate(_ raw: String) -> Date? {
        let formatters: [DateFormatter] = [
            makeDateFormatter("yyyy:MM:dd HH:mm:ss"),
            makeDateFormatter("yyyy:MM:dd HH:mm:ssXXXXX"),
            makeDateFormatter("yyyy-MM-dd HH:mm:ss")
        ]

        for formatter in formatters {
            if let parsed = formatter.date(from: raw) {
                return parsed
            }
        }

        return parseFlexibleDate(raw)
    }

    private func parseFlexibleDate(_ raw: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = isoFormatter.date(from: raw) {
            return parsed
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: raw)
    }

    private func makeDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private func imageThumbnail(fileDescriptor: Int32, maxPixel: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: "/dev/fd/\(fileDescriptor)")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(128, Int(maxPixel))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func folderSortPredicate(_ lhs: ReviewItem, _ rhs: ReviewItem) -> Bool {
        let lhsDate = lhs.sortDate
        let rhsDate = rhs.sortDate
        if lhsDate == rhsDate {
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return lhsDate < rhsDate
    }

    private func openDirectoryDescriptor(at path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP { throw ReviewError.sourceFolderIsSymbolicLink }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return descriptor
    }

    private func openItemDescriptor(for item: ReviewItem, under sourceFolderURL: URL) -> Int32? {
        guard let relativePath = item.relativePath,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.utf8.contains(0)
        else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }

        var currentDescriptor = Darwin.open(
            sourceFolderURL.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else { return nil }
        defer { Darwin.close(currentDescriptor) }

        for component in components.dropLast() {
            let childDescriptor = component.withCString { name in
                openat(
                    currentDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard childDescriptor >= 0 else { return nil }
            Darwin.close(currentDescriptor)
            currentDescriptor = childDescriptor
        }

        let fileDescriptor = components[components.count - 1].withCString { name in
            openat(currentDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fileDescriptor >= 0 else { return nil }
        var info = stat()
        let identityMatches = fstat(fileDescriptor, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && (item.fileDeviceNumber.map { UInt64(info.st_dev) == $0 } ?? true)
            && (item.fileInodeNumber.map { UInt64(info.st_ino) == $0 } ?? true)
        guard identityMatches else {
            Darwin.close(fileDescriptor)
            return nil
        }
        return fileDescriptor
    }

    private func directoryEntryNamesWithoutFollowingSymlinks(at descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard let directory = fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let code = errno
                guard code == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                break
            }
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    private func directoryChainIsAttached(
        root: URL,
        rootDescriptor: Int32,
        directoryComponents: [String],
        expectedChain: [OpenDirectoryIdentity],
        currentDescriptor: Int32
    ) -> Bool {
        guard expectedChain.count == directoryComponents.count + 1 else { return false }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              OpenDirectoryIdentity(rootInfo) == expectedChain[0]
        else { return false }

        let pathDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard pathDescriptor >= 0 else { return false }
        var pathInfo = stat()
        let pathMatches = fstat(pathDescriptor, &pathInfo) == 0
            && OpenDirectoryIdentity(pathInfo) == expectedChain[0]
        Darwin.close(pathDescriptor)
        guard pathMatches else { return false }

        var parentDescriptor = dup(rootDescriptor)
        guard parentDescriptor >= 0 else { return false }
        defer { Darwin.close(parentDescriptor) }

        for (index, component) in directoryComponents.enumerated() {
            let childDescriptor = component.withCString { name in
                openat(
                    parentDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard childDescriptor >= 0 else { return false }
            var childInfo = stat()
            let childMatches = fstat(childDescriptor, &childInfo) == 0
                && OpenDirectoryIdentity(childInfo) == expectedChain[index + 1]
            let previousDescriptor = parentDescriptor
            parentDescriptor = childDescriptor
            Darwin.close(previousDescriptor)
            guard childMatches else { return false }
        }

        var currentInfo = stat()
        return fstat(currentDescriptor, &currentInfo) == 0
            && OpenDirectoryIdentity(currentInfo) == expectedChain.last
    }

    private func isPackageDirectory(name: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: name).pathExtension
        guard !fileExtension.isEmpty else { return false }
        if UTType(filenameExtension: fileExtension)?.conforms(to: .package) == true {
            return true
        }
        return Self.packageExtensions.contains { $0.caseInsensitiveCompare(fileExtension) == .orderedSame }
    }

    private func date(from value: timespec) -> Date? {
        guard value.tv_sec != 0 || value.tv_nsec != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000)
    }

}
