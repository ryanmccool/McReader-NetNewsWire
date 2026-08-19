import XCTest
import Account
import RSCore
@testable import NetNewsWireFeature

@MainActor
final class StarredArticleArchiveSettingsTests: XCTestCase {
	override func setUpWithError() throws {
		if NetNewsWireEnvironment.current == nil {
			let root = FileManager.default.temporaryDirectory.appendingPathComponent("Starred-Archive-Settings-Tests", isDirectory: true)
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			try NetNewsWireEnvironment.configure(.init(
				mode: .embedded,
				dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
				cacheDirectoryURL: root.appendingPathComponent("Cache", isDirectory: true),
				userDefaultsSuiteName: "NetNewsWireFeature.StarredArchiveTests",
				cloudKitContainerIdentifier: "iCloud.example.starred-archive-tests",
				resourceBundle: .netNewsWireFeatureResources
			))
		}
	}

	func testImportResultMessageReportsEveryOutcome() {
		var result = StarredArticleArchiveImportResult()
		result.added = 2
		result.updated = 3
		result.unchanged = 4
		result.rejected = 5

		let message = SettingsViewController.starredArchiveImportResultMessage(result)

		XCTAssertTrue(message.contains("Added: 2"))
		XCTAssertTrue(message.contains("Updated: 3"))
		XCTAssertTrue(message.contains("Unchanged: 4"))
		XCTAssertTrue(message.contains("Rejected: 5"))
	}

	func testImportResultMessageExplainsDeferredProviderSync() {
		var result = StarredArticleArchiveImportResult()
		result.upstreamSyncFailed = true

		let message = SettingsViewController.starredArchiveImportResultMessage(result)

		XCTAssertTrue(message.contains("imported on this device"))
		XCTAssertTrue(message.contains("Refresh the account"))
	}
}
