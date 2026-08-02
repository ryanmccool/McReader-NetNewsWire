import UIKit

@MainActor
public protocol NetNewsWireFeatureHosting: AnyObject {
	var viewController: UIViewController { get }
	func updateAppearance(_ appearance: NetNewsWireFeatureAppearance?)
	func sceneWillEnterForeground()
	func sceneDidEnterBackground()
	func suspend()
}

@MainActor
final class NetNewsWireFeatureApplicationLifecycle {
	private let resumeIfNecessary: () -> Void
	private let prepareAccountsForForeground: () -> Void
	private let prepareAccountsForBackground: () -> Void
	private let didReceiveMemoryWarningCallback: () -> Void

	init(
		resumeIfNecessary: @escaping () -> Void,
		prepareAccountsForForeground: @escaping () -> Void,
		prepareAccountsForBackground: @escaping () -> Void,
		didReceiveMemoryWarning: @escaping () -> Void
	) {
		self.resumeIfNecessary = resumeIfNecessary
		self.prepareAccountsForForeground = prepareAccountsForForeground
		self.prepareAccountsForBackground = prepareAccountsForBackground
		self.didReceiveMemoryWarningCallback = didReceiveMemoryWarning
	}

	func applicationWillEnterForeground() {
		resumeIfNecessary()
		prepareAccountsForForeground()
	}

	func applicationDidEnterBackground() {
		prepareAccountsForBackground()
	}

	func didReceiveMemoryWarning() {
		didReceiveMemoryWarningCallback()
	}
}

@MainActor
final class NetNewsWireFeatureSceneLifecycle {
	private let resetFocus: () -> Void
	private let didEnterBackground: () -> Void
	private let suspendCallback: () -> Void

	init(
		resetFocus: @escaping () -> Void,
		didEnterBackground: @escaping () -> Void,
		suspend: @escaping () -> Void
	) {
		self.resetFocus = resetFocus
		self.didEnterBackground = didEnterBackground
		self.suspendCallback = suspend
	}

	func sceneWillEnterForeground() {
		resetFocus()
	}

	func sceneDidEnterBackground() {
		didEnterBackground()
	}

	func suspend() {
		suspendCallback()
	}
}

@MainActor
public final class NetNewsWireFeatureHost: NetNewsWireFeatureHosting {
	public let viewController: UIViewController
	let publishingActions: NetNewsWirePublishingActions
	let highlightActions: NetNewsWireHighlightActions
	private let lifecycle: NetNewsWireFeatureSceneLifecycle
	private let rootSplitViewController: RootSplitViewController

	internal init(
		capabilities: NetNewsWireFeatureCapabilities,
		globalMutationSeams: NetNewsWireHostGlobalMutationSeams,
		publishingActions: NetNewsWirePublishingActions = .disabled,
		highlightActions: NetNewsWireHighlightActions = .disabled
	) throws {
		_ = AppDelegate.bootstrapEmbeddedIfNeeded(capabilities: capabilities, globalMutationSeams: globalMutationSeams)
		let storyboard = UIStoryboard.main
		guard let rootSplitViewController = storyboard.instantiateViewController(withIdentifier: "RootSplitViewController") as? RootSplitViewController else {
			throw NetNewsWireFeatureConfigurationError.missingRootController
		}
		self.rootSplitViewController = rootSplitViewController
		self.viewController = rootSplitViewController
		self.publishingActions = publishingActions
		self.highlightActions = highlightActions
		self.lifecycle = NetNewsWireFeatureSceneLifecycle(
			resetFocus: { rootSplitViewController.coordinator.resetFocus() },
			didEnterBackground: { rootSplitViewController.coordinator.didEnterBackground() },
			suspend: { rootSplitViewController.coordinator.suspend() }
		)
		NetNewsWireSceneSetup.configure(
			rootSplitViewController: rootSplitViewController,
			stateRestorationActivity: nil,
			capabilities: capabilities,
			publishingActions: publishingActions,
			highlightActions: highlightActions
		)
		rootSplitViewController.applyFeatureAppearance()
	}

	public func updateAppearance(_ appearance: NetNewsWireFeatureAppearance?) {
		NetNewsWireFeatureTheme.update(appearance)
	}

	public func sceneWillEnterForeground() {
		lifecycle.sceneWillEnterForeground()
	}

	public func sceneDidEnterBackground() {
		lifecycle.sceneDidEnterBackground()
	}

	public func suspend() {
		lifecycle.suspend()
	}
}
