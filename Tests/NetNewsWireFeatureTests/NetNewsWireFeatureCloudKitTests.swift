import CloudKit
@testable import CloudKitSync
import UIKit
import XCTest
@testable import Account
@testable import NetNewsWireFeature
import RSCore

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

		XCTAssertEqual(receivedIdentifiers, ["iCloud.com.staticevolution.staticreader.feeds"])
	}

	func testContainedRuntimeEnablesResetForExactConfiguredFeedsContainer() throws {
		_ = try NetNewsWireFeatureRuntime(
			configuration: makeConfiguration(),
			cloudKitContainerConfigurator: { identifier in
				XCTAssertEqual(identifier, CloudKitAccountContainerConfiguration.feedsContainerIdentifier)
			}
		)

		XCTAssertTrue(AccountManager.shared.cloudKitResetIsAvailable)
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
			userDefaultsSuiteName: "com.staticevolution.staticreader.conflicting.feeds.tests",
			cloudKitContainerIdentifier: "iCloud.com.staticevolution.staticreader.conflicting.feeds",
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

	func testOPMLImportRejectsActiveRefreshInsteadOfSilentlySucceeding() {
		XCTAssertThrowsError(try CloudKitAccountDelegate.opmlImportRootExternalID(
			refreshIsComplete: false,
			syncIsComplete: true,
			rootExternalID: "root"
		)) { error in
			XCTAssertEqual(error as? CloudKitAccountDelegateError, .importUnavailableWhileRefreshing)
		}
	}

	func testOPMLImportRejectsActiveCloudKitSyncInsteadOfRacingIt() {
		XCTAssertThrowsError(try CloudKitAccountDelegate.opmlImportRootExternalID(
			refreshIsComplete: true,
			syncIsComplete: false,
			rootExternalID: "root"
		)) { error in
			XCTAssertEqual(error as? CloudKitAccountDelegateError, .importUnavailableWhileRefreshing)
		}
	}

	func testOPMLImportRejectsAccountWithoutInitializedRoot() {
		XCTAssertThrowsError(try CloudKitAccountDelegate.opmlImportRootExternalID(
			refreshIsComplete: true,
			syncIsComplete: true,
			rootExternalID: nil
		)) { error in
			XCTAssertEqual(error as? CloudKitAccountDelegateError, .accountNotReady)
		}
	}

	func testOPMLImportAcceptsInitializedIdleAccount() throws {
		let rootExternalID = try CloudKitAccountDelegate.opmlImportRootExternalID(
			refreshIsComplete: true,
			syncIsComplete: true,
			rootExternalID: "root"
		)

		XCTAssertEqual(rootExternalID, "root")
	}

	func testSettingsOPMLImportFailureMapsCloudKitAuthorizationError() {
		let error = NSError(domain: CKErrorDomain, code: CKError.Code.badContainer.rawValue)

		XCTAssertEqual(
			SettingsViewController.opmlImportFailureMessage(error),
			"The iCloud container for feeds is unavailable. Check iCloud access and try again."
		)
	}

	func testCommittedOPMLImportDoesNotFailWhenFollowUpRefreshFails() async throws {
		var saved = false
		var reportedError: TestError?

		let result = try await CloudKitAccountDelegate.performOPMLImport(
			save: {
				saved = true
				return OPMLImportResult(added: 1)
			},
			refresh: { throw TestError.unavailable },
			verify: { false },
			reportRefreshError: { reportedError = $0 as? TestError }
		)

		XCTAssertTrue(saved)
		XCTAssertEqual(reportedError, .unavailable)
		XCTAssertEqual(result.added, 1)
		XCTAssertTrue(result.committedButNotApplied)
	}

	func testCommittedOPMLImportReportsAppliedWhenRefreshFailsAfterConvergence() async throws {
		let result = try await CloudKitAccountDelegate.performOPMLImport(
			save: { OPMLImportResult(unchanged: 1) },
			refresh: { throw TestError.unavailable },
			verify: { true },
			reportRefreshError: { _ in }
		)

		XCTAssertFalse(result.committedButNotApplied)
	}

	func testSettingsOPMLImportFailureUsesOperationalErrorDescription() {
		let error = CloudKitAccountDelegateError.accountNotReady

		XCTAssertEqual(
			SettingsViewController.opmlImportFailureMessage(error),
			error.localizedDescription
		)
	}

	func testSettingsPartialOPMLImportFailureReportsConfirmedCountsAndOperationalError() {
		let underlyingError = CloudKitAccountDelegateError.accountNotReady
		let error = OPMLImportPartialFailure(
			result: OPMLImportResult(foldersAdded: 1, added: 1, rejected: 2),
			underlyingError: underlyingError
		)

		XCTAssertEqual(
			SettingsViewController.opmlImportFailureMessage(error),
			"Folders added: 1\nAdded: 1\nUpdated: 0\nUnchanged: 0\nRepositioned: 0\nRejected: 2\n\n\(underlyingError.localizedDescription)"
		)
	}

	func testSettingsCloudKitResetRowIsVisibleForAccountOrInterruptedReset() {
		XCTAssertTrue(SettingsViewController.shouldShowCloudKitResetRow(
			hasAccount: true,
			resetPhase: .idle,
			resetIsAvailable: true
		))
		XCTAssertTrue(SettingsViewController.shouldShowCloudKitResetRow(
			hasAccount: false,
			resetPhase: .localAccountDeleted,
			resetIsAvailable: true
		))
		XCTAssertFalse(SettingsViewController.shouldShowCloudKitResetRow(
			hasAccount: false,
			resetPhase: .idle,
			resetIsAvailable: true
		))
		XCTAssertFalse(SettingsViewController.shouldShowCloudKitResetRow(
			hasAccount: true,
			resetPhase: .localAccountDeleted,
			resetIsAvailable: false
		))
	}

	func testSettingsCloudKitResetRowIsDisabledWhileBusy() {
		XCTAssertTrue(SettingsViewController.cloudKitResetRowIsEnabled(
			hasAccount: true,
			resetPhase: .idle,
			isBusy: false,
			resetIsAvailable: true
		))
		XCTAssertFalse(SettingsViewController.cloudKitResetRowIsEnabled(
			hasAccount: true,
			resetPhase: .idle,
			isBusy: true,
			resetIsAvailable: true
		))
		XCTAssertTrue(SettingsViewController.cloudKitResetRowIsEnabled(
			hasAccount: false,
			resetPhase: .localAccountDeleted,
			isBusy: false,
			resetIsAvailable: true
		))
	}

	func testSettingsCloudKitResetWarningNamesAllDeletedDataAndOldBuildRisk() {
		let message = SettingsViewController.cloudKitResetWarningMessage()

		for expectedText in [
			"subscriptions",
			"folders",
			"articles",
			"read/starred state",
			"close Static Reader build 157 or older on every device before resetting",
			"do not reopen it"
		] {
			XCTAssertTrue(message.localizedCaseInsensitiveContains(expectedText), "Missing \(expectedText) in: \(message)")
		}
	}

	func testSettingsProgressMessagesKeepContainedReaderOpen() {
		XCTAssertEqual(
			SettingsViewController.opmlImportProgressMessage(),
			"Keep Static Reader Feeds open until the import finishes."
		)
		XCTAssertEqual(
			SettingsViewController.cloudKitResetProgressMessage(),
			"This may take a few minutes. Keep Static Reader Feeds open."
		)
	}

	func testSettingsCannotDismissWhileOPMLImportIsInProgress() {
		XCTAssertTrue(SettingsViewController.settingsDismissalIsAllowed(opmlImportInProgress: false))
		XCTAssertFalse(SettingsViewController.settingsDismissalIsAllowed(opmlImportInProgress: true))
	}

	func testSettingsActiveResultPresenterUsesVisibleSettingsOrRootFallback() {
		let settings = UIViewController()
		let root = UIViewController()

		XCTAssertTrue(SettingsViewController.activeResultPresenter(
			settings: settings,
			root: root,
			settingsIsVisible: true
		) === settings)
		XCTAssertTrue(SettingsViewController.activeResultPresenter(
			settings: settings,
			root: root,
			settingsIsVisible: false
		) === root)
		XCTAssertNil(SettingsViewController.activeResultPresenter(
			settings: settings,
			root: nil,
			settingsIsVisible: false
		))
	}

	func testSettingsCloudKitResetFinalConfirmationNamesAccount() {
		let message = SettingsViewController.cloudKitResetFinalConfirmationMessage(accountName: "Ryan's iCloud Feeds")

		XCTAssertTrue(message.contains("Ryan's iCloud Feeds"))
	}

	func testSettingsOPMLImportResultMessageFormatsConfirmedCounts() {
		let result = OPMLImportResult(foldersAdded: 1, added: 2, updated: 3, unchanged: 4, repositioned: 5, rejected: 6)

		XCTAssertEqual(
			SettingsViewController.importResultMessage(result),
			"Folders added: 1\nAdded: 2\nUpdated: 3\nUnchanged: 4\nRepositioned: 5\nRejected: 6"
		)
	}

	func testSettingsOPMLImportResultMessageExplainsCommittedButNotApplied() {
		var result = OPMLImportResult(added: 2)
		result.committedButNotApplied = true

		let message = SettingsViewController.importResultMessage(result)

		XCTAssertTrue(message.contains("Added: 2"))
		XCTAssertTrue(message.localizedCaseInsensitiveContains("saved"))
		XCTAssertTrue(message.localizedCaseInsensitiveContains("refresh once"))
		XCTAssertFalse(message.localizedCaseInsensitiveContains("import again"))
	}

	func testRemoteNotificationIdentityRequiresMatchingContainerAndZone() {
		let expectedZoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
		let otherZoneID = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)

		XCTAssertTrue(CloudKitRemoteNotificationResult.handles(
			notificationContainerIdentifier: "iCloud.com.staticevolution.staticreader.feeds",
			notificationZoneID: expectedZoneID,
			expectedContainerIdentifier: "iCloud.com.staticevolution.staticreader.feeds",
			expectedZoneID: expectedZoneID
		))
		XCTAssertFalse(CloudKitRemoteNotificationResult.handles(
			notificationContainerIdentifier: "iCloud.com.staticevolution.staticreader",
			notificationZoneID: expectedZoneID,
			expectedContainerIdentifier: "iCloud.com.staticevolution.staticreader.feeds",
			expectedZoneID: expectedZoneID
		))
		XCTAssertFalse(CloudKitRemoteNotificationResult.handles(
			notificationContainerIdentifier: "iCloud.com.staticevolution.staticreader.feeds",
			notificationZoneID: otherZoneID,
			expectedContainerIdentifier: "iCloud.com.staticevolution.staticreader.feeds",
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

	func testArticleUsesCanonicalStringWebFeedURLField() {
		let zoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
		let record = CKRecord(recordType: CloudKitArticlesZone.CloudKitArticle.recordType, recordID: CKRecord.ID(recordName: "article", zoneID: zoneID))
		record[CloudKitArticlesZone.CloudKitArticle.Fields.uniqueID] = "unique"
		record[CloudKitArticlesZone.CloudKitArticle.Fields.webFeedURL] = "https://example.com/feed"

		XCTAssertEqual(CloudKitArticlesZone.CloudKitArticle.Fields.webFeedURL, "webFeedURL")
		XCTAssertEqual(record[CloudKitArticlesZone.CloudKitArticle.Fields.webFeedURL] as? String, "https://example.com/feed")
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

	func testReceiveStatusOperationRetainsRefreshFailure() async throws {
		let userDefaults = try XCTUnwrap(UserDefaults(suiteName: "NetNewsWireFeatureCloudKitTests.receiveFailure"))
		let zone = CloudKitArticlesZone(container: nil, userDefaults: userDefaults, syncArticleContentForUnreadArticles: { false })
		let operation = CloudKitReceiveStatusOperation(articlesZone: zone, accountID: "test", accountDisplayName: "Test")
		let queue = MainThreadOperationQueue()
		let completion = expectation(description: "Receive status operation completes")
		operation.completionBlock = { _ in completion.fulfill() }

		queue.add(operation)
		await fulfillment(of: [completion], timeout: 2)

		guard let receiveError = operation.receiveError as? CloudKitZoneError,
				case .databaseUnavailable = receiveError else {
			return XCTFail("Expected databaseUnavailable, got \(String(describing: operation.receiveError))")
		}
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
			cloudKitContainerIdentifier: "iCloud.com.staticevolution.staticreader.feeds",
			resourceBundle: .netNewsWireFeatureResources,
			capabilities: .containedReader
		)
	}
}
