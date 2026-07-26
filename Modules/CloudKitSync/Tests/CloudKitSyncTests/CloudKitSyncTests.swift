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
}
