import CloudKit
@testable import CloudKitSync
import XCTest
@testable import Account
@testable import NetNewsWireFeature

@MainActor
final class NetNewsWireFeatureCloudKitTests: XCTestCase {
	private enum TestError: Error, Equatable {
		case unavailable
	}

	override class func setUp() {
		super.setUp()
		try! NetNewsWireFeatureTestEnvironment.configure()
	}

	func testRuntimeConfiguresExactInjectedCloudKitContainerIdentifier() throws {
		var receivedIdentifiers = [String]()
		let configuration = try makeConfiguration()

		_ = try NetNewsWireFeatureRuntime(
			configuration: configuration,
			cloudKitContainerConfigurator: { receivedIdentifiers.append($0) }
		)

		XCTAssertEqual(receivedIdentifiers, ["iCloud.ryanmccool.McReader.Feeds"])
	}

	func testRuntimePropagatesCloudKitContainerConfigurationFailure() throws {
		let configuration = try makeConfiguration()

		XCTAssertThrowsError(try NetNewsWireFeatureRuntime(
			configuration: configuration,
			cloudKitContainerConfigurator: { _ in throw TestError.unavailable }
		)) { error in
			XCTAssertEqual(error as? TestError, .unavailable)
		}
	}

	func testRejectedRuntimeDoesNotMutateCloudKitContainerConfiguration() throws {
		var configuredIdentifiers = [String]()
		_ = try NetNewsWireFeatureRuntime(
			configuration: makeConfiguration(),
			cloudKitContainerConfigurator: { _ in }
		)
		let conflictingConfiguration = try NetNewsWireFeatureConfiguration(
			dataDirectoryURL: NetNewsWireFeatureTestEnvironment.values.dataDirectoryURL,
			cacheDirectoryURL: NetNewsWireFeatureTestEnvironment.values.cacheDirectoryURL,
			userDefaultsSuiteName: "ryanmccool.McReader.ConflictingFeedsTests",
			cloudKitContainerIdentifier: "iCloud.ryanmccool.McReader.ConflictingFeeds",
			resourceBundle: .netNewsWireFeatureResources,
			capabilities: .containedReader
		)

		XCTAssertThrowsError(try NetNewsWireFeatureRuntime(
			configuration: conflictingConfiguration,
			cloudKitContainerConfigurator: { configuredIdentifiers.append($0) }
		)) { error in
			XCTAssertEqual(error as? NetNewsWireFeatureConfigurationError, .alreadyConfigured)
		}
		XCTAssertTrue(configuredIdentifiers.isEmpty)
	}

	func testStandaloneContainerSelectionUsesDefaultWhenNoEmbeddedContainerWasConfigured() {
		var defaultFactoryCallCount = 0

		let selected = CloudKitAccountContainerConfiguration.resolve(
			configured: Optional<String>.none,
			defaultContainer: {
				defaultFactoryCallCount += 1
				return "entitlement-default"
			}
		)

		XCTAssertEqual(selected, "entitlement-default")
		XCTAssertEqual(defaultFactoryCallCount, 1)
	}

	func testNoActiveCloudKitAccountDoesNotAcceptRemoteNotification() async {
		let manager = AccountManager()

		let accepted = await manager.receiveRemoteNotification(userInfo: [:])

		XCTAssertFalse(accepted)
	}

	func testContainerAuthorizationErrorMapsToLocalizedAccountError() {
		let error = NSError(domain: CKErrorDomain, code: CKError.Code.badContainer.rawValue)

		let mappedError = CloudKitAccountDelegateError.userVisibleError(for: error)

		XCTAssertEqual(mappedError as? CloudKitAccountDelegateError, .containerUnavailable)
		XCTAssertEqual(mappedError.localizedDescription, "The iCloud container for feeds is unavailable. Check iCloud access and try again.")
	}

	func testRemoteNotificationIdentityRequiresMatchingContainerAndZone() {
		let expectedZoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
		let otherZoneID = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)

		XCTAssertTrue(CloudKitRemoteNotificationResult.handles(
			notificationContainerIdentifier: "iCloud.ryanmccool.McReader.Feeds",
			notificationZoneID: expectedZoneID,
			expectedContainerIdentifier: "iCloud.ryanmccool.McReader.Feeds",
			expectedZoneID: expectedZoneID
		))
		XCTAssertFalse(CloudKitRemoteNotificationResult.handles(
			notificationContainerIdentifier: "iCloud.ryanmccool.McReader",
			notificationZoneID: expectedZoneID,
			expectedContainerIdentifier: "iCloud.ryanmccool.McReader.Feeds",
			expectedZoneID: expectedZoneID
		))
		XCTAssertFalse(CloudKitRemoteNotificationResult.handles(
			notificationContainerIdentifier: "iCloud.ryanmccool.McReader.Feeds",
			notificationZoneID: otherZoneID,
			expectedContainerIdentifier: "iCloud.ryanmccool.McReader.Feeds",
			expectedZoneID: expectedZoneID
		))
	}

	func testRemoteNotificationFetchResultRequiresActualChanges() {
		XCTAssertEqual(CloudKitRemoteNotificationResult.fetched(changedCount: 0, deletedCount: 0), .noChanges)
		XCTAssertEqual(CloudKitRemoteNotificationResult.fetched(changedCount: 1, deletedCount: 0), .changes)
		XCTAssertEqual(CloudKitRemoteNotificationResult.fetched(changedCount: 0, deletedCount: 1), .changes)
	}

	func testRemoteNotificationResultPreservesChangesAcrossZonesAndPages() {
		XCTAssertEqual(CloudKitRemoteNotificationResult.notHandled.merging(.noChanges), .noChanges)
		XCTAssertEqual(CloudKitRemoteNotificationResult.noChanges.merging(.changes), .changes)
		XCTAssertEqual(CloudKitRemoteNotificationResult.changes.merging(.noChanges), .changes)
	}

	func testFetchCallbackStateSnapshotsMutationsBeforeResultProcessing() {
		let zoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
		let changedRecord = CKRecord(recordType: "ArticleStatus", recordID: CKRecord.ID(recordName: "changed", zoneID: zoneID))
		let deletedRecordID = CKRecord.ID(recordName: "deleted", zoneID: zoneID)
		let state = CloudKitZoneFetchCallbackState(savedChangeToken: nil)

		state.appendChangedRecord(changedRecord)
		state.appendDeletedRecord(recordType: "ArticleStatus", recordID: deletedRecordID)
		state.updateZoneResult(serverChangeToken: nil, moreComing: true)
		let snapshot = state.snapshot()

		XCTAssertEqual(snapshot.changedRecords.map(\.recordID), [changedRecord.recordID])
		XCTAssertEqual(snapshot.deletedRecordKeys.map(\.recordID), [deletedRecordID])
		XCTAssertTrue(snapshot.moreComing)
	}

	private func makeConfiguration() throws -> NetNewsWireFeatureConfiguration {
		try FileManager.default.createDirectory(
			at: NetNewsWireFeatureTestEnvironment.rootURL,
			withIntermediateDirectories: true
		)
		return try NetNewsWireFeatureConfiguration(
			dataDirectoryURL: NetNewsWireFeatureTestEnvironment.values.dataDirectoryURL,
			cacheDirectoryURL: NetNewsWireFeatureTestEnvironment.values.cacheDirectoryURL,
			userDefaultsSuiteName: NetNewsWireFeatureTestEnvironment.suiteName,
			cloudKitContainerIdentifier: "iCloud.ryanmccool.McReader.Feeds",
			resourceBundle: .netNewsWireFeatureResources,
			capabilities: .containedReader
		)
	}
}
