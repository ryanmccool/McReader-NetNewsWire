//
//  CloudKitAccountResetCoordinatorTests.swift
//  AccountTests
//

import CloudKit
import XCTest
@testable import Account

@MainActor final class CloudKitAccountResetCoordinatorTests: XCTestCase {

	func testResetResumesAfterEveryPersistedPhase() async throws {
		for interruptedPhase in CloudKitAccountResetPhase.allCases where interruptedPhase != .idle {
			let defaults = makeDefaults()
			let firstRunOperations = Operations()
			let firstRun = makeCoordinator(defaults: defaults, operations: firstRunOperations)

			do {
				try await firstRun.run { phase in
					if phase == interruptedPhase {
						throw TestError.interrupted
					}
				}
				XCTFail("Expected interruption after \(interruptedPhase)")
			} catch TestError.interrupted {
				// Expected.
			}

			XCTAssertEqual(firstRun.phase, interruptedPhase)

			let resumedOperations = Operations()
			let resumed = makeCoordinator(defaults: defaults, operations: resumedOperations)
			try await resumed.run()

			XCTAssertEqual(resumed.phase, .idle)
			XCTAssertEqual(resumedOperations.values, expectedOperations(after: interruptedPhase))
		}
	}

	func testResetDeletesOnlyFeedsAccountAndArticlesZones() async throws {
		let defaults = makeDefaults()
		var deletedZoneIDs = [CKRecordZone.ID]()
		let coordinator = CloudKitAccountResetCoordinator(
			userDefaults: defaults,
			deleteZone: { deletedZoneIDs.append($0) },
			deleteLocalAccount: {},
			recreateAccount: {},
			initializeCloud: {},
			verifyEmpty: {}
		)

		try await coordinator.run()

		XCTAssertEqual(deletedZoneIDs.map(\.zoneName), ["Account", "Articles"])
		XCTAssertTrue(deletedZoneIDs.allSatisfy { $0.ownerName == CKCurrentUserDefaultName })
	}

	func testResetContainerValidationRejectsMcReaderLibraryContainer() {
		XCTAssertEqual(CloudKitAccountContainerConfiguration.feedsContainerIdentifier, "iCloud.com.staticevolution.staticreader.feeds")
		XCTAssertTrue(CloudKitAccountContainerConfiguration.isResetContainerIdentifier(CloudKitAccountContainerConfiguration.feedsContainerIdentifier))
		XCTAssertFalse(CloudKitAccountContainerConfiguration.isResetContainerIdentifier("iCloud.com.staticevolution.staticreader"))
		XCTAssertFalse(CloudKitAccountContainerConfiguration.isResetContainerIdentifier("iCloud.example.Other.Feeds"))
		XCTAssertFalse(CloudKitAccountContainerConfiguration.isResetContainerIdentifier("iCloud.com.staticevolution.staticreader.staging.feeds"))
		XCTAssertFalse(CloudKitAccountContainerConfiguration.isResetContainerIdentifier(nil))
	}

	func testResetAvailabilityRequiresEmbeddedModeAndExactFeedsContainer() {
		let feedsContainer = CloudKitAccountContainerConfiguration.feedsContainerIdentifier

		XCTAssertTrue(CloudKitAccountContainerConfiguration.isResetAvailable(
			isEmbedded: true,
			containerIdentifier: feedsContainer
		))
		XCTAssertFalse(CloudKitAccountContainerConfiguration.isResetAvailable(
			isEmbedded: false,
			containerIdentifier: feedsContainer
		))
		XCTAssertFalse(CloudKitAccountContainerConfiguration.isResetAvailable(
			isEmbedded: true,
			containerIdentifier: nil
		))
		XCTAssertFalse(CloudKitAccountContainerConfiguration.isResetAvailable(
			isEmbedded: true,
			containerIdentifier: "iCloud.com.staticevolution.staticreader"
		))
	}

	func testResetStateSurvivesDeletingICloudAccountDefaults() {
		let defaults = makeDefaults()
		defaults.set("value", forKey: "iCloud-externalID")
		let coordinator = makeCoordinator(defaults: defaults)
		coordinator.phase = .zonesDeleted

		for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("iCloud-") {
			defaults.removeObject(forKey: key)
		}

		XCTAssertFalse(CloudKitAccountResetCoordinator.phaseDefaultsKey.hasPrefix("iCloud-"))
		XCTAssertEqual(coordinator.phase, .zonesDeleted)
	}

	func testMissingZonesAndLocalAccountAreSuccessfulNoOps() async throws {
		let coordinator = makeCoordinator(defaults: makeDefaults())

		try await coordinator.run()

		XCTAssertEqual(coordinator.phase, .idle)
	}

	func testMarkerRemainsAtCloudInitializedUntilEmptyVerificationSucceeds() async throws {
		let defaults = makeDefaults()
		var verifyShouldFail = true
		let coordinator = CloudKitAccountResetCoordinator(
			userDefaults: defaults,
			deleteZone: { _ in },
			deleteLocalAccount: {},
			recreateAccount: {},
			initializeCloud: {},
			verifyEmpty: {
				if verifyShouldFail {
					throw TestError.notEmpty
				}
			}
		)

		do {
			try await coordinator.run()
			XCTFail("Expected verification failure")
		} catch TestError.notEmpty {
			// Expected.
		}
		XCTAssertEqual(coordinator.phase, .cloudInitialized)

		verifyShouldFail = false
		try await coordinator.run()
		XCTAssertEqual(coordinator.phase, .idle)
	}

	func testInitialSetupAwaitsEveryLifecycleStepInOrder() async throws {
		var operations = [String]()

		try await CloudKitAccountDelegate.performInitialSetup(
			createAccountZone: { operations.append("accountZone") },
			createArticlesZone: { operations.append("articlesZone") },
			createAccountRoot: { operations.append("accountRoot") },
			subscribeAccountZone: { operations.append("accountSubscription") },
			subscribeArticlesZone: { operations.append("articlesSubscription") },
			initialRefresh: { operations.append("initialRefresh") },
			verifyEmpty: { operations.append("verifyEmpty") }
		)

		XCTAssertEqual(operations, [
			"accountZone", "articlesZone", "accountRoot", "accountSubscription",
			"articlesSubscription", "initialRefresh", "verifyEmpty"
		])
	}

	func testLocalAccountRemovalIgnoresOnlyMissingDirectory() throws {
		XCTAssertNoThrow(try AccountManager.removeCloudKitAccountDirectory(atPath: "/missing") { _ in
			throw CocoaError(.fileNoSuchFile)
		})

		XCTAssertThrowsError(try AccountManager.removeCloudKitAccountDirectory(atPath: "/failed") { _ in
			throw TestError.unavailable
		}) { error in
			XCTAssertEqual(error as? TestError, .unavailable)
		}
	}

	func testPersistedResetSuppressesOrdinaryAutomaticSetup() {
		let defaults = makeDefaults()
		let coordinator = makeCoordinator(defaults: defaults)

		XCTAssertTrue(CloudKitAccountDelegate.shouldStartAutomaticInitialSetup(externalID: nil, userDefaults: defaults))
		coordinator.phase = .accountRecreated
		XCTAssertFalse(CloudKitAccountDelegate.shouldStartAutomaticInitialSetup(externalID: nil, userDefaults: defaults))
		XCTAssertFalse(CloudKitAccountDelegate.shouldStartAutomaticInitialSetup(externalID: "root", userDefaults: defaults))
	}

	func testAwaitingCachedFailedSetupRetriesInSameCall() async throws {
		let failedTask = Task<Void, Error> { throw TestError.unavailable }
		var retryCount = 0

		let completedTask = try await CloudKitAccountDelegate.awaitInitialSetup(existingTask: failedTask) {
			retryCount += 1
			return Task {}
		}

		try await completedTask.value
		XCTAssertEqual(retryCount, 1)
	}
}

@MainActor private extension CloudKitAccountResetCoordinatorTests {
	func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "CloudKitAccountResetCoordinatorTests.\(UUID().uuidString)")!
	}

	func makeCoordinator(
		defaults: UserDefaults,
		operations: Operations? = nil
	) -> CloudKitAccountResetCoordinator {
		CloudKitAccountResetCoordinator(
			userDefaults: defaults,
			deleteZone: { _ in operations?.values.append("deleteZone") },
			deleteLocalAccount: { operations?.values.append("deleteLocalAccount") },
			recreateAccount: { operations?.values.append("recreateAccount") },
			initializeCloud: { operations?.values.append("initializeCloud") },
			verifyEmpty: { operations?.values.append("verifyEmpty") }
		)
	}

	func expectedOperations(after phase: CloudKitAccountResetPhase) -> [String] {
		switch phase {
		case .idle:
			return ["deleteZone", "deleteZone", "deleteLocalAccount", "recreateAccount", "initializeCloud", "verifyEmpty"]
		case .zonesDeleted:
			return ["deleteLocalAccount", "recreateAccount", "initializeCloud", "verifyEmpty"]
		case .localAccountDeleted:
			return ["recreateAccount", "initializeCloud", "verifyEmpty"]
		case .accountRecreated:
			return ["initializeCloud", "verifyEmpty"]
		case .cloudInitialized:
			return ["verifyEmpty"]
		case .verified:
			return []
		}
	}
}

@MainActor private final class Operations {
	var values = [String]()
}

private enum TestError: Error, Equatable {
	case interrupted
	case notEmpty
	case unavailable
}
