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
}
