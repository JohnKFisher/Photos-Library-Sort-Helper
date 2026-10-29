import CSQLite
import Foundation
import PhotosSortCore
import XCTest

final class TemporalGroupingCoreTests: XCTestCase {
    func testInclusiveAdjacentBoundaryAndTransitiveChain() {
        let origin = Date(timeIntervalSince1970: 10_000)
        let items = [0.0, 8.0, 16.0].enumerated().map { index, offset in
            ReviewMediaMetadata(id: "p\(index)", preferredDate: origin.addingTimeInterval(offset), isVideo: false)
        }

        let groups = TemporalGrouping.groups(from: items, maxGapSeconds: 8)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].itemIDs, ["p0", "p1", "p2"])
    }

    func testGapGreaterThanBoundaryStartsNewGroup() {
        let origin = Date(timeIntervalSince1970: 10_000)
        let items = [0.0, 8.0001].enumerated().map { index, offset in
            ReviewMediaMetadata(id: "p\(index)", preferredDate: origin.addingTimeInterval(offset), isVideo: false)
        }

        XCTAssertEqual(TemporalGrouping.groups(from: items, maxGapSeconds: 8).map(\.itemIDs), [["p0"], ["p1"]])
    }

    func testUnknownDatesAreStableSingletons() {
        let origin = Date(timeIntervalSince1970: 10_000)
        let items = [
            ReviewMediaMetadata(id: "b", preferredDate: nil, isVideo: false),
            ReviewMediaMetadata(id: "a", preferredDate: nil, isVideo: false),
            ReviewMediaMetadata(id: "dated", preferredDate: origin, isVideo: false)
        ]

        let groups = TemporalGrouping.groups(from: items, maxGapSeconds: 30)

        XCTAssertEqual(groups.map(\.itemIDs), [["a"], ["b"], ["dated"]])
        XCTAssertEqual(groups.map(\.id).count, Set(groups.map(\.id)).count)
    }

    func testVideosAreSingletonsAndLivePhotosRemainInImageGroup() {
        let origin = Date(timeIntervalSince1970: 10_000)
        let items = [
            ReviewMediaMetadata(id: "image-a", preferredDate: origin, isVideo: false),
            ReviewMediaMetadata(id: "video", preferredDate: origin.addingTimeInterval(2), isVideo: true),
            ReviewMediaMetadata(id: "live", preferredDate: origin.addingTimeInterval(4), isVideo: false, isLivePhoto: true),
            ReviewMediaMetadata(id: "image-b", preferredDate: origin.addingTimeInterval(6), isVideo: false)
        ]

        let groups = TemporalGrouping.groups(from: items, maxGapSeconds: 8)

        XCTAssertEqual(groups.map(\.itemIDs), [["image-a", "live", "image-b"], ["video"]])
    }

    func testEqualDatesUseStableIdentifierOrderAndFingerprintTracksSettings() {
        let date = Date(timeIntervalSince1970: 10_000)
        let items = [
            ReviewMediaMetadata(id: "z", preferredDate: date, isVideo: false),
            ReviewMediaMetadata(id: "a", preferredDate: date, isVideo: false)
        ]
        let first = TemporalGrouping.groups(from: items, maxGapSeconds: 5)
        let second = TemporalGrouping.groups(from: Array(items.reversed()), maxGapSeconds: 5)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(TemporalGrouping.fingerprint(maxGapSeconds: 5), TemporalGrouping.fingerprint(maxGapSeconds: 6))
    }

    func testStableGroupIdentityIncludesScope() {
        let date = Date(timeIntervalSince1970: 10_000)
        let items = [ReviewMediaMetadata(id: "photo", preferredDate: date, isVideo: false)]
        let first = TemporalGrouping.groups(from: items, maxGapSeconds: 5, scopeID: "all-photos")
        let repeated = TemporalGrouping.groups(from: items, maxGapSeconds: 5, scopeID: "all-photos")
        let otherScope = TemporalGrouping.groups(from: items, maxGapSeconds: 5, scopeID: "album-photos")

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first.first?.id, otherScope.first?.id)
    }
}

final class PhotoDateRangeTests: XCTestCase {
    func testDateRangeIncludesWholeBoundaryDaysAndFractionalEndTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let from = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 18)))
        let through = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 1)))
        let range = PhotoDateRange(from: from, through: through, calendar: calendar)
        let firstMoment = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
        let lastMoment = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 23, minute: 59, second: 59)))
        let afterLastDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 13)))

        XCTAssertTrue(range.contains(firstMoment))
        XCTAssertTrue(range.contains(lastMoment.addingTimeInterval(0.75)))
        XCTAssertFalse(range.contains(afterLastDay))
        XCTAssertEqual(range.endExclusive, afterLastDay)
    }

    func testReversedRangeNormalizesAndCalendarDayAdditionHandlesDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 14)))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9)))
        let range = PhotoDateRange(from: later, through: earlier, calendar: calendar)
        let nextDayStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))

        XCTAssertEqual(range.startInclusive, calendar.startOfDay(for: earlier))
        XCTAssertEqual(range.endExclusive, nextDayStart)
        XCTAssertEqual(range.endExclusive.timeIntervalSince(range.startInclusive), 47 * 60 * 60)
    }
}

final class ReviewFrontierPositionTests: XCTestCase {
    func testNewEligibleGroupIsVisibleAfterACompletedScopeEvenWhenTheFrontierShrinks() {
        let oldIDs = Set(["old-1", "old-2", "old-3", "old-4"])

        let position = ReviewFrontierPosition.resolve(
            groupIDs: ["new-backdated-group"],
            itemIDsByGroup: [["new-photo"]],
            previouslyKnownGroupIDs: oldIDs,
            currentGroupID: nil,
            currentItemID: nil,
            fallbackGroupIndex: 4
        )

        XCTAssertEqual(position, 0)
    }

    func testCompletedScopeStaysAtTheEndWhenNoNewGroupsAppear() {
        let IDs = ["group-1", "group-2", "group-3", "group-4"]

        let position = ReviewFrontierPosition.resolve(
            groupIDs: IDs,
            itemIDsByGroup: [[], [], [], []],
            previouslyKnownGroupIDs: Set(IDs),
            currentGroupID: nil,
            currentItemID: nil,
            fallbackGroupIndex: 4
        )

        XCTAssertEqual(position, IDs.count)
    }

    func testPreviouslyCompletedGroupReturnsToFrontWhenItsAlbumMembershipIsRemoved() {
        let position = ReviewFrontierPosition.resolve(
            groupIDs: ["completed-group"],
            itemIDsByGroup: [["same-photo-a", "same-photo-b"]],
            previouslyKnownGroupIDs: ["completed-group"],
            previouslyCompletedGroupIDs: ["completed-group"],
            currentGroupID: nil,
            currentItemID: nil,
            fallbackGroupIndex: 4
        )

        XCTAssertEqual(position, 0)
    }

    func testCurrentPhotoAndGroupIdentityTakePrecedenceOverFallback() {
        let position = ReviewFrontierPosition.resolve(
            groupIDs: ["group-a", "group-b"],
            itemIDsByGroup: [["a1", "a2"], ["b1"]],
            previouslyKnownGroupIDs: ["group-a", "group-b"],
            currentGroupID: "group-a",
            currentItemID: "b1",
            fallbackGroupIndex: 0
        )

        XCTAssertEqual(position, 1)
    }
}

final class PhotoCommitReconciliationTests: XCTestCase {
    func testEachDecisionMapsToItsDestinationAndVerifiesOnlyExpectedMembership() {
        let destinations: [(ReviewDecision, DestinationRole)] = [
            (.keep, .fullySorted),
            (.discard, .manualDelete),
            (.edit, .edit)
        ]

        for (decision, destination) in destinations {
            XCTAssertEqual(PhotoCommitReconciliation.destination(for: decision), destination)
            XCTAssertEqual(
                PhotoCommitReconciliation.outcome(for: decision, memberships: [destination], assetAvailable: true),
                .verifiedCommitted
            )
            XCTAssertEqual(
                PhotoCommitReconciliation.outcome(for: decision, memberships: [], assetAvailable: true),
                .retryable
            )
            XCTAssertEqual(
                PhotoCommitReconciliation.outcome(for: decision, memberships: [], assetAvailable: false),
                .unavailable
            )
        }
    }

    func testWrongOrMultipleDestinationMembershipIsAConflict() {
        XCTAssertEqual(
            PhotoCommitReconciliation.outcome(for: .keep, memberships: [.edit], assetAvailable: true),
            .conflict
        )
        XCTAssertEqual(
            PhotoCommitReconciliation.outcome(for: .discard, memberships: [.manualDelete, .fullySorted], assetAvailable: true),
            .conflict
        )
    }
}

final class SQLiteReviewStoreTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var store: SQLiteReviewStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        databaseURL = directory.appendingPathComponent("review-state.sqlite")
        store = try SQLiteReviewStore(url: databaseURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testGroupCompletionFreezesOnlyUntouchedItemsAndPositionAtomically() throws {
        let group = makeGroup(scope: "scope-a", items: ["a", "b", "c"])
        try store.setExplicitDecision(libraryKey: "library", assetID: "a", decision: .edit, scopeID: group.scopeID, groupID: group.id)
        let next = ScopePosition(id: group.scopeID, currentGroupID: "next", currentItemID: "d", fallbackGroupIndex: 1, groupingFingerprint: group.groupingFingerprint)

        try store.completeGroup(group, defaultDecision: .discard, libraryKey: "library", nextPosition: next)

        let rows = try store.pendingItems(libraryKey: "library")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first(where: { $0.assetID == "a" })?.decision, .edit)
        XCTAssertEqual(rows.first(where: { $0.assetID == "a" })?.origin, .explicit)
        XCTAssertEqual(rows.first(where: { $0.assetID == "b" })?.decision, .discard)
        XCTAssertEqual(rows.first(where: { $0.assetID == "b" })?.origin, .completedDefault)
        XCTAssertEqual(try store.groups(scopeID: group.scopeID).first?.state, .completed)
        XCTAssertEqual(try store.position(scopeID: group.scopeID), next)
    }

    func testSkipPersistsProgressWithoutCreatingDefaultQueueEntries() throws {
        let group = makeGroup(scope: "scope-a", items: ["explicit", "untouched"])
        try store.setExplicitDecision(libraryKey: "library", assetID: "explicit", decision: .keep, scopeID: group.scopeID, groupID: group.id)
        let next = ScopePosition(id: group.scopeID, currentGroupID: "next", currentItemID: nil, fallbackGroupIndex: 1, groupingFingerprint: group.groupingFingerprint)

        try store.skipGroup(group, nextPosition: next)

        XCTAssertEqual(try store.queuedAssetIDs(libraryKey: "library"), Set(["explicit"]))
        XCTAssertEqual(try store.groups(scopeID: group.scopeID).first?.state, .skipped)
        XCTAssertEqual(try store.position(scopeID: group.scopeID), next)
    }

    func testReopenRetainsQueueGroupsAndPosition() throws {
        let group = makeGroup(scope: "scope-a", items: ["a"])
        let next = ScopePosition(id: group.scopeID, currentGroupID: group.id, currentItemID: "a", fallbackGroupIndex: 0, groupingFingerprint: group.groupingFingerprint)
        try store.completeGroup(group, defaultDecision: .keep, libraryKey: "library", nextPosition: next)
        store = nil

        store = try SQLiteReviewStore(url: databaseURL)

        XCTAssertEqual(try store.pendingItem(libraryKey: "library", assetID: "a")?.decision, .keep)
        XCTAssertEqual(try store.groups(scopeID: group.scopeID), [groupWithState(group, .completed)])
        XCTAssertEqual(try store.position(scopeID: group.scopeID), next)
    }

    func testUnsupportedSchemaIsRejectedWithoutChangingDatabaseContents() throws {
        store = nil
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "CREATE TABLE preserved(value TEXT); INSERT INTO preserved VALUES('keep'); PRAGMA user_version = 99;", nil, nil, nil),
            SQLITE_OK
        )

        XCTAssertThrowsError(try SQLiteReviewStore(url: databaseURL)) { error in
            XCTAssertEqual(error as? SQLiteReviewStoreError, .unsupportedSchema(99))
        }

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT value FROM preserved", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "keep")
    }

    func testRepeatedExplicitEditIncrementsRevisionAndReplacesDecision() throws {
        let group = makeGroup(scope: "scope-a", items: ["a"])
        let first = try store.setExplicitDecision(libraryKey: "library", assetID: "a", decision: .keep, scopeID: group.scopeID, groupID: group.id)
        let second = try store.setExplicitDecision(libraryKey: "library", assetID: "a", decision: .edit, scopeID: group.scopeID, groupID: group.id)

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.decision, .edit)
        XCTAssertEqual(second.origin, .explicit)
    }

    func testReplayingReconciledCommitCannotDeleteRestagedChoice() throws {
        let original = try store.setExplicitDecision(
            libraryKey: "library",
            assetID: "asset",
            decision: .keep,
            scopeID: "scope",
            groupID: "group"
        )
        let attempt = try store.beginCommit(libraryKey: "library", attemptID: "replay-safe")

        try store.reconcile(attemptID: attempt.id, outcomes: ["asset": .verifiedCommitted])
        XCTAssertNil(try store.pendingItem(libraryKey: "library", assetID: "asset"))
        let restaged = try store.setExplicitDecision(
            libraryKey: "library",
            assetID: "asset",
            decision: .discard,
            scopeID: "scope",
            groupID: "group"
        )
        XCTAssertGreaterThan(restaged.revision, original.revision)

        try store.reconcile(attemptID: attempt.id, outcomes: ["asset": .verifiedCommitted])

        XCTAssertEqual(try store.pendingItem(libraryKey: "library", assetID: "asset")?.decision, .discard)
    }

    func testObservedMembershipThenInterruptedCommitPreservesNewRevision() throws {
        let original = try store.setExplicitDecision(
            libraryKey: "library",
            assetID: "asset",
            decision: .keep,
            scopeID: "scope",
            groupID: "group"
        )
        let attempt = try store.beginCommit(libraryKey: "library", attemptID: "observed-before-reconcile")
        try store.reconcileObservedMembership(
            libraryKey: "library",
            assetID: "asset",
            revision: original.revision,
            outcome: .verifiedCommitted
        )
        let restaged = try store.setExplicitDecision(
            libraryKey: "library",
            assetID: "asset",
            decision: .edit,
            scopeID: "scope",
            groupID: "group"
        )

        try store.reconcile(attemptID: attempt.id, outcomes: ["asset": .verifiedCommitted])

        let current = try XCTUnwrap(store.pendingItem(libraryKey: "library", assetID: "asset"))
        XCTAssertGreaterThan(restaged.revision, original.revision)
        XCTAssertEqual(current.decision, .edit)
        XCTAssertEqual(current.status, .conflict)
    }

    func testSchemaV1UpgradeSeedsRevisionSequenceFromPendingAndJournalRows() throws {
        let initial = try store.setExplicitDecision(
            libraryKey: "library",
            assetID: "asset",
            decision: .keep,
            scopeID: "scope",
            groupID: "group"
        )
        let attempt = try store.beginCommit(libraryKey: "library", attemptID: "schema-upgrade")
        XCTAssertEqual(attempt.items.first?.revision, initial.revision)
        store = nil

        var database: OpaquePointer?
        XCTAssertEqual(databaseURL.path.withCString { sqlite3_open($0, &database) }, SQLITE_OK)
        let handle = try XCTUnwrap(database)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "UPDATE pending_items SET revision = 17 WHERE asset_id = 'asset'; UPDATE commit_items SET revision = 29 WHERE attempt_id = 'schema-upgrade'; DROP TABLE review_revision_sequence; PRAGMA user_version = 1;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
        database = nil

        store = try SQLiteReviewStore(url: databaseURL)
        let upgraded = try store.setExplicitDecision(
            libraryKey: "library",
            assetID: "asset",
            decision: .discard,
            scopeID: "scope",
            groupID: "group"
        )

        XCTAssertEqual(SQLiteReviewStore.currentSchemaVersion, 2)
        XCTAssertGreaterThan(upgraded.revision, 29)
        XCTAssertEqual(try store.pendingItem(libraryKey: "library", assetID: "asset")?.decision, .discard)
    }

    func testFailedLegacyVerificationRollsBackImportedGroupsPositionAndRows() throws {
        let existing = try store.setExplicitDecision(
            libraryKey: "library",
            assetID: "conflicting-asset",
            decision: .discard,
            scopeID: "newer-scope",
            groupID: "newer-group"
        )
        let importedGroup = makeGroup(scope: "legacy-scope", items: ["conflicting-asset"])
        let preexistingGroup = groupWithState(importedGroup, .completed)
        let preexistingPosition = ScopePosition(
            id: importedGroup.scopeID,
            currentGroupID: "newer-group-position",
            currentItemID: "newer-item-position",
            fallbackGroupIndex: 4,
            groupingFingerprint: "newer-position"
        )
        try store.save(group: preexistingGroup)
        try store.save(position: preexistingPosition)
        let migration = LegacyReviewImport(
            sourceDigest: "sha256:conflicting-import",
            libraryKey: "library",
            scopePosition: ScopePosition(
                id: importedGroup.scopeID,
                currentGroupID: importedGroup.id,
                currentItemID: importedGroup.itemIDs.first,
                fallbackGroupIndex: 0,
                groupingFingerprint: importedGroup.groupingFingerprint
            ),
            groups: [importedGroup],
            explicitDecisions: [ExplicitDecision(
                assetID: "conflicting-asset",
                cloudIdentifier: nil,
                decision: .keep,
                scopeID: importedGroup.scopeID,
                groupID: importedGroup.id
            )]
        )

        XCTAssertThrowsError(try store.importLegacy(migration)) {
            XCTAssertEqual($0 as? SQLiteReviewStoreError, .migrationValidationFailed)
        }

        XCTAssertEqual(try store.groups(scopeID: importedGroup.scopeID), [preexistingGroup])
        XCTAssertEqual(try store.position(scopeID: importedGroup.scopeID), preexistingPosition)
        XCTAssertFalse(try store.isMigrationVerified(sourceDigest: migration.sourceDigest))
        let unchanged = try XCTUnwrap(store.pendingItem(libraryKey: "library", assetID: "conflicting-asset"))
        XCTAssertEqual(unchanged.decision, .discard)
        XCTAssertEqual(unchanged.revision, existing.revision)
    }

    func testCommitJournalDeletesOnlyTheExactRevisionItCommitted() throws {
        let group = makeGroup(scope: "scope-a", items: ["a"])
        try store.setExplicitDecision(libraryKey: "library", assetID: "a", decision: .keep, scopeID: group.scopeID, groupID: group.id)
        let attempt = try store.beginCommit(libraryKey: "library", attemptID: "attempt-a")
        XCTAssertEqual(attempt.items.first?.decision, .keep)

        try store.setExplicitDecision(libraryKey: "library", assetID: "a", decision: .discard, scopeID: group.scopeID, groupID: group.id)
        try store.reconcile(attemptID: attempt.id, outcomes: ["a": .verifiedCommitted])

        let row = try XCTUnwrap(store.pendingItem(libraryKey: "library", assetID: "a"))
        XCTAssertEqual(row.decision, .discard)
        XCTAssertEqual(row.revision, 2)
        XCTAssertEqual(row.status, .conflict)
        XCTAssertEqual(try store.commitAttemptsNeedingRecovery().count, 0)
    }

    func testVerifiedCommitClearsOnlyItsMatchingQueueRow() throws {
        let group = makeGroup(scope: "scope-a", items: ["a"])
        try store.setExplicitDecision(libraryKey: "library", assetID: "a", decision: .edit, scopeID: group.scopeID, groupID: group.id)
        let attempt = try store.beginCommit(libraryKey: "library")

        try store.reconcile(attemptID: attempt.id, outcomes: ["a": .verifiedCommitted])

        XCTAssertTrue(try store.pendingItems(libraryKey: "library").isEmpty)
        XCTAssertTrue(try store.commitAttemptsNeedingRecovery().isEmpty)
    }

    func testInterruptedCommitRemainsDiscoverableAndGroupHistoryCanBePruned() throws {
        let group = ReviewGroupSnapshot(
            id: "group-a",
            scopeID: "scope-a",
            position: 0,
            itemIDs: ["a", "b"],
            startDate: nil,
            endDate: nil,
            groupingFingerprint: "grouping-v1",
            state: .completed
        )
        try store.save(group: group)
        try store.setExplicitDecision(libraryKey: "library", assetID: "a", decision: .keep, scopeID: group.scopeID, groupID: group.id)
        let attempt = try store.beginCommit(libraryKey: "library")

        XCTAssertEqual(try store.commitAttemptsNeedingRecovery().map(\.id), [attempt.id])
        try store.removeItemsFromGroups(scopeID: group.scopeID, assetIDs: ["a"])

        let saved = try XCTUnwrap(store.groups(scopeID: group.scopeID).first)
        XCTAssertEqual(saved.itemIDs, ["b"])
        XCTAssertEqual(saved.state, .completed)
        XCTAssertEqual(try store.commitAttemptsNeedingRecovery().map(\.id), [attempt.id])
    }

    func testInterruptedCommitRecoversVerifiedConflictRetryableAndUnavailableMemberships() throws {
        let decisions: [(String, ReviewDecision)] = [
            ("verified", .keep),
            ("conflict", .discard),
            ("retryable", .edit),
            ("unavailable", .keep)
        ]
        for (assetID, decision) in decisions {
            try store.setExplicitDecision(
                libraryKey: "library",
                assetID: assetID,
                decision: decision,
                scopeID: "scope",
                groupID: "group"
            )
        }
        let attempt = try store.beginCommit(libraryKey: "library", attemptID: "interrupted")
        store = nil
        store = try SQLiteReviewStore(url: databaseURL)

        // Fake PhotoKit membership after interruption: one success, one opposing
        // destination, one not-yet-applied add, and one missing asset.
        let observedMembership: [String: Set<DestinationRole>] = [
            "verified": [.fullySorted],
            "conflict": [.edit],
            "retryable": [],
            "unavailable": []
        ]
        let availableAssets: Set<String> = ["verified", "conflict", "retryable"]
        let outcomes = Dictionary(uniqueKeysWithValues: attempt.items.map { item in
            (
                item.assetID,
                PhotoCommitReconciliation.outcome(
                    for: item.decision,
                    memberships: observedMembership[item.assetID] ?? [],
                    assetAvailable: availableAssets.contains(item.assetID)
                )
            )
        })

        try store.reconcile(attemptID: attempt.id, outcomes: outcomes)

        XCTAssertNil(try store.pendingItem(libraryKey: "library", assetID: "verified"))
        XCTAssertEqual(try store.pendingItem(libraryKey: "library", assetID: "conflict")?.status, .conflict)
        XCTAssertEqual(try store.pendingItem(libraryKey: "library", assetID: "retryable")?.status, .pending)
        XCTAssertEqual(try store.pendingItem(libraryKey: "library", assetID: "unavailable")?.status, .unavailable)
        XCTAssertTrue(try store.commitAttemptsNeedingRecovery().isEmpty)
    }

    func testMigrationPreservesExplicitWorkButDoesNotPromoteDisplayedLegacyGroupToCompleted() throws {
        let group = ReviewGroupSnapshot(
            id: "old-group",
            scopeID: "legacy-scope",
            position: 0,
            itemIDs: ["kept", "untouched"],
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 101),
            groupingFingerprint: "legacy",
            state: .completed
        )
        let position = ScopePosition(id: "legacy-scope", currentGroupID: group.id, currentItemID: "kept", fallbackGroupIndex: 0, groupingFingerprint: "legacy")
        let migration = LegacyReviewImport(
            sourceDigest: "sha256:source-a",
            libraryKey: "library",
            scopePosition: position,
            groups: [group],
            explicitDecisions: [ExplicitDecision(assetID: "kept", cloudIdentifier: nil, decision: .keep, scopeID: "legacy-scope", groupID: group.id)]
        )

        XCTAssertTrue(try store.importLegacy(migration))
        XCTAssertFalse(try store.importLegacy(migration))
        XCTAssertEqual(try store.groups(scopeID: "legacy-scope").first?.state, .unresolved)
        XCTAssertEqual(try store.pendingItems(libraryKey: "library").map(\.assetID), ["kept"])
        XCTAssertEqual(try store.pendingItem(libraryKey: "library", assetID: "kept")?.origin, .explicit)
        XCTAssertTrue(try store.isMigrationVerified(sourceDigest: "sha256:source-a"))
    }

    func testLegacyImportRetainsExplicitChoiceForCurrentlyUnavailableAsset() throws {
        let group = makeGroup(scope: "legacy-scope", items: ["asset-unavailable-during-import"])
        let migration = LegacyReviewImport(
            sourceDigest: "sha256:unavailable-asset",
            libraryKey: "library",
            scopePosition: ScopePosition(
                id: group.scopeID,
                currentGroupID: group.id,
                currentItemID: group.itemIDs.first,
                fallbackGroupIndex: 0,
                groupingFingerprint: group.groupingFingerprint
            ),
            groups: [group],
            explicitDecisions: [ExplicitDecision(
                assetID: "asset-unavailable-during-import",
                cloudIdentifier: nil,
                decision: .discard,
                scopeID: group.scopeID,
                groupID: group.id
            )]
        )

        XCTAssertTrue(try store.importLegacy(migration))
        XCTAssertEqual(
            try store.pendingItem(libraryKey: "library", assetID: "asset-unavailable-during-import")?.decision,
            .discard
        )
        XCTAssertTrue(try store.isMigrationVerified(sourceDigest: migration.sourceDigest))
    }

    func testAlbumBindingsPersistByRoleAndLibrary() throws {
        let binding = DestinationAlbumBinding(libraryKey: "library", role: .edit, localIdentifier: "album-id", cloudIdentifier: "cloud-id", title: "Edits")
        try store.bindAlbum(binding)
        store = nil
        store = try SQLiteReviewStore(url: databaseURL)

        let restored = try XCTUnwrap(store.albumBindings(libraryKey: "library").first)
        XCTAssertEqual(restored.libraryKey, binding.libraryKey)
        XCTAssertEqual(restored.role, binding.role)
        XCTAssertEqual(restored.localIdentifier, binding.localIdentifier)
        XCTAssertEqual(restored.cloudIdentifier, binding.cloudIdentifier)
        XCTAssertEqual(restored.title, binding.title)
        XCTAssertLessThan(abs(restored.updatedAt.timeIntervalSince(binding.updatedAt)), 0.001)
    }

    private func makeGroup(scope: String, items: [String]) -> ReviewGroupSnapshot {
        ReviewGroupSnapshot(id: "group-\(scope)", scopeID: scope, position: 0, itemIDs: items, startDate: nil, endDate: nil, groupingFingerprint: "grouping-v1")
    }

    private func groupWithState(_ group: ReviewGroupSnapshot, _ state: SavedGroupState) -> ReviewGroupSnapshot {
        ReviewGroupSnapshot(id: group.id, scopeID: group.scopeID, position: group.position, itemIDs: group.itemIDs, startDate: group.startDate, endDate: group.endDate, groupingFingerprint: group.groupingFingerprint, state: state)
    }
}
