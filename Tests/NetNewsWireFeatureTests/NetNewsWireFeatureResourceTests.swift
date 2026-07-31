import UIKit
import XCTest
@testable import NetNewsWireFeature

@MainActor
final class NetNewsWireFeatureResourceTests: XCTestCase {
	override class func setUp() {
		super.setUp()
		try! NetNewsWireFeatureTestEnvironment.configure()
	}

	func testRequiredResourcesAreContainedInFeatureBundle() throws {
		let bundle = Bundle.netNewsWireFeatureResources
		let developmentLocalization = try XCTUnwrap(
			bundle.infoDictionary?["CFBundleDevelopmentRegion"] as? String
		)
		let rootDecoy = FileManager.default.temporaryDirectory
			.appendingPathComponent("NetNewsWireFeatureResourceDecoys", isDirectory: true)
		try FileManager.default.createDirectory(at: rootDecoy, withIntermediateDirectories: true)
		for name in ["Main.storyboardc", "Assets.car", "Localizable.strings", "Appanoose.nnwtheme"] {
			try Data().write(to: rootDecoy.appendingPathComponent(name))
		}

		XCTAssertNotEqual(bundle.bundleURL.standardizedFileURL, Bundle.main.bundleURL.standardizedFileURL)
		XCTAssertNotEqual(bundle.bundleURL.standardizedFileURL, Bundle(for: Self.self).bundleURL.standardizedFileURL)
		for decoy in try FileManager.default.contentsOfDirectory(at: rootDecoy, includingPropertiesForKeys: nil) {
			XCTAssertFalse(decoy.isContained(in: bundle), "root decoy must not satisfy inventory: \(decoy.lastPathComponent)")
		}

		let themes = [
			"Appanoose", "Biblioteca", "Hyperlegible", "NewsFax",
			"Promenade", "Sepia", "Tiqoe Dark", "Verdana Revival"
		]
		for theme in themes {
			let themeURL = try XCTUnwrap(
				resourceURL(theme, extension: "nnwtheme", in: bundle.bundleURL, developmentLocalization: developmentLocalization),
				theme
			)
			XCTAssertTrue(themeURL.isContained(in: bundle), theme)
			for child in ["Info.plist", "template.html", "stylesheet.css"] {
				XCTAssertTrue(FileManager.default.fileExists(atPath: themeURL.appendingPathComponent(child).path), "\(theme)/\(child)")
			}
		}

		for storyboard in ["Account", "Add", "Main", "Inspector", "Settings", "LaunchScreenPad", "LaunchScreenPhone"] {
			assertResource(storyboard, extension: "storyboardc", in: bundle, developmentLocalization: developmentLocalization)
		}
		for nib in ["AddFeedSelectFolderTableViewCell", "SettingsComboTableViewCell", "SettingsTableViewCell"] {
			assertResource(nib, extension: "nib", in: bundle, developmentLocalization: developmentLocalization)
		}
		for resource in [
			("Assets", "car"),
			("page", "html"), ("blank", "html"), ("main_ios", "js"), ("article_highlights", "js"),
			("template", "html"), ("core", "css"), ("stylesheet", "css"),
			("main", "js"), ("newsfoot", "js"), ("ContentRules", "json"),
			("DefaultFeeds", "opml"), ("GlobalKeyboardShortcuts", "plist"),
			("SidebarKeyboardShortcuts", "plist"), ("TimelineKeyboardShortcuts", "plist"),
			("DetailKeyboardShortcuts", "plist")
		] {
			assertResource(resource.0, extension: resource.1, in: bundle, developmentLocalization: developmentLocalization)
		}

		for color in [
			"barBackgroundColor", "controlBackgroundColor", "deleteBackgroundColor",
			"fullScreenBackgroundColor", "iconBackgroundColor", "primaryAccentColor",
			"secondaryAccentColor", "sectionHeaderColor", "starColor", "vibrantTextColor"
		] {
			XCTAssertNotNil(UIColor(named: color, in: bundle, compatibleWith: nil), color)
		}
		for image in [
			"accountBazQux", "accountCloudKit", "accountFeedbin", "accountFeedly", "accountFreshRSS",
			"accountInoreader", "accountLocalPad", "accountLocalPhone", "accountNewsBlur",
			"accountTheOldReader", "disclosure", "faviconTemplateImage", "markAllAsRead", "nnwFeedIcon"
		] {
			XCTAssertNotNil(UIImage(named: image, in: bundle, compatibleWith: nil), image)
		}

		let localizationRoot = bundle.bundleURL
			.appendingPathComponent("\(developmentLocalization).lproj", isDirectory: true)
		for table in ["Localizable.strings", "DefaultAccountNames.strings"] {
			let localizationURL = localizationRoot.appendingPathComponent(table)
			XCTAssertTrue(FileManager.default.fileExists(atPath: localizationURL.path), table)
			XCTAssertTrue(localizationURL.isContained(in: bundle), table)
		}
	}

	func testMarkAllAsReadAccessorLoadsFromConfiguredFeatureBundle() {
		let image = Assets.Images.markAllAsRead

		XCTAssertGreaterThan(image.size.width, 0)
		XCTAssertGreaterThan(image.size.height, 0)
	}

	func testUnrelatedLocalizationAndSplitTablesDoNotSatisfyResourcePolicy() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
			.appendingPathExtension("bundle")
		defer { try? FileManager.default.removeItem(at: root) }
		for localization in ["en", "fr"] {
			try FileManager.default.createDirectory(
				at: root.appendingPathComponent("\(localization).lproj", isDirectory: true),
				withIntermediateDirectories: true
			)
		}
		let info: [String: Any] = [
			"CFBundleIdentifier": "com.ryanmccool.NetNewsWireFeatureResourceFixture",
			"CFBundleDevelopmentRegion": "en",
			"CFBundleLocalizations": ["en", "fr"],
			"CFBundlePackageType": "BNDL"
		]
		let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
		try infoData.write(to: root.appendingPathComponent("Info.plist"))
		try Data().write(to: root.appendingPathComponent("fr.lproj/page.html"))
		try Data().write(to: root.appendingPathComponent("root.html"))
		try FileManager.default.createDirectory(
			at: root.appendingPathComponent("Base.lproj", isDirectory: true),
			withIntermediateDirectories: true
		)
		try Data().write(to: root.appendingPathComponent("Base.lproj/base.html"))
		try Data().write(to: root.appendingPathComponent("en.lproj/development.html"))
		try Data().write(to: root.appendingPathComponent("en.lproj/Localizable.strings"))
		try Data().write(to: root.appendingPathComponent("fr.lproj/DefaultAccountNames.strings"))

		let bundle = try XCTUnwrap(Bundle(url: root))
		let developmentLocalization = try XCTUnwrap(
			bundle.infoDictionary?["CFBundleDevelopmentRegion"] as? String
		)
		XCTAssertNotNil(resourceURL("root", extension: "html", in: root, developmentLocalization: developmentLocalization))
		XCTAssertNotNil(resourceURL("base", extension: "html", in: root, developmentLocalization: developmentLocalization))
		XCTAssertNotNil(resourceURL("development", extension: "html", in: root, developmentLocalization: developmentLocalization))
		XCTAssertNil(resourceURL("page", extension: "html", in: root, developmentLocalization: developmentLocalization))
		XCTAssertFalse(hasDevelopmentLocalizationTables(in: root, developmentLocalization: developmentLocalization))
	}

	private func assertResource(
		_ name: String,
		extension resourceExtension: String,
		in bundle: Bundle,
		developmentLocalization: String
	) {
		let url = resourceURL(
			name,
			extension: resourceExtension,
			in: bundle.bundleURL,
			developmentLocalization: developmentLocalization
		)
		XCTAssertNotNil(url, "\(name).\(resourceExtension)")
		if let url {
			XCTAssertTrue(url.isContained(in: bundle), "\(name).\(resourceExtension)")
		}
	}

	private func resourceURL(
		_ name: String,
		extension resourceExtension: String,
		in root: URL,
		developmentLocalization: String
	) -> URL? {
		let filename = "\(name).\(resourceExtension)"
		return [root, root.appendingPathComponent("Base.lproj"), root.appendingPathComponent("\(developmentLocalization).lproj")]
			.map { $0.appendingPathComponent(filename) }
			.first { FileManager.default.fileExists(atPath: $0.path) }
	}

	private func hasDevelopmentLocalizationTables(in root: URL, developmentLocalization: String) -> Bool {
		let localizationRoot = root.appendingPathComponent("\(developmentLocalization).lproj", isDirectory: true)
		return ["Localizable.strings", "DefaultAccountNames.strings"].allSatisfy {
			FileManager.default.fileExists(atPath: localizationRoot.appendingPathComponent($0).path)
		}
	}
}

private extension URL {
	func isContained(in bundle: Bundle) -> Bool {
		standardizedFileURL.path.hasPrefix(bundle.bundleURL.standardizedFileURL.path + "/")
	}
}
