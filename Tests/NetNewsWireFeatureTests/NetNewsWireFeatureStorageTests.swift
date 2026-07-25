import CloudKit
import CloudKitSync
import XCTest
@testable import Account
@testable import NetNewsWireFeature
@testable import RSCore

@MainActor
final class NetNewsWireFeatureStorageTests: XCTestCase {
	override class func setUp() {
		super.setUp()
		try! NetNewsWireFeatureTestEnvironment.configure()
	}

	func testConfiguredStorageRootsReplaceSystemDirectories() throws {
		let environment = try XCTUnwrap(NetNewsWireEnvironment.current)

		XCTAssertTrue(AppConfig.dataFolder.path.hasPrefix(environment.dataDirectoryURL.path))
		XCTAssertTrue(AppConfig.cacheFolder.path.hasPrefix(environment.cacheDirectoryURL.path))
		XCTAssertFalse(AppConfig.dataFolder.path.contains("/Documents"))
		XCTAssertEqual(AppConfig.defaultsSuiteName, environment.userDefaultsSuiteName)
		XCTAssertTrue(try XCTUnwrap(Platform.dataSubfolder(forApplication: nil, folderName: "Themes"))
			.hasPrefix(environment.dataDirectoryURL.path))
	}

	func testConfiguredDefaultsDoNotWriteToStandardDefaults() {
		let key = "NetNewsWireFeatureStorageTests.configured-defaults"
		UserDefaults.standard.removeObject(forKey: key)
		AppConfig.defaults.set(true, forKey: key)

		XCTAssertTrue(AppConfig.defaults.bool(forKey: key))
		XCTAssertNil(UserDefaults.standard.object(forKey: key))
	}

	func testGeneralDefaultsUseStandardStandaloneAndInjectedSuiteEmbedded() {
		let standalone = environment(mode: .standalone)
		let embedded = environment(mode: .embedded)
		let key = "NetNewsWireFeatureStorageTests.general-defaults"
		let embeddedSuite = UserDefaults(suiteName: embedded.userDefaultsSuiteName)!
		UserDefaults.standard.removeObject(forKey: key)
		embeddedSuite.removeObject(forKey: key)

		XCTAssertTrue(AppConfig.defaults(for: standalone) === UserDefaults.standard)
		AppConfig.defaults(for: embedded).set(true, forKey: key)

		XCTAssertTrue(embeddedSuite.bool(forKey: key))
		XCTAssertNil(UserDefaults.standard.object(forKey: key))
	}

	func testAppDefaultsUseAppGroupStandaloneAndInjectedSuiteEmbedded() {
		let standaloneSuiteName = "com.ranchero.NetNewsWire.tests.\(UUID().uuidString)"
		let embedded = environment(mode: .embedded)
		let key = "NetNewsWireFeatureStorageTests.app-defaults"
		let standaloneSuite = UserDefaults(suiteName: standaloneSuiteName)!
		let embeddedSuite = UserDefaults(suiteName: embedded.userDefaultsSuiteName)!
		standaloneSuite.removeObject(forKey: key)
		embeddedSuite.removeObject(forKey: key)

		AppDefaults.store(for: environment(mode: .standalone), standaloneSuiteName: standaloneSuiteName).set(true, forKey: key)
		XCTAssertTrue(standaloneSuite.bool(forKey: key))
		XCTAssertNil(embeddedSuite.object(forKey: key))

		standaloneSuite.removeObject(forKey: key)
		AppDefaults.store(for: embedded, standaloneSuiteName: standaloneSuiteName).set(true, forKey: key)
		XCTAssertTrue(embeddedSuite.bool(forKey: key))
		XCTAssertNil(standaloneSuite.object(forKey: key))
	}

	func testThemeDownloadDirectoryPreservesStandaloneAndEmbeddedPaths() {
		let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
		let standaloneURL = ArticleThemeDownloader.downloadDirectory(
			for: environment(mode: .standalone),
			applicationSupportDirectory: applicationSupport
		)
		let embedded = environment(mode: .embedded)
		let embeddedURL = ArticleThemeDownloader.downloadDirectory(
			for: embedded,
			applicationSupportDirectory: applicationSupport
		)

		XCTAssertEqual(standaloneURL, applicationSupport.appendingPathComponent("NetNewsWire/Downloads", isDirectory: true))
		XCTAssertEqual(embeddedURL, embedded.dataDirectoryURL.appendingPathComponent("Downloads", isDirectory: true))
	}

	func testCloudKitChangeTokensUseInjectedDefaults() {
		let suite = UserDefaults(suiteName: NetNewsWireFeatureTestEnvironment.suiteName)!
		let zone = TestCloudKitZone(userDefaults: suite)
		let tokenData = Data("token".utf8)
		suite.set(tokenData, forKey: zone.changeTokenKey)
		UserDefaults.standard.set(tokenData, forKey: zone.changeTokenKey)

		zone.resetChangeToken()

		XCTAssertNil(suite.object(forKey: zone.changeTokenKey))
		XCTAssertEqual(UserDefaults.standard.data(forKey: zone.changeTokenKey), tokenData)
		UserDefaults.standard.removeObject(forKey: zone.changeTokenKey)
	}

	func testProductionCloudKitZonesReceiveInjectedDefaults() {
		let defaults = UserDefaults(suiteName: NetNewsWireFeatureTestEnvironment.suiteName)!
		let zones = CloudKitZoneFactory.makeZones(
			container: nil,
			userDefaults: defaults,
			syncArticleContentForUnreadArticles: { false }
		)

		XCTAssertTrue(zones.account.userDefaults === defaults)
		XCTAssertTrue(zones.articles.userDefaults === defaults)
	}

	private func environment(mode: NetNewsWireEnvironmentMode) -> NetNewsWireEnvironmentValues {
		let values = NetNewsWireFeatureTestEnvironment.values
		return NetNewsWireEnvironmentValues(
			mode: mode,
			dataDirectoryURL: values.dataDirectoryURL,
			cacheDirectoryURL: values.cacheDirectoryURL,
			userDefaultsSuiteName: values.userDefaultsSuiteName,
			cloudKitContainerIdentifier: values.cloudKitContainerIdentifier,
			resourceBundle: values.resourceBundle
		)
	}
}

@MainActor
private final class TestCloudKitZone: CloudKitZone {
	static let qualityOfService = QualityOfService.default
	let zoneID = CKRecordZone.ID(zoneName: "NetNewsWireFeatureStorageTests", ownerName: CKCurrentUserDefaultName)
	let container: CKContainer? = nil
	let database: CKDatabase? = nil
	let userDefaults: UserDefaults
	weak var delegate: CloudKitZoneDelegate?
	var fetchChangesPageHandler: CloudKitZoneFetchPageHandler?

	init(userDefaults: UserDefaults) {
		self.userDefaults = userDefaults
	}
}
