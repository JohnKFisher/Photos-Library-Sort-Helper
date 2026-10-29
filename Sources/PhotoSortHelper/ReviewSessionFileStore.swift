import Foundation

struct ReviewSessionFileStore {
    struct Entry {
        let session: StoredReviewSession
        let data: Data
        let url: URL
    }

    enum StoreError: LocalizedError {
        case invalidFolderSession
        case copyVerificationFailed

        var errorDescription: String? {
            switch self {
            case .invalidFolderSession:
                "Only Folder review sessions can be saved to the Folder session file."
            case .copyVerificationFailed:
                "The copied Folder review session did not pass its read-back check."
            }
        }
    }

    let legacyURL: URL
    let folderURL: URL
    let fileManager: FileManager

    func loadPreferred(
        selectedSourceKind: ReviewSourceKind,
        hasStoredSourcePreference: Bool
    ) -> Entry? {
        guard hasStoredSourcePreference else { return loadPreferred() }
        guard selectedSourceKind == .folder else { return nil }

        if let folder = load(from: folderURL), folder.session.selectedSourceKind == .folder {
            return folder
        }
        guard let legacy = loadLegacy(), legacy.session.selectedSourceKind == .folder else { return nil }
        return legacy
    }

    func loadPreferred() -> Entry? {
        if let folder = load(from: folderURL), folder.session.selectedSourceKind == .folder {
            return folder
        }
        return loadLegacy()
    }

    func loadLegacy() -> Entry? {
        load(from: legacyURL)
    }

    /// Copies an old Folder session to its new writable path without consuming the
    /// original file. Read-back equality proves the copy-forward completed intact.
    func copyForwardLegacyFolder(_ entry: Entry) throws -> Entry {
        guard entry.url.standardizedFileURL == legacyURL.standardizedFileURL,
              entry.session.selectedSourceKind == .folder else {
            throw StoreError.invalidFolderSession
        }
        try saveFolderData(entry.data)
        guard let copied = load(from: folderURL), copied.session.selectedSourceKind == .folder,
              copied.data == entry.data else {
            throw StoreError.copyVerificationFailed
        }
        return copied
    }

    func saveFolderData(_ data: Data) throws {
        guard let session = decode(data), session.selectedSourceKind == .folder else {
            throw StoreError.invalidFolderSession
        }
        try fileManager.createDirectory(at: folderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: folderURL, options: [.atomic])
        guard (try Data(contentsOf: folderURL)) == data else {
            throw StoreError.copyVerificationFailed
        }
    }

    private func load(from url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url), let session = decode(data) else { return nil }
        return Entry(session: session, data: data, url: url)
    }

    private func decode(_ data: Data) -> StoredReviewSession? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredReviewSession.self, from: data)
    }
}
