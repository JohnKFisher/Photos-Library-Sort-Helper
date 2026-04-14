import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FolderScanListing: Sendable {
    var items: [ReviewItem]
    var skippedHiddenCount: Int
    var skippedUnsupportedCount: Int
    var skippedPackageCount: Int
    var skippedSymlinkDirectoryCount: Int
}

final class FolderLibraryService: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @MainActor
    func chooseFolder(initialSelection: FolderSelection?) -> FolderSelection? {
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

        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
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
        let sourceFolderURL = try resolveValidatedFolderURL(for: selection)

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .nameKey,
            .typeIdentifierKey,
            .contentTypeKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]

        var items: [ReviewItem] = []
        var skippedHiddenCount = 0
        var skippedUnsupportedCount = 0
        var skippedPackageCount = 0
        var skippedSymlinkDirectoryCount = 0

        try await walkDirectory(
            root: sourceFolderURL,
            current: sourceFolderURL,
            recursive: recursive,
            includeVideos: includeVideos,
            keys: keys,
            items: &items,
            skippedHiddenCount: &skippedHiddenCount,
            skippedUnsupportedCount: &skippedUnsupportedCount,
            skippedPackageCount: &skippedPackageCount,
            skippedSymlinkDirectoryCount: &skippedSymlinkDirectoryCount
        )

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
        current: URL,
        recursive: Bool,
        includeVideos: Bool,
        keys: [URLResourceKey],
        items: inout [ReviewItem],
        skippedHiddenCount: inout Int,
        skippedUnsupportedCount: inout Int,
        skippedPackageCount: inout Int,
        skippedSymlinkDirectoryCount: inout Int
    ) async throws {
        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: current.path)
        } catch {
            throw ReviewError.unreadableSourceFolder
        }

        for name in contents.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let url = current.appendingPathComponent(name, isDirectory: false)
            let standardizedURL = url.standardizedFileURL
            let values = try? standardizedURL.resourceValues(forKeys: Set(keys))
            let isSymbolicLink = isSymbolicLinkPath(url.path)

            if values?.isHidden == true {
                skippedHiddenCount += 1
                continue
            }

            if isSymbolicLink {
                skippedSymlinkDirectoryCount += 1
                continue
            }

            if values?.isDirectory == true {
                if values?.isPackage == true {
                    skippedPackageCount += 1
                    continue
                }

                if recursive {
                    try await walkDirectory(
                        root: root,
                        current: standardizedURL,
                        recursive: recursive,
                        includeVideos: includeVideos,
                        keys: keys,
                        items: &items,
                        skippedHiddenCount: &skippedHiddenCount,
                        skippedUnsupportedCount: &skippedUnsupportedCount,
                        skippedPackageCount: &skippedPackageCount,
                        skippedSymlinkDirectoryCount: &skippedSymlinkDirectoryCount
                    )
                }

                continue
            }

            guard values?.isRegularFile == true else {
                continue
            }

            guard
                let mediaKind = mediaKind(for: standardizedURL, resourceValues: values),
                includeVideos || mediaKind != .video,
                resolvedTypeIdentifier(for: standardizedURL, resourceValues: values) != nil
            else {
                skippedUnsupportedCount += 1
                continue
            }

            let fallbackCreationDate = values?.creationDate
            let fallbackModificationDate = values?.contentModificationDate
            let fallbackDate = fallbackCreationDate ?? fallbackModificationDate

            let (captureDate, dateSource) = await captureDate(for: standardizedURL, mediaKind: mediaKind)
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

            let relativePath = standardizedURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let badges = badges(for: mediaKind, pathExtension: standardizedURL.pathExtension)
            items.append(
                ReviewItem(
                    id: standardizedURL.path,
                    source: .file(path: standardizedURL.path, relativePath: relativePath),
                    displayName: values?.name ?? standardizedURL.lastPathComponent,
                    mediaKind: mediaKind,
                    primaryDate: captureDate,
                    fallbackDate: fallbackDate,
                    byteSize: Int64(values?.fileSize ?? 0),
                    badgeLabels: badges,
                    detailLabel: resolvedDateSource
                )
            )
        }
    }

    @MainActor
    func thumbnail(for item: ReviewItem, maxPixel: CGFloat) async -> NSImage? {
        switch item.mediaKind {
        case .image:
            return await imageThumbnail(for: item, maxPixel: maxPixel)
        case .video:
            return await videoThumbnail(for: item, maxPixel: maxPixel)
        }
    }

    func featurePrintCGImage(for item: ReviewItem, maxPixel: CGFloat = 320) async -> CGImage? {
        guard
            item.mediaKind == .image,
            let path = item.absolutePath,
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixel))
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func previewPlayer(for item: ReviewItem) -> AVPlayer? {
        guard item.isVideo, let path = item.absolutePath else {
            return nil
        }

        let player = AVPlayer(url: URL(fileURLWithPath: path))
        player.actionAtItemEnd = .pause
        return player
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

    private func resolvedTypeIdentifier(for url: URL, resourceValues: URLResourceValues?) -> String? {
        if let contentType = resourceValues?.contentType {
            return contentType.identifier
        }

        if let typeIdentifier = resourceValues?.typeIdentifier {
            return typeIdentifier
        }

        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension)
        else {
            return nil
        }

        return type.identifier
    }

    private func mediaKind(for url: URL, resourceValues: URLResourceValues?) -> MediaKind? {
        let type = resourceValues?.contentType
            ?? (resourceValues?.typeIdentifier).flatMap { UTType($0) }
            ?? UTType(filenameExtension: url.pathExtension)

        guard let type else {
            return nil
        }

        if type.conforms(to: .image) {
            return .image
        }

        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            return .video
        }

        return nil
    }

    private func badges(for mediaKind: MediaKind, pathExtension: String) -> [String] {
        var badges: [String] = [mediaKind == .video ? "VIDEO" : "IMAGE"]
        if !pathExtension.isEmpty {
            badges.append(pathExtension.uppercased())
        }
        return badges
    }

    private func captureDate(for url: URL, mediaKind: MediaKind) async -> (Date?, String?) {
        switch mediaKind {
        case .image:
            if let date = imageCaptureDate(from: url) {
                return (date, "Taken")
            }
        case .video:
            if let date = await videoCaptureDate(from: url) {
                return (date, "Captured")
            }
        }

        return (nil, nil)
    }

    private func imageCaptureDate(from url: URL) -> Date? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
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

    private func videoCaptureDate(from url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)

        if let metadataDate = try? await asset.load(.creationDate) {
            if let loadedDate = try? await metadataDate.load(.dateValue) {
                return loadedDate
            }

            if
                let loadedString = try? await metadataDate.load(.stringValue),
                let parsed = parseFlexibleDate(loadedString)
            {
                return parsed
            }
        }

        return nil
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

    @MainActor
    private func imageThumbnail(for item: ReviewItem, maxPixel: CGFloat) async -> NSImage? {
        guard
            let path = item.absolutePath,
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else {
            return nil
        }

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

    @MainActor
    private func videoThumbnail(for item: ReviewItem, maxPixel: CGFloat) async -> NSImage? {
        guard let path = item.absolutePath else {
            return nil
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        let timestamp = CMTime(seconds: 0.0, preferredTimescale: 600)
        do {
            let generated = try await generator.image(at: timestamp)
            let image = generated.image
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch {
            return nil
        }
    }

    private func folderSortPredicate(_ lhs: ReviewItem, _ rhs: ReviewItem) -> Bool {
        let lhsDate = lhs.sortDate
        let rhsDate = rhs.sortDate
        if lhsDate == rhsDate {
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return lhsDate < rhsDate
    }

    private func isSymbolicLinkPath(_ path: String) -> Bool {
        var fileInfo = stat()
        return lstat(path, &fileInfo) == 0 && (fileInfo.st_mode & S_IFMT) == S_IFLNK
    }

}
