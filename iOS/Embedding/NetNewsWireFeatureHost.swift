import UIKit

@MainActor
public final class NetNewsWireFeatureHost {
	private let appDelegate: AppDelegate
	public let viewController: UIViewController
	private let rootSplitViewController: RootSplitViewController

	public init() {
		appDelegate = AppDelegate.bootstrapEmbeddedIfNeeded()
		let storyboard = UIStoryboard.main
		let rootSplitViewController = storyboard.instantiateViewController(withIdentifier: "RootSplitViewController") as! RootSplitViewController
		self.rootSplitViewController = rootSplitViewController
		self.viewController = rootSplitViewController
		NetNewsWireSceneSetup.configure(rootSplitViewController: rootSplitViewController, stateRestorationActivity: nil)
	}

	public func sceneWillEnterForeground() {
		appDelegate.resumeIfNecessary()
		appDelegate.prepareAccountsForForeground()
		rootSplitViewController.coordinator.resetFocus()
	}

	public func sceneDidEnterBackground() {
		rootSplitViewController.coordinator.didEnterBackground()
		appDelegate.prepareAccountsForBackground()
		rootSplitViewController.coordinator.suspend()
	}

	public func didReceiveMemoryWarning() {
		appDelegate.applicationDidReceiveMemoryWarning(UIApplication.shared)
	}
}
