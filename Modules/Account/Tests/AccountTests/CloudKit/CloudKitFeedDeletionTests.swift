//
//  CloudKitFeedDeletionTests.swift
//  AccountTests
//

import CloudKit
import XCTest
import CloudKitSync
@testable import Account

@MainActor final class CloudKitFeedDeletionTests: XCTestCase {

	private let zoneID = CKRecordZone.ID(zoneName: "Account", ownerName: CKCurrentUserDefaultName)

	func testMembershipOnlyRemovalSkipsFinalCleanup() async throws {
		var deletedArticleFeedIDs = [String]()
		var clearedSettings = false

		try await CloudKitAccountDelegate.completeFeedDeletion(
			deletedFinalRecord: false,
			feedExternalID: "feed-id",
			deleteArticles: { deletedArticleFeedIDs.append($0) },
			clearSettings: { clearedSettings = true }
		)

		XCTAssertTrue(deletedArticleFeedIDs.isEmpty)
		XCTAssertFalse(clearedSettings)
	}

	func testMembershipSaveUnknownItemPropagatesWithoutFinalCleanup() async {
		let feedExternalID = "feed-id"
		let record = CKRecord(
			recordType: CloudKitAccountZone.CloudKitFeed.recordType,
			recordID: recordID(feedExternalID)
		)
		record[CloudKitAccountZone.CloudKitFeed.Fields.containerExternalIDs] = ["source", "other"]
		var cleanupRequested = false

		do {
			let deletedFinalRecord = try await CloudKitAccountZone.removeFeed(
				fromContainerExternalID: "source",
				feedExternalID: feedExternalID,
				zoneID: zoneID,
				fetch: { _ in record },
				save: { _ in throw CloudKitError(CKError(.unknownItem)) },
				delete: { _ in XCTFail("Membership-only removal must not delete the feed record") }
			)
			try await CloudKitAccountDelegate.completeFeedDeletion(
				deletedFinalRecord: deletedFinalRecord,
				feedExternalID: feedExternalID,
				deleteArticles: { _ in cleanupRequested = true },
				clearSettings: { cleanupRequested = true }
			)
			XCTFail("Expected membership save to fail")
		} catch {
			let underlyingError = (error as? CloudKitError)?.error as? CKError
			XCTAssertEqual(underlyingError?.code, .unknownItem)
			XCTAssertFalse(cleanupRequested)
		}
	}

	func testFinalRemovalDeletesArticlesAndClearsSettings() async throws {
		var deletedArticleFeedIDs = [String]()
		var clearedSettings = false

		try await CloudKitAccountDelegate.completeFeedDeletion(
			deletedFinalRecord: true,
			feedExternalID: "feed-id",
			deleteArticles: { deletedArticleFeedIDs.append($0) },
			clearSettings: { clearedSettings = true }
		)

		XCTAssertEqual(deletedArticleFeedIDs, ["feed-id"])
		XCTAssertTrue(clearedSettings)
	}

	func testCleanupFailureReportsCommittedFeedDeletion() async {
		do {
			try await CloudKitAccountDelegate.completeFeedDeletion(
				deletedFinalRecord: true,
				feedExternalID: "feed-id",
				deleteArticles: { _ in throw TestError.expected },
				clearSettings: { XCTFail("Settings must not clear after failed article cleanup") }
			)
			XCTFail("Expected cleanup to fail")
		} catch {
			XCTAssertEqual(error as? CloudKitAccountDelegateError, .feedDeletedCleanupFailed)
		}
	}

	func testCommittedCleanupFailureDoesNotRequestFeedRestoration() {
		XCTAssertFalse(CloudKitAccountDelegate.feedRemovalNeedsRestore(after: CloudKitAccountDelegateError.feedDeletedCleanupFailed))
		XCTAssertTrue(CloudKitAccountDelegate.feedRemovalNeedsRestore(after: TestError.expected))
	}

	func testDirectUnknownItemSatisfiesAbsence() {
		let error = CloudKitError(CKError(.unknownItem))

		XCTAssertTrue(CloudKitAbsenceResult.isSatisfied(error: error, targetRecordIDs: [recordID("feed")]))
	}

	func testTargetOnlyPartialUnknownItemsSatisfyAbsence() {
		let first = recordID("first")
		let second = recordID("second")
		let error = partialFailure([first: CKError(.unknownItem), second: CKError(.unknownItem)])

		XCTAssertTrue(CloudKitAbsenceResult.isSatisfied(error: error, targetRecordIDs: [first, second]))
	}

	func testMixedPartialFailureDoesNotSatisfyAbsence() {
		let first = recordID("first")
		let second = recordID("second")
		let error = partialFailure([first: CKError(.unknownItem), second: CKError(.networkFailure)])

		XCTAssertFalse(CloudKitAbsenceResult.isSatisfied(error: error, targetRecordIDs: [first, second]))
	}

	func testPartialFailureForNonTargetDoesNotSatisfyAbsence() {
		let target = recordID("target")
		let error = partialFailure([recordID("other"): CKError(.unknownItem)])

		XCTAssertFalse(CloudKitAbsenceResult.isSatisfied(error: error, targetRecordIDs: [target]))
	}

	func testDeleteSettingsWaitsUntilURLRowIsGone() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let database = FeedSettingsDatabase(databasePath: directory.appendingPathComponent("FeedSettings.db").path)
		let feedURL = "https://example.com/feed"
		database.ensureFeedExists(feedURL, feedID: "feed-id")

		await database.deleteSettings(for: feedURL)

		XCTAssertNil(database.allRows()[feedURL])
	}

	private func recordID(_ name: String) -> CKRecord.ID {
		CKRecord.ID(recordName: name, zoneID: zoneID)
	}

	private func partialFailure(_ errors: [CKRecord.ID: CKError]) -> CloudKitError {
		CloudKitError(CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors]))
	}

	private enum TestError: Error {
		case expected
	}
}
