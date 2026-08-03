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
		secondHost.publishingActions.send(capture, .postAs(.note))

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

	func testContainedAppearanceResolvesSemanticColorsAndDeduplicatesUpdates() {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }

		let first = makeAppearance(
			style: .dark,
			background: NetNewsWireFeatureColor(red: 0.2, green: 0.4, blue: 0.6)
		)
		NetNewsWireFeatureTheme.update(first)
		let duplicateNotification = expectation(description: "No notification for an unchanged appearance")
		duplicateNotification.isInverted = true
		let duplicateToken = NotificationCenter.default.addObserver(
			forName: .netNewsWireFeatureAppearanceDidChange,
			object: nil,
			queue: nil
		) { _ in
			duplicateNotification.fulfill()
		}

		NetNewsWireFeatureTheme.update(first)
		wait(for: [duplicateNotification], timeout: 0.05)
		NotificationCenter.default.removeObserver(duplicateToken)

		XCTAssertEqual(NetNewsWireFeatureTheme.interfaceStyle, .dark)
		XCTAssertEqual(
			NetNewsWireFeatureTheme.background,
			UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
		)
		XCTAssertTrue(
			NetNewsWireFeatureTheme.articleCSSOverride.contains(
				"--nnw-feature-background: rgba(51, 102, 153, 1.0)"
			)
		)

		let changedNotification = expectation(description: "Notification for a changed appearance")
		let changedToken = NotificationCenter.default.addObserver(
			forName: .netNewsWireFeatureAppearanceDidChange,
			object: nil,
			queue: nil
		) { _ in
			changedNotification.fulfill()
		}
		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .light,
				background: NetNewsWireFeatureColor(red: 0.8, green: 0.7, blue: 0.6)
			)
		)
		wait(for: [changedNotification], timeout: 0.1)
		NotificationCenter.default.removeObserver(changedToken)

		XCTAssertEqual(NetNewsWireFeatureTheme.interfaceStyle, .light)
	}

	func testTimelineAppearanceUsesSemanticSurface() {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		let background = NetNewsWireFeatureColor(red: 0.2, green: 0.3, blue: 0.4)
		NetNewsWireFeatureTheme.update(makeAppearance(style: .dark, background: background))
		let collectionView = UICollectionView(
			frame: .zero,
			collectionViewLayout: UICollectionViewFlowLayout()
		)

		MainTimelineFeatureAppearance.apply(to: collectionView)

		XCTAssertEqual(collectionView.backgroundColor, NetNewsWireFeatureTheme.secondaryBackground)

		NetNewsWireFeatureTheme.update(nil)
		MainTimelineFeatureAppearance.apply(to: collectionView)

		XCTAssertEqual(collectionView.backgroundColor, .systemBackground)
	}

	func testContainedInactiveListBackgroundIsTransparent() {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .dark,
				background: NetNewsWireFeatureColor(red: 0.2, green: 0.3, blue: 0.4)
			)
		)
		var configuration = UIBackgroundConfiguration.listCell()
		configuration.backgroundColor = .systemRed
		configuration.visualEffect = UIBlurEffect(style: .systemMaterial)

		NetNewsWireFeatureTheme.prepareContainedListBackground(&configuration)

		XCTAssertEqual(configuration.backgroundColor, .clear)
		XCTAssertNil(configuration.visualEffect)
	}

	func testTimelineControllerRefreshesSurfaceAfterAppearanceChange() {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		let controller = MainTimelineModernViewController()
		controller.view = UIView()
		let collectionView = UICollectionView(
			frame: .zero,
			collectionViewLayout: UICollectionViewFlowLayout()
		)
		controller.collectionView = collectionView

		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .dark,
				background: NetNewsWireFeatureColor(red: 0.2, green: 0.3, blue: 0.4)
			)
		)
		controller.featureAppearanceDidChange()

		XCTAssertEqual(collectionView.backgroundColor, NetNewsWireFeatureTheme.secondaryBackground)
	}



	func testAppearanceRefreshPreservesMainFeedRefreshControl() throws {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .dark,
				background: NetNewsWireFeatureColor(red: 0.2, green: 0.3, blue: 0.4)
			)
		)
		let controller = try XCTUnwrap(
			UIStoryboard.main.instantiateViewController(
				withIdentifier: "MainFeedCollectionViewController"
			) as? MainFeedCollectionViewController
		)
		controller.loadViewIfNeeded()
		let refreshControl = try XCTUnwrap(controller.collectionView.refreshControl)

		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .light,
				background: NetNewsWireFeatureColor(red: 0.8, green: 0.7, blue: 0.6)
			)
		)

		XCTAssertIdentical(controller.collectionView.refreshControl, refreshControl)
	}

	func testArticleNavigationAppearanceTracksContainment() {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		let containedAppearance = makeAppearance(
			style: .dark,
			background: NetNewsWireFeatureColor(red: 0.2, green: 0.3, blue: 0.4)
		)
		NetNewsWireFeatureTheme.update(containedAppearance)
		let containedBackground = UIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
		XCTAssertEqual(
			ArticleViewController.featureNavigationAppearance().backgroundColor,
			containedBackground
		)
		XCTAssertNil(ArticleViewController.featureNavigationAppearance().backgroundEffect)

		NetNewsWireFeatureTheme.update(nil)
		XCTAssertNotEqual(
			ArticleViewController.featureNavigationAppearance().backgroundColor,
			containedBackground
		)

		NetNewsWireFeatureTheme.update(containedAppearance)
		XCTAssertEqual(
			ArticleViewController.featureNavigationAppearance().backgroundColor,
			containedBackground
		)
	}

	func testArticleSearchBarRestoresStandaloneDefaults() {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		NetNewsWireFeatureTheme.update(nil)
		let container = UIView()
		let searchBar = ArticleSearchBar(frame: .zero)
		container.addSubview(searchBar)

		XCTAssertEqual(searchBar.background.backgroundColor, .systemGray5)
		XCTAssertNil(searchBar.searchField.backgroundColor)

		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .dark,
				background: NetNewsWireFeatureColor(red: 0.2, green: 0.3, blue: 0.4)
			)
		)
		XCTAssertEqual(searchBar.searchField.backgroundColor, NetNewsWireFeatureTheme.elevatedBackground)

		NetNewsWireFeatureTheme.update(nil)
		XCTAssertEqual(searchBar.background.backgroundColor, .systemGray5)
		XCTAssertNil(searchBar.searchField.backgroundColor)
	}

	func testVibrantSelectionUsesSelectedBackgroundContract() {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .dark,
				background: NetNewsWireFeatureColor(red: 0.2, green: 0.3, blue: 0.4)
			)
		)

		let cell = VibrantTableViewCell(style: .default, reuseIdentifier: nil)

		XCTAssertEqual(
			cell.selectedBackgroundView?.backgroundColor,
			NetNewsWireFeatureTheme.selectedBackground
		)
	}

	func testAppearanceRefreshDoesNotLoadDormantChildControllers() {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .dark,
				background: NetNewsWireFeatureColor(red: 0.2, green: 0.3, blue: 0.4)
			)
		)
		let root = RootSplitViewController()
		root.loadViewIfNeeded()
		let dormantChild = UIViewController()
		root.addChild(dormantChild)
		XCTAssertFalse(dormantChild.isViewLoaded)

		root.applyFeatureAppearance(refreshContent: true)

		XCTAssertFalse(dormantChild.isViewLoaded)
	}

	func testContainedArticleRenderingIgnoresIndependentArticleThemeCSS() throws {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .dark,
				background: NetNewsWireFeatureColor(red: 0.1, green: 0.2, blue: 0.3)
			)
		)

		let sepia = try XCTUnwrap(
			ArticleThemesManager.shared.articleThemeWithThemeName("Sepia")
		)
		let rendering = ArticleRenderer.noSelectionHTML(theme: sepia)

		XCTAssertFalse(rendering.style.contains("rgb(248, 241, 227)"))
		XCTAssertTrue(rendering.style.contains("--nnw-feature-background"))
		XCTAssertTrue(
			rendering.style.contains(
				"--primary-accent-color: var(--nnw-feature-tint);"
			)
		)
		XCTAssertTrue(
			rendering.style.contains(
				"--nnw-saved-highlight-background: color-mix("
			)
		)
		XCTAssertTrue(
			rendering.style.contains(
				"background: var(--nnw-feature-surface) !important;"
			)
		)

		NetNewsWireFeatureTheme.update(nil)
		let standaloneRendering = ArticleRenderer.noSelectionHTML(theme: sepia)
		XCTAssertTrue(standaloneRendering.style.contains("rgb(248, 241, 227)"))
	}

	func testContainedSettingsHideIndependentThemeAndPaletteRows() throws {
		let originalAppearance = NetNewsWireFeatureTheme.appearance
		defer { NetNewsWireFeatureTheme.update(originalAppearance) }
		NetNewsWireFeatureTheme.update(
			makeAppearance(
				style: .dark,
				background: NetNewsWireFeatureColor(red: 0.1, green: 0.2, blue: 0.3)
			)
		)

		let runtime = try NetNewsWireFeatureRuntime(
			configuration: makeConfiguration(),
			cloudKitContainerConfigurator: { _ in }
		)
		_ = try runtime.makeHost()

		let controller = UIStoryboard.settings.instantiateController(
			ofType: SettingsViewController.self
		)
		controller.loadViewIfNeeded()

		let standaloneArticleRowCount = UIDevice.current.userInterfaceIdiom == .phone ? 4 : 3
		XCTAssertEqual(
			controller.tableView.numberOfRows(inSection: 4),
			standaloneArticleRowCount - 1
		)
		XCTAssertEqual(controller.tableView.numberOfRows(inSection: 5), 0)
		XCTAssertNil(controller.tableView(controller.tableView, titleForHeaderInSection: 5))
		XCTAssertEqual(
			controller.tableView(controller.tableView, heightForHeaderInSection: 5),
			.leastNormalMagnitude
		)
		XCTAssertEqual(
			controller.tableView(controller.tableView, heightForFooterInSection: 5),
			.leastNormalMagnitude
		)
		let openLinksCell = controller.tableView(
			controller.tableView,
			cellForRowAt: IndexPath(row: 0, section: 4)
		)
		let javaScriptCell = controller.tableView(
			controller.tableView,
			cellForRowAt: IndexPath(row: 1, section: 4)
		)
		XCTAssertTrue(controller.openLinksInNetNewsWire.isDescendant(of: openLinksCell))
		XCTAssertTrue(controller.enableJavaScriptSwitch.isDescendant(of: javaScriptCell))
		if UIDevice.current.userInterfaceIdiom == .phone {
			let fullScreenCell = controller.tableView(
				controller.tableView,
				cellForRowAt: IndexPath(row: 2, section: 4)
			)
			XCTAssertTrue(controller.showFullscreenArticlesSwitch.isDescendant(of: fullScreenCell))
		}

		NetNewsWireFeatureTheme.update(nil)
		let standaloneController = UIStoryboard.settings.instantiateController(
			ofType: SettingsViewController.self
		)
		standaloneController.loadViewIfNeeded()

		XCTAssertEqual(
			standaloneController.tableView.numberOfRows(inSection: 4),
			standaloneArticleRowCount
		)
		XCTAssertGreaterThan(standaloneController.tableView.numberOfRows(inSection: 5), 0)
	}

	private func makeAppearance(
		style: NetNewsWireFeatureAppearance.Style,
		background: NetNewsWireFeatureColor
	) -> NetNewsWireFeatureAppearance {
		let color = NetNewsWireFeatureColor(red: 0.3, green: 0.4, blue: 0.5)
		return NetNewsWireFeatureAppearance(
			style: style,
			background: background,
			secondaryBackground: color,
			elevatedBackground: color,
			primaryText: color,
			secondaryText: color,
			tertiaryText: color,
			tint: color,
			secondaryTint: color,
			tertiaryTint: color,
			separator: color,
			success: color,
			warning: color,
			destructive: color
		)
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
