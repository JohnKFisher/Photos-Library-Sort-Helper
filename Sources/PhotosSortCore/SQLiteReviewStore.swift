import CSQLite
import Foundation

public enum SQLiteReviewStoreError: Error, LocalizedError, Equatable {
    case open(String)
    case sqlite(code: Int32, message: String)
    case unsupportedSchema(Int32)
    case noPendingItems
    case migrationValidationFailed
    case invalidDatabaseSnapshot

    public var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open local review database: \(message)"
        case .sqlite(_, let message): "Local review database error: \(message)"
        case .unsupportedSchema(let version): "Local review database schema version \(version) is not supported."
        case .noPendingItems: "There are no pending review choices to commit."
        case .migrationValidationFailed: "The imported review state did not match its source. The original session remains available."
        case .invalidDatabaseSnapshot: "The copied local review database failed its integrity check. The original database remains available."
        }
    }
}

/// Per-device transactional persistence. No Photos, UI, or SQL row types escape this boundary.
public final class SQLiteReviewStore: @unchecked Sendable {
    public static let currentSchemaVersion: Int32 = 2

    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite did not return a database handle."
            if let handle { sqlite3_close(handle) }
            throw SQLiteReviewStoreError.open(message)
        }
        database = handle
        sqlite3_busy_timeout(handle, 5_000)
        try withLock {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            let version = try scalarInt("PRAGMA user_version")
            guard version <= Self.currentSchemaVersion else {
                throw SQLiteReviewStoreError.unsupportedSchema(Int32(version))
            }
            if version == 0 { try createSchema() }
            else if version == 1 { try migrateToSchemaV2() }
        }
    }

    /// Creates a standalone, integrity-checked snapshot from a quiescent database copy.
    /// Opening the copied source read/write lets SQLite recover a copied WAL or rollback
    /// journal without modifying the original user database.
    public static func createConsistentSnapshot(fromQuiescentCopy sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var source: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceResult == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite did not return a source database handle."
            if let source { sqlite3_close(source) }
            throw SQLiteReviewStoreError.open(message)
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 5_000)

        var destination: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite did not return a destination database handle."
            if let destination { sqlite3_close(destination) }
            throw SQLiteReviewStoreError.open(message)
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, 5_000)

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SQLiteReviewStoreError.sqlite(
                code: sqlite3_errcode(destination),
                message: String(cString: sqlite3_errmsg(destination))
            )
        }

        var stepResult: Int32
        var retryCount = 0
        repeat {
            stepResult = sqlite3_backup_step(backup, -1)
            if stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
                retryCount += 1
                if retryCount <= 50 { Thread.sleep(forTimeInterval: 0.1) }
            }
        } while stepResult == SQLITE_OK
            || ((stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED) && retryCount <= 50)

        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let code = stepResult == SQLITE_DONE ? finishResult : stepResult
            throw SQLiteReviewStoreError.sqlite(
                code: code,
                message: String(cString: sqlite3_errmsg(destination))
            )
        }

        try validateDatabaseSnapshot(destination)
    }

    private static func validateDatabaseSnapshot(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let integrityResult = sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil)
        guard integrityResult == SQLITE_OK, let statement else {
            throw SQLiteReviewStoreError.sqlite(
                code: integrityResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let integrityText = sqlite3_column_text(statement, 0),
              String(cString: integrityText) == "ok" else {
            throw SQLiteReviewStoreError.invalidDatabaseSnapshot
        }

        var versionStatement: OpaquePointer?
        let versionResult = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil)
        guard versionResult == SQLITE_OK, let versionStatement else {
            throw SQLiteReviewStoreError.sqlite(
                code: versionResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(versionStatement) }

        guard sqlite3_step(versionStatement) == SQLITE_ROW else {
            throw SQLiteReviewStoreError.invalidDatabaseSnapshot
        }
        let version = sqlite3_column_int(versionStatement, 0)
        guard version <= currentSchemaVersion else {
            throw SQLiteReviewStoreError.unsupportedSchema(version)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    @discardableResult
    public func setExplicitDecision(
        libraryKey: String,
        assetID: String,
        cloudIdentifier: String? = nil,
        decision: ReviewDecision,
        scopeID: String,
        groupID: String
    ) throws -> PendingReviewItem {
        try withLock {
            try transaction {
                let row = PendingReviewItem(
                    libraryKey: libraryKey,
                    assetID: assetID,
                    cloudIdentifier: cloudIdentifier,
                    decision: decision,
                    origin: .explicit,
                    revision: try nextRevision(),
                    scopeID: scopeID,
                    groupID: groupID,
                    updatedAt: Date()
                )
                try upsert(row)
                return try pendingItem(libraryKey: libraryKey, assetID: assetID) ?? row
            }
        }
    }

    /// Freezes only untouched items and persists the group completion and next scope position atomically.
    public func completeGroup(
        _ group: ReviewGroupSnapshot,
        defaultDecision: ReviewDecision,
        libraryKey: String,
        cloudIdentifiers: [String: String] = [:],
        nextPosition: ScopePosition
    ) throws {
        try withLock {
            try transaction {
                try save(group: group, state: .completed)
                for assetID in group.itemIDs {
                    guard try pendingItem(libraryKey: libraryKey, assetID: assetID) == nil else { continue }
                    let row = PendingReviewItem(
                        libraryKey: libraryKey,
                        assetID: assetID,
                        cloudIdentifier: cloudIdentifiers[assetID],
                        decision: defaultDecision,
                        origin: .completedDefault,
                        revision: try nextRevision(),
                        scopeID: group.scopeID,
                        groupID: group.id,
                        updatedAt: Date()
                    )
                    try upsert(row, insertOnly: true)
                }
                try save(position: nextPosition)
            }
        }
    }

    /// Skipping advances the cursor and saves the group without inventing choices for untouched items.
    public func skipGroup(_ group: ReviewGroupSnapshot, nextPosition: ScopePosition) throws {
        try withLock {
            try transaction {
                try save(group: group, state: .skipped)
                try save(position: nextPosition)
            }
        }
    }

    public func save(group: ReviewGroupSnapshot, state: SavedGroupState? = nil, insertOnly: Bool = false) throws {
        try withLock {
            var group = group
            if let state { group.state = state }
            let payload = try encode(group)
            let conflictAction = insertOnly ? "DO NOTHING" : """
                DO UPDATE SET
                    scope_id=excluded.scope_id,
                    position=excluded.position,
                    payload=excluded.payload,
                    state=excluded.state
                """
            try execute(
                """
                INSERT INTO review_groups(group_id, scope_id, position, payload, state)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(group_id) \(conflictAction)
                """
            ) { statement in
                try self.bind(group.id, at: 1, in: statement)
                try self.bind(group.scopeID, at: 2, in: statement)
                sqlite3_bind_int64(statement, 3, Int64(group.position))
                try self.bind(payload, at: 4, in: statement)
                try self.bind(group.state.rawValue, at: 5, in: statement)
            }
        }
    }

    public func save(position: ScopePosition) throws {
        try withLock {
            let payload = try encode(position)
            try execute(
                """
                INSERT INTO review_scopes(scope_id, payload, updated_at) VALUES(?, ?, ?)
                ON CONFLICT(scope_id) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at
                """
            ) { statement in
                try self.bind(position.id, at: 1, in: statement)
                try self.bind(payload, at: 2, in: statement)
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            }
        }
    }

    public func position(scopeID: String) throws -> ScopePosition? {
        try withLock {
            try queryOne("SELECT payload FROM review_scopes WHERE scope_id = ?", bind: { try self.bind(scopeID, at: 1, in: $0) }) {
                try decode(ScopePosition.self, from: columnText($0, 0))
            }
        }
    }

    public func groups(scopeID: String) throws -> [ReviewGroupSnapshot] {
        try withLock {
            try queryMany(
                "SELECT payload FROM review_groups WHERE scope_id = ? ORDER BY position, group_id",
                bind: { try self.bind(scopeID, at: 1, in: $0) },
                read: { try decode(ReviewGroupSnapshot.self, from: columnText($0, 0)) }
            )
        }
    }

    /// Replaces a fully indexed scope frontier atomically while preserving each
    /// snapshot's explicit unresolved/completed/skipped state.
    public func replaceGroups(scopeID: String, with snapshots: [ReviewGroupSnapshot]) throws {
        try withLock {
            try transaction {
                try execute("DELETE FROM review_groups WHERE scope_id = ?") {
                    try self.bind(scopeID, at: 1, in: $0)
                }
                for snapshot in snapshots where snapshot.scopeID == scopeID {
                    try save(group: snapshot)
                }
            }
        }
    }

    /// Removes committed assets from the saved review frontier without erasing the
    /// surrounding group's completion history or scope position.
    public func removeItemsFromGroups(scopeID: String, assetIDs: Set<String>) throws {
        guard !assetIDs.isEmpty else { return }
        try withLock {
            try transaction {
                let snapshots = try groups(scopeID: scopeID)
                for snapshot in snapshots {
                    let remaining = snapshot.itemIDs.filter { !assetIDs.contains($0) }
                    guard remaining.count != snapshot.itemIDs.count else { continue }
                    try save(group: ReviewGroupSnapshot(
                        id: snapshot.id,
                        scopeID: snapshot.scopeID,
                        position: snapshot.position,
                        itemIDs: remaining,
                        startDate: snapshot.startDate,
                        endDate: snapshot.endDate,
                        groupingFingerprint: snapshot.groupingFingerprint,
                        state: snapshot.state
                    ))
                }
            }
        }
    }

    public func pendingItems(libraryKey: String) throws -> [PendingReviewItem] {
        try withLock {
            try queryMany(
                "SELECT library_key, asset_id, cloud_id, decision, origin, revision, scope_id, group_id, status, updated_at FROM pending_items WHERE library_key = ? ORDER BY updated_at, asset_id",
                bind: { try self.bind(libraryKey, at: 1, in: $0) },
                read: readPendingItem
            )
        }
    }

    public func queuedAssetIDs(libraryKey: String) throws -> Set<String> {
        try withLock {
            Set(try queryMany(
                "SELECT asset_id FROM pending_items WHERE library_key = ?",
                bind: { try self.bind(libraryKey, at: 1, in: $0) },
                read: { columnText($0, 0) }
            ))
        }
    }

    public func bindAlbum(_ binding: DestinationAlbumBinding) throws {
        try withLock {
            try execute(
                """
                INSERT INTO album_bindings(library_key, role, local_identifier, cloud_identifier, title, updated_at)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(library_key, role) DO UPDATE SET
                    local_identifier=excluded.local_identifier,
                    cloud_identifier=excluded.cloud_identifier,
                    title=excluded.title,
                    updated_at=excluded.updated_at
                """
            ) { statement in
                try self.bind(binding.libraryKey, at: 1, in: statement)
                try self.bind(binding.role.rawValue, at: 2, in: statement)
                try self.bind(binding.localIdentifier, at: 3, in: statement)
                try self.bind(binding.cloudIdentifier, at: 4, in: statement)
                try self.bind(binding.title, at: 5, in: statement)
                sqlite3_bind_double(statement, 6, binding.updatedAt.timeIntervalSince1970)
            }
        }
    }

    public func albumBindings(libraryKey: String) throws -> [DestinationAlbumBinding] {
        try withLock {
            try queryMany(
                "SELECT library_key, role, local_identifier, cloud_identifier, title, updated_at FROM album_bindings WHERE library_key = ? ORDER BY role",
                bind: { try self.bind(libraryKey, at: 1, in: $0) },
                read: { statement in
                    DestinationAlbumBinding(
                        libraryKey: columnText(statement, 0),
                        role: DestinationRole(rawValue: columnText(statement, 1)) ?? .edit,
                        localIdentifier: columnText(statement, 2),
                        cloudIdentifier: columnOptionalText(statement, 3),
                        title: columnText(statement, 4),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                    )
                }
            )
        }
    }

    public func pendingItem(libraryKey: String, assetID: String) throws -> PendingReviewItem? {
        try withLock {
            try queryOne(
                "SELECT library_key, asset_id, cloud_id, decision, origin, revision, scope_id, group_id, status, updated_at FROM pending_items WHERE library_key = ? AND asset_id = ?",
                bind: {
                    try self.bind(libraryKey, at: 1, in: $0)
                    try self.bind(assetID, at: 2, in: $0)
                },
                read: readPendingItem
            )
        }
    }

    public func updateStatus(libraryKey: String, assetID: String, status: PendingItemStatus) throws {
        try withLock {
            try execute("UPDATE pending_items SET status = ?, updated_at = ? WHERE library_key = ? AND asset_id = ?") { statement in
                try self.bind(status.rawValue, at: 1, in: statement)
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                try self.bind(libraryKey, at: 3, in: statement)
                try self.bind(assetID, at: 4, in: statement)
            }
        }
    }

    /// Applies a fresh PhotoKit membership observation, including work completed by another device.
    public func reconcileObservedMembership(
        libraryKey: String,
        assetID: String,
        revision: Int64,
        outcome: CommitItemOutcome
    ) throws {
        try withLock {
            try transaction {
                let current = try pendingItem(libraryKey: libraryKey, assetID: assetID)
                guard let current else { return }
                guard current.revision == revision else {
                    if outcome == .verifiedCommitted {
                        try updateStatus(libraryKey: libraryKey, assetID: assetID, status: .conflict)
                    }
                    return
                }
                switch outcome {
                case .verifiedCommitted:
                    try execute("DELETE FROM pending_items WHERE library_key = ? AND asset_id = ? AND revision = ?") { statement in
                        try self.bind(libraryKey, at: 1, in: statement)
                        try self.bind(assetID, at: 2, in: statement)
                        sqlite3_bind_int64(statement, 3, revision)
                    }
                case .conflict:
                    try updateStatus(libraryKey: libraryKey, assetID: assetID, status: .conflict)
                case .unavailable:
                    try updateStatus(libraryKey: libraryKey, assetID: assetID, status: .unavailable)
                case .retryable:
                    try updateStatus(libraryKey: libraryKey, assetID: assetID, status: .pending)
                }
            }
        }
    }

    /// Captures immutable classifications/revisions before any PhotoKit mutation is requested.
    public func beginCommit(libraryKey: String, attemptID: String = UUID().uuidString) throws -> CommitAttempt {
        try withLock {
            try transaction {
                let rows = try pendingItems(libraryKey: libraryKey).filter { $0.status == .pending }
                guard !rows.isEmpty else { throw SQLiteReviewStoreError.noPendingItems }
                let startedAt = Date()
                try execute("INSERT INTO commit_attempts(attempt_id, library_key, started_at, state) VALUES(?, ?, ?, 'prepared')") { statement in
                    try self.bind(attemptID, at: 1, in: statement)
                    try self.bind(libraryKey, at: 2, in: statement)
                    sqlite3_bind_double(statement, 3, startedAt.timeIntervalSince1970)
                }
                for row in rows {
                    try execute("INSERT INTO commit_items(attempt_id, library_key, asset_id, cloud_id, decision, revision, scope_id, group_id) VALUES(?, ?, ?, ?, ?, ?, ?, ?)") { statement in
                        try self.bind(attemptID, at: 1, in: statement)
                        try self.bind(row.libraryKey, at: 2, in: statement)
                        try self.bind(row.assetID, at: 3, in: statement)
                        try self.bind(row.cloudIdentifier, at: 4, in: statement)
                        try self.bind(row.decision.rawValue, at: 5, in: statement)
                        sqlite3_bind_int64(statement, 6, row.revision)
                        try self.bind(row.scopeID, at: 7, in: statement)
                        try self.bind(row.groupID, at: 8, in: statement)
                    }
                }
                return CommitAttempt(
                    id: attemptID,
                    startedAt: startedAt,
                    items: rows.map {
                        CommitItemIntent(
                            libraryKey: $0.libraryKey,
                            assetID: $0.assetID,
                            cloudIdentifier: $0.cloudIdentifier,
                            decision: $0.decision,
                            revision: $0.revision,
                            scopeID: $0.scopeID,
                            groupID: $0.groupID,
                            outcome: nil
                        )
                    }
                )
            }
        }
    }

    /// Reconciliation deletes only a queue row whose revision still matches the journaled intent.
    public func reconcile(attemptID: String, outcomes: [String: CommitItemOutcome]) throws {
        try withLock {
            try transaction {
                let state = try queryOne(
                    "SELECT state FROM commit_attempts WHERE attempt_id = ?",
                    bind: { try self.bind(attemptID, at: 1, in: $0) },
                    read: { columnText($0, 0) }
                )
                guard state == "prepared" else { return }
                let intents = try commitItems(attemptID: attemptID)
                for intent in intents {
                    guard intent.outcome == nil, let outcome = outcomes[intent.assetID] else { continue }
                    try execute("UPDATE commit_items SET outcome = ? WHERE attempt_id = ? AND asset_id = ?") { statement in
                        try self.bind(outcome.rawValue, at: 1, in: statement)
                        try self.bind(attemptID, at: 2, in: statement)
                        try self.bind(intent.assetID, at: 3, in: statement)
                    }
                    switch outcome {
                    case .verifiedCommitted:
                        let current = try pendingItem(libraryKey: intent.libraryKey, assetID: intent.assetID)
                        if current?.revision == intent.revision {
                            try execute("DELETE FROM pending_items WHERE library_key = ? AND asset_id = ? AND revision = ?") { statement in
                                try self.bind(intent.libraryKey, at: 1, in: statement)
                                try self.bind(intent.assetID, at: 2, in: statement)
                                sqlite3_bind_int64(statement, 3, intent.revision)
                            }
                        } else if current != nil {
                            try updateStatus(libraryKey: intent.libraryKey, assetID: intent.assetID, status: .conflict)
                        }
                    case .conflict:
                        let current = try pendingItem(libraryKey: intent.libraryKey, assetID: intent.assetID)
                        if current?.revision == intent.revision {
                            try updateStatus(libraryKey: intent.libraryKey, assetID: intent.assetID, status: .conflict)
                        } else if current != nil {
                            try updateStatus(libraryKey: intent.libraryKey, assetID: intent.assetID, status: .conflict)
                        }
                    case .unavailable:
                        let current = try pendingItem(libraryKey: intent.libraryKey, assetID: intent.assetID)
                        if current?.revision == intent.revision {
                            try updateStatus(libraryKey: intent.libraryKey, assetID: intent.assetID, status: .unavailable)
                        } else if current != nil {
                            try updateStatus(libraryKey: intent.libraryKey, assetID: intent.assetID, status: .conflict)
                        }
                    case .retryable:
                        let current = try pendingItem(libraryKey: intent.libraryKey, assetID: intent.assetID)
                        if current?.revision != intent.revision, current != nil {
                            try updateStatus(libraryKey: intent.libraryKey, assetID: intent.assetID, status: .conflict)
                        }
                    }
                }
                let remaining = try queryOne(
                    "SELECT COUNT(*) FROM commit_items WHERE attempt_id = ? AND outcome IS NULL",
                    bind: { try self.bind(attemptID, at: 1, in: $0) },
                    read: { Int(sqlite3_column_int($0, 0)) }
                ) ?? 0
                if remaining == 0 {
                    try execute("UPDATE commit_attempts SET state = 'reconciled' WHERE attempt_id = ?") { try self.bind(attemptID, at: 1, in: $0) }
                }
            }
        }
    }

    public func commitAttemptsNeedingRecovery() throws -> [CommitAttempt] {
        try withLock {
            let ids = try queryMany(
                "SELECT attempt_id FROM commit_attempts WHERE state != 'reconciled' ORDER BY started_at",
                bind: { _ in },
                read: { columnText($0, 0) }
            )
            return try ids.compactMap { id in
                guard let startedAt = try queryOne(
                    "SELECT started_at FROM commit_attempts WHERE attempt_id = ?",
                    bind: { try self.bind(id, at: 1, in: $0) },
                    read: { Date(timeIntervalSince1970: sqlite3_column_double($0, 0)) }
                ) else { return nil }
                return CommitAttempt(id: id, startedAt: startedAt, items: try commitItems(attemptID: id))
            }
        }
    }

    /// Imports legacy explicit work only. Legacy display-time "reviewed" flags do not imply completion.
    /// The source file is never deleted or rewritten by this repository.
    @discardableResult
    public func importLegacy(_ legacy: LegacyReviewImport) throws -> Bool {
        try withLock {
            try transaction {
                let existingVerified = try queryOne(
                    "SELECT verified FROM migration_receipts WHERE source_digest = ?",
                    bind: { try self.bind(legacy.sourceDigest, at: 1, in: $0) },
                    read: { sqlite3_column_int($0, 0) == 1 }
                )
                if existingVerified == true { return false }

                if existingVerified == nil {
                    try execute("INSERT INTO migration_receipts(source_digest, source_name, verified, imported_at) VALUES(?, 'review-session-v2.json', 0, ?)") { statement in
                        try self.bind(legacy.sourceDigest, at: 1, in: statement)
                        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                    }
                    for group in legacy.groups {
                        var unresolved = group
                        unresolved.state = .unresolved
                        try save(group: unresolved, insertOnly: true)
                    }
                    if try position(scopeID: legacy.scopePosition.id) == nil {
                        try save(position: legacy.scopePosition)
                    }
                    for decision in legacy.explicitDecisions {
                        let row = PendingReviewItem(
                            libraryKey: legacy.libraryKey,
                            assetID: decision.assetID,
                            cloudIdentifier: decision.cloudIdentifier,
                            decision: decision.decision,
                            origin: .explicit,
                            revision: try nextRevision(),
                            scopeID: decision.scopeID,
                            groupID: decision.groupID
                        )
                        try upsert(row, insertOnly: true)
                    }
                }

                let storedGroups = try groups(scopeID: legacy.scopePosition.id)
                let storedPosition = try position(scopeID: legacy.scopePosition.id)
                let storedItems = try pendingItems(libraryKey: legacy.libraryKey)
                let expectedItems = legacy.explicitDecisions.reduce(into: [String: ExplicitDecision]()) { $0[$1.assetID] = $1 }
                let actualItems = Dictionary(uniqueKeysWithValues: storedItems.map { ($0.assetID, $0) })
                let itemMatches = expectedItems.allSatisfy { assetID, expected in
                    guard let actual = actualItems[assetID] else { return false }
                    return actual.decision == expected.decision && actual.origin == .explicit && actual.scopeID == expected.scopeID && actual.groupID == expected.groupID
                }
                let groupMatches = storedGroups.count == legacy.groups.count && zip(storedGroups, legacy.groups).allSatisfy { pair in
                    pair.0.id == pair.1.id && pair.0.itemIDs == pair.1.itemIDs && pair.0.state == .unresolved
                }
                guard itemMatches, groupMatches, storedPosition == legacy.scopePosition else {
                    throw SQLiteReviewStoreError.migrationValidationFailed
                }
                try execute("UPDATE migration_receipts SET verified = 1 WHERE source_digest = ?") {
                    try self.bind(legacy.sourceDigest, at: 1, in: $0)
                }
                return true
            }
        }
    }

    public func isMigrationVerified(sourceDigest: String) throws -> Bool {
        try withLock {
            try queryOne(
                "SELECT verified FROM migration_receipts WHERE source_digest = ?",
                bind: { try self.bind(sourceDigest, at: 1, in: $0) },
                read: { sqlite3_column_int($0, 0) == 1 }
            ) ?? false
        }
    }

    private func createSchema() throws {
        try transaction {
            try execute("""
            CREATE TABLE pending_items(
                library_key TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                cloud_id TEXT,
                decision TEXT NOT NULL CHECK(decision IN ('keep','discard','edit')),
                origin TEXT NOT NULL CHECK(origin IN ('explicit','completedDefault')),
                revision INTEGER NOT NULL CHECK(revision > 0),
                scope_id TEXT,
                group_id TEXT,
                status TEXT NOT NULL CHECK(status IN ('pending','conflict','unavailable')),
                updated_at REAL NOT NULL,
                PRIMARY KEY(library_key, asset_id)
            )
            """)
            try execute("""
            CREATE TABLE review_scopes(
                scope_id TEXT PRIMARY KEY,
                payload TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
            try execute("""
            CREATE TABLE review_groups(
                group_id TEXT PRIMARY KEY,
                scope_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                payload TEXT NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('unresolved','completed','skipped'))
            )
            """)
            try execute("CREATE INDEX review_groups_scope_order ON review_groups(scope_id, position)")
            try execute("""
            CREATE TABLE commit_attempts(
                attempt_id TEXT PRIMARY KEY,
                library_key TEXT NOT NULL,
                started_at REAL NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('prepared','reconciled'))
            )
            """)
            try execute("""
            CREATE TABLE commit_items(
                attempt_id TEXT NOT NULL REFERENCES commit_attempts(attempt_id) ON DELETE CASCADE,
                library_key TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                cloud_id TEXT,
                decision TEXT NOT NULL,
                revision INTEGER NOT NULL,
                scope_id TEXT,
                group_id TEXT,
                outcome TEXT,
                PRIMARY KEY(attempt_id, asset_id)
            )
            """)
            try execute("""
            CREATE TABLE album_bindings(
                library_key TEXT NOT NULL,
                role TEXT NOT NULL,
                local_identifier TEXT NOT NULL,
                cloud_identifier TEXT,
                title TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY(library_key, role)
            )
            """)
            try execute("""
            CREATE TABLE migration_receipts(
                source_digest TEXT PRIMARY KEY,
                source_name TEXT NOT NULL,
                verified INTEGER NOT NULL CHECK(verified IN (0,1)),
                imported_at REAL NOT NULL
            )
            """)
            try execute("""
            CREATE TABLE review_revision_sequence(
                sequence_id INTEGER PRIMARY KEY CHECK(sequence_id = 1),
                last_revision INTEGER NOT NULL CHECK(last_revision >= 0)
            )
            """)
            try execute("INSERT INTO review_revision_sequence(sequence_id, last_revision) VALUES(1, 0)")
            try execute("PRAGMA user_version = 2")
        }
    }

    private func migrateToSchemaV2() throws {
        try transaction {
            try execute("""
            CREATE TABLE review_revision_sequence(
                sequence_id INTEGER PRIMARY KEY CHECK(sequence_id = 1),
                last_revision INTEGER NOT NULL CHECK(last_revision >= 0)
            )
            """)
            let maximumRevision = try queryOne(
                """
                SELECT COALESCE(MAX(revision), 0) FROM (
                    SELECT revision FROM pending_items
                    UNION ALL
                    SELECT revision FROM commit_items
                )
                """,
                bind: { _ in },
                read: { sqlite3_column_int64($0, 0) }
            ) ?? 0
            try execute("INSERT INTO review_revision_sequence(sequence_id, last_revision) VALUES(1, ?)") {
                sqlite3_bind_int64($0, 1, maximumRevision)
            }
            try execute("PRAGMA user_version = 2")
        }
    }

    private func nextRevision() throws -> Int64 {
        guard let current = try queryOne(
            "SELECT last_revision FROM review_revision_sequence WHERE sequence_id = 1",
            bind: { _ in },
            read: { sqlite3_column_int64($0, 0) }
        ) else {
            throw SQLiteReviewStoreError.sqlite(code: SQLITE_CORRUPT, message: "The review revision sequence is missing.")
        }
        guard current < Int64.max else {
            throw SQLiteReviewStoreError.sqlite(code: SQLITE_FULL, message: "The review revision sequence is exhausted.")
        }
        let next = current + 1
        try execute("UPDATE review_revision_sequence SET last_revision = ? WHERE sequence_id = 1") {
            sqlite3_bind_int64($0, 1, next)
        }
        guard let database, sqlite3_changes(database) == 1 else {
            throw SQLiteReviewStoreError.sqlite(code: SQLITE_CORRUPT, message: "The review revision sequence could not be advanced.")
        }
        return next
    }

    private func upsert(_ row: PendingReviewItem, insertOnly: Bool = false) throws {
        let conflictAction: String
        if insertOnly {
            conflictAction = "DO NOTHING"
        } else {
            conflictAction = """
            DO UPDATE SET cloud_id=excluded.cloud_id, decision=excluded.decision, origin=excluded.origin,
                revision=excluded.revision, scope_id=excluded.scope_id, group_id=excluded.group_id,
                status='pending', updated_at=excluded.updated_at
            """
        }
        try execute(
            """
            INSERT INTO pending_items(library_key, asset_id, cloud_id, decision, origin, revision, scope_id, group_id, status, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(library_key, asset_id) \(conflictAction)
            """
        ) { statement in
            try self.bind(row.libraryKey, at: 1, in: statement)
            try self.bind(row.assetID, at: 2, in: statement)
            try self.bind(row.cloudIdentifier, at: 3, in: statement)
            try self.bind(row.decision.rawValue, at: 4, in: statement)
            try self.bind(row.origin.rawValue, at: 5, in: statement)
            sqlite3_bind_int64(statement, 6, row.revision)
            try self.bind(row.scopeID, at: 7, in: statement)
            try self.bind(row.groupID, at: 8, in: statement)
            try self.bind(row.status.rawValue, at: 9, in: statement)
            sqlite3_bind_double(statement, 10, row.updatedAt.timeIntervalSince1970)
        }
    }

    private func commitItems(attemptID: String) throws -> [CommitItemIntent] {
        try queryMany(
            "SELECT library_key, asset_id, cloud_id, decision, revision, scope_id, group_id, outcome FROM commit_items WHERE attempt_id = ? ORDER BY asset_id",
            bind: { try self.bind(attemptID, at: 1, in: $0) },
            read: { statement in
                CommitItemIntent(
                    libraryKey: columnText(statement, 0),
                    assetID: columnText(statement, 1),
                    cloudIdentifier: columnOptionalText(statement, 2),
                    decision: ReviewDecision(rawValue: columnText(statement, 3)) ?? .discard,
                    revision: sqlite3_column_int64(statement, 4),
                    scopeID: columnOptionalText(statement, 5),
                    groupID: columnOptionalText(statement, 6),
                    outcome: columnOptionalText(statement, 7).flatMap(CommitItemOutcome.init(rawValue:))
                )
            }
        )
    }

    private func readPendingItem(_ statement: OpaquePointer) -> PendingReviewItem {
        PendingReviewItem(
            libraryKey: columnText(statement, 0),
            assetID: columnText(statement, 1),
            cloudIdentifier: columnOptionalText(statement, 2),
            decision: ReviewDecision(rawValue: columnText(statement, 3)) ?? .discard,
            origin: DecisionOrigin(rawValue: columnText(statement, 4)) ?? .explicit,
            revision: sqlite3_column_int64(statement, 5),
            scopeID: columnOptionalText(statement, 6),
            groupID: columnOptionalText(statement, 7),
            status: PendingItemStatus(rawValue: columnText(statement, 8)) ?? .pending,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
        )
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil) throws {
        guard let database else { throw SQLiteReviewStoreError.open("Database is closed.") }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else { throw currentError(code: prepareResult) }
        defer { sqlite3_finalize(statement) }
        try bind?(statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw currentError(code: result) }
    }

    private func queryOne<T>(_ sql: String, bind: (OpaquePointer) throws -> Void, read: (OpaquePointer) throws -> T) throws -> T? {
        guard let database else { throw SQLiteReviewStoreError.open("Database is closed.") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw currentError(code: result) }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw currentError(code: step) }
        return try read(statement)
    }

    private func queryMany<T>(_ sql: String, bind: (OpaquePointer) throws -> Void, read: (OpaquePointer) throws -> T) throws -> [T] {
        guard let database else { throw SQLiteReviewStoreError.open("Database is closed.") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw currentError(code: result) }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var values: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw currentError(code: step) }
            values.append(try read(statement))
        }
        return values
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try queryOne(sql, bind: { _ in }, read: { Int(sqlite3_column_int($0, 0)) }) ?? 0
    }

    private func currentError(code: Int32) -> SQLiteReviewStoreError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error."
        return .sqlite(code: code, message: message)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        guard result == SQLITE_OK else { throw currentError(code: result) }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            let result = sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else { throw currentError(code: result) }
            return
        }
        try self.bind(value, at: index, in: statement)
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, index)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(value.utf8))
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
