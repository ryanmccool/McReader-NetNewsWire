import CloudKit
import XCTest
@testable import CloudKitSync

final class CloudKitSyncTests: XCTestCase {
	func testMissingDatabaseErrorIsOperational() {
		XCTAssertEqual(
			CloudKitZoneError.databaseUnavailable.errorDescription,
			"The iCloud database is unavailable."
		)
	}

	func testZoneFetchStateRetainsZoneFailure() {
		let state = CloudKitZoneFetchCallbackState(savedChangeToken: nil)
		let error = CKError(.zoneBusy)

		state.setRecordZoneResult(.failure(error))

		XCTAssertEqual((state.snapshot().recordZoneError as? CKError)?.code, .zoneBusy)
	}

	func testZoneFetchStateRetainsRecordFailure() {
		let state = CloudKitZoneFetchCallbackState(savedChangeToken: nil)
		let error = CKError(.serverRecordChanged)

		state.setRecordError(error)

		XCTAssertEqual((state.snapshot().recordError as? CKError)?.code, .serverRecordChanged)
	}

	func testZoneDeletionTreatsOnlyMissingZoneAsSuccess() {
		XCTAssertTrue(CloudKitZoneDeletion.isMissingZoneError(CKError(.zoneNotFound)))
		XCTAssertFalse(CloudKitZoneDeletion.isMissingZoneError(CKError(.zoneBusy)))

		let zoneID = CKRecordZone.ID(zoneName: "Account")
		let missingPartial = CKError(.partialFailure, userInfo: [
			CKPartialErrorsByItemIDKey: [zoneID: CKError(.zoneNotFound)]
		])
		XCTAssertTrue(CloudKitZoneDeletion.isMissingZoneError(missingPartial))

		let mixedPartial = CKError(.partialFailure, userInfo: [
			CKPartialErrorsByItemIDKey: [
				zoneID: CKError(.zoneNotFound),
				CKRecordZone.ID(zoneName: "Articles"): CKError(.zoneBusy)
			]
		])
		XCTAssertFalse(CloudKitZoneDeletion.isMissingZoneError(mixedPartial))
	}

	func testTargetTransientPartialFailureReturnsRetryDelay() {
		let targetID = CKRecord.ID(recordName: "target")
		for code in [CKError.Code.requestRateLimited, .zoneBusy, .networkFailure] {
			let itemError = CKError(code, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 1.5)])
			let partialError = CKError(.partialFailure, userInfo: [
				CKPartialErrorsByItemIDKey: [targetID: itemError]
			])

			XCTAssertEqual(
				CloudKitZoneResult.targetTransientPartialFailureRetryDelay(partialError, targetRecordID: targetID),
				1.5,
				"Expected \(code) to be retried"
			)
		}
	}

	func testTargetTransientPartialFailureRejectsUnrelatedMixedAndPermanentErrors() {
		let targetID = CKRecord.ID(recordName: "target")
		let unrelatedID = CKRecord.ID(recordName: "unrelated")
		let unrelated = CKError(.partialFailure, userInfo: [
			CKPartialErrorsByItemIDKey: [unrelatedID: CKError(.networkFailure)]
		])
		let mixed = CKError(.partialFailure, userInfo: [
			CKPartialErrorsByItemIDKey: [
				targetID: CKError(.networkFailure),
				unrelatedID: CKError(.zoneBusy)
			]
		])
		let permanent = CKError(.partialFailure, userInfo: [
			CKPartialErrorsByItemIDKey: [targetID: CKError(.permissionFailure)]
		])

		XCTAssertNil(CloudKitZoneResult.targetTransientPartialFailureRetryDelay(unrelated, targetRecordID: targetID))
		XCTAssertNil(CloudKitZoneResult.targetTransientPartialFailureRetryDelay(mixed, targetRecordID: targetID))
		XCTAssertNil(CloudKitZoneResult.targetTransientPartialFailureRetryDelay(permanent, targetRecordID: targetID))
	}
}
