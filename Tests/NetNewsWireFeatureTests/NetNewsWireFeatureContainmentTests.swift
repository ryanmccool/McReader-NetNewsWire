import XCTest
import UIKit
@testable import NetNewsWireFeature

@MainActor
final class NetNewsWireFeatureContainmentTests: XCTestCase {
	override class func setUp() {
		super.setUp()
		try! NetNewsWireFeatureTestEnvironment.configure()
	}

	func testContainedHostLeavesHostGlobalStateUnchanged() async throws {
		XCTAssertNil(appDelegate, "This test must characterize the first feature bootstrap.")
		let applicationDelegateBefore = UIApplication.shared.delegate.map { ObjectIdentifier($0) }
		let hostNotificationDelegate = NSObject()
		var notificationDelegateIdentity: ObjectIdentifier? = ObjectIdentifier(hostNotificationDelegate)
		var shortcutItemTypes = ["host.quick-action"]
		let notificationDelegateBefore = notificationDelegateIdentity
		let shortcutItemsBefore = shortcutItemTypes
		var badgeMutationCount = 0
		var backgroundTaskRegistrationCount = 0
		var notificationAuthorizationRequestCount = 0
		let mutationSeams = NetNewsWireHostGlobalMutationSeams(
			didRequestBadgeChange: { _ in badgeMutationCount += 1 },
			didRegisterBackgroundTasks: { backgroundTaskRegistrationCount += 1 },
			didRequestNotificationAuthorization: { notificationAuthorizationRequestCount += 1 },
			didAssignNotificationDelegate: { notificationDelegateIdentity = ObjectIdentifier($0) },
			didInstallQuickActions: { shortcutItemTypes = $0 }
		)
		let runtime = try NetNewsWireFeatureRuntime(
			configuration: makeConfiguration(),
			cloudKitContainerConfigurator: { _ in }
		)

		_ = try runtime.makeHost(globalMutationSeams: mutationSeams)
		await withCheckedContinuation { continuation in
			DispatchQueue.main.async {
				continuation.resume()
			}
		}

		XCTAssertEqual(UIApplication.shared.delegate.map { ObjectIdentifier($0) }, applicationDelegateBefore)
		XCTAssertEqual(notificationDelegateIdentity, notificationDelegateBefore)
		XCTAssertEqual(shortcutItemTypes, shortcutItemsBefore)
		XCTAssertEqual(badgeMutationCount, 0)
		XCTAssertEqual(backgroundTaskRegistrationCount, 0)
		XCTAssertEqual(notificationAuthorizationRequestCount, 0)
	}

	func testContainedCapabilitiesRejectHostRestorationActivity() {
		let activity = NSUserActivity(activityType: "com.ryanmccool.tests.restoration")

		XCTAssertFalse(NetNewsWireFeatureCapabilities.containedReader.mayRestoreSceneState)
		XCTAssertNil(NetNewsWireSceneSetup.restorationActivity(activity, capabilities: .containedReader))
		XCTAssertIdentical(NetNewsWireSceneSetup.restorationActivity(activity, capabilities: .standalone), activity)
	}

	func testHostsKeepDistinctPublishingActions() throws {
		var firstHostSendCount = 0
		var secondHostSendCount = 0
		let runtime = try NetNewsWireFeatureRuntime(
			configuration: makeConfiguration(),
			cloudKitContainerConfigurator: { _ in }
		)
		let firstHost = try runtime.makeHost(publishingActions: NetNewsWirePublishingActions { _, _ in
			firstHostSendCount += 1
		})
		let secondHost = try runtime.makeHost(publishingActions: NetNewsWirePublishingActions { _, _ in
			secondHostSendCount += 1
		})
		let capture = NetNewsWirePublishingCapture(
			selectedText: nil,
			title: "Article",
			creator: nil,
			preferredURL: URL(string: "https://example.com/article")!
		)

		firstHost.publishingActions.send(capture, .capture)
		secondHost.publishingActions.send(capture, .post)

		XCTAssertEqual(firstHostSendCount, 1)
		XCTAssertEqual(secondHostSendCount, 1)
	}

	func testHostsKeepDistinctHighlightActions() async throws {
		var firstHostLoadCount = 0
		var secondHostLoadCount = 0
		let runtime = try NetNewsWireFeatureRuntime(
			configuration: makeConfiguration(),
			cloudKitContainerConfigurator: { _ in }
		)
		let firstHost = try runtime.makeHost(highlightActions: makeHighlightActions {
			firstHostLoadCount += 1
		})
		let secondHost = try runtime.makeHost(highlightActions: makeHighlightActions {
			secondHostLoadCount += 1
		})

		_ = try await firstHost.highlightActions.load("first")
		_ = try await secondHost.highlightActions.load("second")

		XCTAssertEqual(firstHostLoadCount, 1)
		XCTAssertEqual(secondHostLoadCount, 1)
	}

	func testStandaloneSceneSetupUsesDisabledHighlights() {
		XCTAssertFalse(NetNewsWireSceneSetup.standaloneHighlightActions.isEnabled)
	}

	private func makeConfiguration() throws -> NetNewsWireFeatureConfiguration {
		try NetNewsWireFeatureConfiguration(
			dataDirectoryURL: NetNewsWireFeatureTestEnvironment.values.dataDirectoryURL,
			cacheDirectoryURL: NetNewsWireFeatureTestEnvironment.values.cacheDirectoryURL,
			userDefaultsSuiteName: NetNewsWireFeatureTestEnvironment.suiteName,
			cloudKitContainerIdentifier: "iCloud.ryanmccool.McReader.Feeds",
			resourceBundle: .netNewsWireFeatureResources,
			capabilities: .containedReader
		)
	}

	private func makeHighlightActions(didLoad: @escaping () -> Void) -> NetNewsWireHighlightActions {
		NetNewsWireHighlightActions(
			load: { _ in
				didLoad()
				return []
			},
			insert: { _ in },
			delete: { _ in },
			observe: { _, _, _ in NetNewsWireHighlightObservation(cancel: {}) }
		)
	}
}
