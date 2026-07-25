import XCTest
@testable import Account
@testable import RSCore
@testable import NetNewsWireFeature

enum NetNewsWireFeatureTestEnvironment {
	static let rootURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("NetNewsWireFeatureTests", isDirectory: true)
	static let suiteName = "ryanmccool.McReader.Feeds.NetNewsWire.tests.\(UUID().uuidString)"

	static var values: NetNewsWireEnvironmentValues {
		NetNewsWireEnvironmentValues(
			mode: .embedded,
			dataDirectoryURL: rootURL.appendingPathComponent("Application Support", isDirectory: true),
			cacheDirectoryURL: rootURL.appendingPathComponent("Caches", isDirectory: true),
			userDefaultsSuiteName: suiteName,
			cloudKitContainerIdentifier: "iCloud.ryanmccool.McReader.Feeds",
			resourceBundle: .netNewsWireFeatureResources
		)
	}

	static func configure() throws {
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		try NetNewsWireEnvironment.configure(values)
	}
}

@MainActor
final class NetNewsWireFeatureConfigurationTests: XCTestCase {
	override class func setUp() {
		super.setUp()
		try! NetNewsWireFeatureTestEnvironment.configure()
	}

	func testRejectsNonICloudContainerIdentifier() {
		XCTAssertThrowsError(try makeConfiguration(cloudKitContainerIdentifier: "ryanmccool.McReader.Feeds")) { error in
			XCTAssertEqual(error as? NetNewsWireFeatureConfigurationError, .invalidCloudKitContainerIdentifier)
		}
	}

	func testRejectsEmptyDefaultsSuiteName() {
		XCTAssertThrowsError(try makeConfiguration(userDefaultsSuiteName: "  ")) { error in
			XCTAssertEqual(error as? NetNewsWireFeatureConfigurationError, .emptyUserDefaultsSuiteName)
		}
	}

	func testRejectsMissingDataDirectoryParent() {
		let missingParent = NetNewsWireFeatureTestEnvironment.rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let dataURL = missingParent.appendingPathComponent("Data", isDirectory: true)

		XCTAssertThrowsError(try makeConfiguration(dataDirectoryURL: dataURL)) { error in
			XCTAssertEqual(error as? NetNewsWireFeatureConfigurationError, .invalidDirectoryParent(dataURL))
		}
	}

	func testRejectsBundleWithoutFeatureMarker() {
		XCTAssertThrowsError(try makeConfiguration(resourceBundle: .main)) { error in
			XCTAssertEqual(error as? NetNewsWireFeatureConfigurationError, .invalidFeatureBundle)
		}
	}

	func testContainedReaderCapabilitiesDoNotOwnHostGlobals() {
		XCTAssertEqual(.containedReader, NetNewsWireFeatureCapabilities(
			mayPresentUserNotifications: false,
			mayHandleNotificationResponses: false,
			mayChangeApplicationBadge: false,
			mayRegisterBackgroundTasks: false,
			mayInstallQuickActions: false,
			extensionsAreAvailable: false,
			mayRestoreSceneState: false,
			mayUseStandaloneSceneDelegates: false,
			mayDonateActivities: false
		))
	}

	func testStandaloneCapabilitiesPreserveUpstreamOwnership() {
		XCTAssertEqual(.standalone, NetNewsWireFeatureCapabilities(
			mayPresentUserNotifications: true,
			mayHandleNotificationResponses: true,
			mayChangeApplicationBadge: true,
			mayRegisterBackgroundTasks: true,
			mayInstallQuickActions: true,
			extensionsAreAvailable: true,
			mayRestoreSceneState: true,
			mayUseStandaloneSceneDelegates: true,
			mayDonateActivities: true
		))
	}

	func testBundleResolutionRequiresConfiguredEnvironment() {
		XCTAssertThrowsError(try NetNewsWireBundleResolution.resourceBundle(environment: nil)) { error in
			XCTAssertEqual(error as? NetNewsWireEnvironmentError, .notConfigured)
		}
	}

	func testRuntimeConfiguresEnvironmentBeforeBootstrap() throws {
		let configuration = try makeConfiguration()
		_ = try makeRuntime(configuration: configuration)
		XCTAssertEqual(NetNewsWireEnvironment.current?.dataDirectoryURL, configuration.dataDirectoryURL)
	}

	func testEmbeddedEnvironmentProvidesNetNewsWireUserAgents() {
		XCTAssertEqual(NetNewsWireEnvironment.current?.userAgent, "NetNewsWire (RSS Reader; https://netnewswire.com/)")
		XCTAssertEqual(NetNewsWireEnvironment.current?.extendedUserAgent, "NetNewsWire (RSS Reader; https://netnewswire.com/; [platform]; [version] ([build]))")
	}

	func testEmbeddedEnvironmentDisablesUbiquitousKeyValueStore() {
		XCTAssertFalse(AccountManager.usesUbiquitousKeyValueStore)
	}

	func testRuntimeRejectsSecondDifferentConfiguration() throws {
		_ = try makeRuntime(configuration: makeConfiguration())

		XCTAssertThrowsError(try makeRuntime(configuration: makeConfiguration(
			userDefaultsSuiteName: "ryanmccool.McReader.OtherNetNewsWireTests"
		))) { error in
			XCTAssertEqual(error as? NetNewsWireFeatureConfigurationError, .alreadyConfigured)
		}
	}

	func testRuntimeRejectsDifferentCapabilitiesAfterConfiguration() throws {
		_ = try makeRuntime(configuration: makeConfiguration())

		XCTAssertThrowsError(try makeRuntime(configuration: makeConfiguration(capabilities: .standalone))) { error in
			XCTAssertEqual(error as? NetNewsWireFeatureConfigurationError, .alreadyConfigured)
		}
	}

	func testRuntimeAcceptsEquivalentRepeatedConfiguration() throws {
		let configuration = try makeConfiguration()
		XCTAssertNoThrow(try makeRuntime(configuration: configuration))
		XCTAssertNoThrow(try makeRuntime(configuration: configuration))
	}

	private func makeRuntime(configuration: NetNewsWireFeatureConfiguration) throws -> NetNewsWireFeatureRuntime {
		try NetNewsWireFeatureRuntime(
			configuration: configuration,
			cloudKitContainerConfigurator: { _ in }
		)
	}

	private func makeConfiguration(
		dataDirectoryURL: URL = NetNewsWireFeatureTestEnvironment.values.dataDirectoryURL,
		cacheDirectoryURL: URL = NetNewsWireFeatureTestEnvironment.values.cacheDirectoryURL,
		userDefaultsSuiteName: String = NetNewsWireFeatureTestEnvironment.suiteName,
		cloudKitContainerIdentifier: String = "iCloud.ryanmccool.McReader.Feeds",
		resourceBundle: Bundle = .netNewsWireFeatureResources,
		capabilities: NetNewsWireFeatureCapabilities = .containedReader
	) throws -> NetNewsWireFeatureConfiguration {
		try NetNewsWireFeatureConfiguration(
			dataDirectoryURL: dataDirectoryURL,
			cacheDirectoryURL: cacheDirectoryURL,
			userDefaultsSuiteName: userDefaultsSuiteName,
			cloudKitContainerIdentifier: cloudKitContainerIdentifier,
			resourceBundle: resourceBundle,
			capabilities: capabilities
		)
	}
}
