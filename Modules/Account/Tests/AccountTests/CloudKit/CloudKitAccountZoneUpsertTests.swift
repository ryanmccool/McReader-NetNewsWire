//
//  CloudKitAccountZoneUpsertTests.swift
//  AccountTests
//

import CloudKit
import XCTest
import RSCore
import CloudKitSync
@testable import Account

@MainActor final class CloudKitAccountZoneUpsertTests: XCTestCase {

	private let zoneID = CKRecordZone.ID(zoneName: "Account", ownerName: CKCurrentUserDefaultName)

	func testNewFeedUsesExactURLMD5RecordID() async throws {
		let urlString = "https://EXAMPLE.com/feed/"
		var savedRecord: CKRecord?
		var unchangedSaveCount = 0

		let result = try await CloudKitAccountZone.upsertFeed(
			urlString: urlString,
			name: nil,
			editedName: "Imported",
			homePageURL: nil,
			containerExternalIDs: ["root"],
			zoneID: zoneID,
			fetch: { _ in throw CloudKitError(CKError(.unknownItem)) },
			saveNew: { savedRecord = $0 },
			saveUnchanged: { _ in unchangedSaveCount += 1 }
		)

		XCTAssertEqual(savedRecord?.recordID.recordName, urlString.md5String)
		XCTAssertEqual(savedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.url] as? String, urlString)
		XCTAssertTrue(result.wasAdded)
		XCTAssertEqual(unchangedSaveCount, 0)
	}

	func testExistingFeedPreservesDownloadedNameAndOmittedHomepageWhileReplacingPlacements() async throws {
		let record = feedRecord(urlString: "https://example.com/feed")
		record[CloudKitAccountZone.CloudKitFeed.Fields.name] = "Downloaded Name"
		record[CloudKitAccountZone.CloudKitFeed.Fields.editedName] = "Old Title"
		record[CloudKitAccountZone.CloudKitFeed.Fields.homePageURL] = "https://example.com/"
		record[CloudKitAccountZone.CloudKitFeed.Fields.containerExternalIDs] = ["old-folder"]
		var savedRecord: CKRecord?

		let result = try await CloudKitAccountZone.upsertFeed(
			urlString: "https://example.com/feed",
			name: nil,
			editedName: "Imported Title",
			homePageURL: nil,
			containerExternalIDs: ["folder-b", "folder-a"],
			zoneID: zoneID,
			fetch: { _ in record },
			saveNew: { _ in XCTFail("Existing records must not use the new-record save path") },
			saveUnchanged: { savedRecord = $0 }
		)

		XCTAssertEqual(savedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.name] as? String, "Downloaded Name")
		XCTAssertEqual(savedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.editedName] as? String, "Imported Title")
		XCTAssertEqual(savedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.homePageURL] as? String, "https://example.com/")
		XCTAssertEqual(savedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.containerExternalIDs] as? [String], ["folder-a", "folder-b"])
		XCTAssertEqual(result, CloudKitFeedUpsertResult(wasAdded: false, metadataChanged: true, placementChanged: true))
	}

	func testUnchangedFeedDoesNotSave() async throws {
		let record = feedRecord(urlString: "https://example.com/feed")
		record[CloudKitAccountZone.CloudKitFeed.Fields.editedName] = "Imported"
		record[CloudKitAccountZone.CloudKitFeed.Fields.containerExternalIDs] = ["root"]
		var saveCount = 0

		let result = try await CloudKitAccountZone.upsertFeed(
			urlString: "https://example.com/feed",
			name: nil,
			editedName: "Imported",
			homePageURL: nil,
			containerExternalIDs: ["root"],
			zoneID: zoneID,
			fetch: { _ in record },
			saveNew: { _ in XCTFail("Existing records must not use the new-record save path") },
			saveUnchanged: { _ in saveCount += 1 }
		)

		XCTAssertEqual(saveCount, 0)
		XCTAssertTrue(result.isUnchanged)
	}

	func testImportReportsConfirmedResultsWhenLaterFeedFails() async {
		let plan = CloudKitOPMLImportPlan(
			feeds: [
				PlannedCloudKitFeed(
					urlString: "https://example.com/first",
					editedName: nil,
					homePageURL: nil,
					isTopLevel: true,
					folderNames: []
				),
				PlannedCloudKitFeed(
					urlString: "https://example.com/second",
					editedName: nil,
					homePageURL: nil,
					isTopLevel: true,
					folderNames: []
				)
			],
			rejectedCount: 1
		)
		var upsertCount = 0

		do {
			_ = try await CloudKitAccountZone.importFeeds(
				rootExternalID: "root",
				plan: plan,
				folders: [:],
				initialResult: OPMLImportResult(rejected: plan.rejectedCount)
			) { _, _, _, _, _ in
				upsertCount += 1
				guard upsertCount == 1 else {
					throw TestError.expected
				}
				return CloudKitFeedUpsertResult(wasAdded: true, metadataChanged: false, placementChanged: false)
			}
			XCTFail("Expected the second feed to fail")
		} catch let error as OPMLImportPartialFailure {
			XCTAssertEqual(error.result.added, 1)
			XCTAssertEqual(error.result.rejected, 1)
			XCTAssertTrue(error.underlyingError is TestError)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testImportReportsRejectedStateWhenFirstFeedFails() async {
		let plan = CloudKitOPMLImportPlan(
			feeds: [PlannedCloudKitFeed(
				urlString: "https://example.com/feed",
				editedName: nil,
				homePageURL: nil,
				isTopLevel: true,
				folderNames: []
			)],
			rejectedCount: 1
		)

		do {
			_ = try await CloudKitAccountZone.importFeeds(
				rootExternalID: "root",
				plan: plan,
				folders: [:],
				initialResult: OPMLImportResult(rejected: plan.rejectedCount)
			) { _, _, _, _, _ in
				throw TestError.expected
			}
			XCTFail("Expected the first feed to fail")
		} catch let error as OPMLImportPartialFailure {
			XCTAssertEqual(error.result.rejected, 1)
			XCTAssertTrue(error.underlyingError is TestError)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testImportReportsCommittedFoldersWhenFirstFeedFails() async {
		let plan = CloudKitOPMLImportPlan(
			feeds: [PlannedCloudKitFeed(
				urlString: "https://example.com/feed",
				editedName: nil,
				homePageURL: nil,
				isTopLevel: false,
				folderNames: ["Tech"]
			)],
			rejectedCount: 0
		)
		let folder = containerRecord(name: "Tech", externalID: "folder", isAccount: false)

		do {
			_ = try await CloudKitAccountZone.importFeeds(
				rootExternalID: "root",
				plan: plan,
				folders: ["Tech": folder],
				initialResult: OPMLImportResult(foldersAdded: 1)
			) { _, _, _, _, _ in
				throw TestError.expected
			}
			XCTFail("Expected the first feed to fail")
		} catch let error as OPMLImportPartialFailure {
			XCTAssertEqual(error.result.foldersAdded, 1)
			XCTAssertTrue(error.underlyingError is TestError)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testConflictRefetchesOnceAndReappliesImportFields() async throws {
		let first = feedRecord(urlString: "https://example.com/feed")
		first[CloudKitAccountZone.CloudKitFeed.Fields.name] = "First Name"
		first[CloudKitAccountZone.CloudKitFeed.Fields.containerExternalIDs] = ["old"]
		let refetched = feedRecord(urlString: "https://example.com/feed")
		refetched[CloudKitAccountZone.CloudKitFeed.Fields.name] = "Concurrent Name"
		refetched[CloudKitAccountZone.CloudKitFeed.Fields.homePageURL] = "https://concurrent.example/"
		refetched[CloudKitAccountZone.CloudKitFeed.Fields.containerExternalIDs] = ["concurrent"]
		var fetchCount = 0
		var saveCount = 0
		var lastSavedRecord: CKRecord?

		_ = try await CloudKitAccountZone.upsertFeed(
			urlString: "https://example.com/feed",
			name: nil,
			editedName: "Imported",
			homePageURL: nil,
			containerExternalIDs: ["root"],
			zoneID: zoneID,
			fetch: { _ in
				fetchCount += 1
				return fetchCount == 1 ? first : refetched
			},
			saveNew: { _ in XCTFail("Existing records must not use the new-record save path") },
			saveUnchanged: { record in
				saveCount += 1
				if saveCount == 1 {
					let conflict = CKError(.serverRecordChanged)
					throw CloudKitError(CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [record.recordID: conflict]]))
				}
				lastSavedRecord = record
			}
		)

		XCTAssertEqual(fetchCount, 2)
		XCTAssertEqual(saveCount, 2)
		XCTAssertEqual(lastSavedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.name] as? String, "Concurrent Name")
		XCTAssertEqual(lastSavedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.homePageURL] as? String, "https://concurrent.example/")
		XCTAssertEqual(lastSavedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.editedName] as? String, "Imported")
		XCTAssertEqual(lastSavedRecord?[CloudKitAccountZone.CloudKitFeed.Fields.containerExternalIDs] as? [String], ["root"])
	}

	func testFolderInventoryIgnoresRootAndIndexesExactNames() throws {
		let root = containerRecord(name: "Account", externalID: "root", isAccount: true)
		let folder = containerRecord(name: "Tech", externalID: "folder", isAccount: false)

		let inventory = try CloudKitAccountZone.folderInventory(records: [root, folder], rootExternalID: "root")

		XCTAssertEqual(inventory.keys.sorted(), ["Tech"])
		XCTAssertEqual(inventory["Tech"]?.externalID, "folder")
	}

	func testFolderInventoryRejectsDuplicateExactNames() {
		let first = containerRecord(name: "Tech", externalID: "first", isAccount: false)
		let second = containerRecord(name: "Tech", externalID: "second", isAccount: false)

		XCTAssertThrowsError(try CloudKitAccountZone.folderInventory(records: [first, second], rootExternalID: "root"))
	}

	func testFolderInventoryRejectsNamelessNonRootRecord() {
		let recordID = CKRecord.ID(recordName: "folder", zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitAccountZone.CloudKitContainer.recordType, recordID: recordID)
		record[CloudKitAccountZone.CloudKitContainer.Fields.isAccount] = "0"

		XCTAssertThrowsError(try CloudKitAccountZone.folderInventory(records: [record], rootExternalID: "root"))
	}

	func testFolderInventoryQueryUsesExistingIsAccountIndex() {
		let query = CloudKitAccountZone.folderInventoryQuery()

		XCTAssertEqual(query.recordType, CloudKitAccountZone.CloudKitContainer.recordType)
		XCTAssertEqual(query.predicate.predicateFormat, "isAccount == \"0\"")
	}

	func testFolderInventorySurfacesUnavailableDatabase() async {
		let defaults = UserDefaults(suiteName: UUID().uuidString)!
		let zone = CloudKitAccountZone(container: nil, userDefaults: defaults)

		do {
			_ = try await zone.inventoryFolders()
			XCTFail("Expected inventory to fail without a database")
		} catch {
			guard case CloudKitZoneError.databaseUnavailable = error else {
				return XCTFail("Unexpected error: \(error)")
			}
		}
	}

	private func feedRecord(urlString: String) -> CKRecord {
		let recordID = CKRecord.ID(recordName: urlString.md5String, zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitAccountZone.CloudKitFeed.recordType, recordID: recordID)
		record[CloudKitAccountZone.CloudKitFeed.Fields.url] = urlString
		return record
	}

	private func containerRecord(name: String, externalID: String, isAccount: Bool) -> CKRecord {
		let recordID = CKRecord.ID(recordName: externalID, zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitAccountZone.CloudKitContainer.recordType, recordID: recordID)
		record[CloudKitAccountZone.CloudKitContainer.Fields.name] = name
		record[CloudKitAccountZone.CloudKitContainer.Fields.isAccount] = isAccount ? "1" : "0"
		return record
	}
}

private enum TestError: Error {
	case expected
}
