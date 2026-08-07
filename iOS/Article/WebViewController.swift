//
//  WebViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 12/28/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
@preconcurrency import WebKit
import RSCore
import RSWeb
import Account
import Articles
import SafariServices
import MessageUI
import Images

enum ArticleHighlightSelectionEligibility {
	static func isEligible(enabled: Bool, articleKey: String?, selectedText: String, overlapsSavedHighlight: Bool) -> Bool {
		enabled && articleKey != nil
			&& !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& !overlapsSavedHighlight
	}
}

@MainActor final class ArticleHighlightLifecycle {
	private weak var webView: WKWebView?
	private(set) var currentState: ArticleHighlightRenderState?
	private(set) var generation: UInt64 = 0
	var selectionIsEligible = false
	var observation: NetNewsWireHighlightObservation?

	@discardableResult
	func beginRender(
		webView: WKWebView,
		articleKey: String?,
		rendition: ArticleHighlightRenderState.Rendition
	) -> ArticleHighlightRenderState? {
		observation?.cancel()
		observation = nil
		selectionIsEligible = false
		generation &+= 1
		self.webView = webView
		currentState = articleKey.map {
			ArticleHighlightRenderState(generation: generation, articleKey: $0, rendition: rendition)
		}
		return currentState
	}

	func accepts(webView: WKWebView, state: ArticleHighlightRenderState?) -> Bool {
		guard let state else {
			return false
		}
		return self.webView === webView && currentState == state
	}

	func accepts(webView: WKWebView, generation: UInt64) -> Bool {
		self.webView === webView && currentState?.generation == generation
	}
}

@MainActor enum ArticleHighlightMutation {
	static func insertBeforeDecoration(
		insert: () async throws -> Void,
		decorate: () async -> Void
	) async throws {
		try await insert()
		await decorate()
	}

	static func deleteBeforeRemoval(
		isCurrent: () -> Bool,
		delete: () async throws -> Void,
		remove: () async -> Void
	) async throws {
		guard isCurrent() else { return }
		try await delete()
		guard isCurrent() else { return }
		await remove()
	}
}

struct ArticleHighlightInsertionKey: Hashable {
	let articleKey: String
	let renditionKindRaw: String
	let selectedText: String
	let startOffset: Int
	let endOffset: Int
	let renderedTextFingerprint: String
}

@MainActor final class ArticleHighlightInsertionGate {
	private var reserved = Set<ArticleHighlightInsertionKey>()

	func reserve(_ key: ArticleHighlightInsertionKey) -> Bool {
		reserved.insert(key).inserted
	}

	func release(_ key: ArticleHighlightInsertionKey) {
		reserved.remove(key)
	}
}

struct ArticleHighlightMessageRenderState {
	let state: ArticleHighlightRenderState

	init?(body: Any) {
		guard let body = body as? [String: Any],
			let generation = Self.uint64(body["generation"]),
			let articleKey = body["articleKey"] as? String,
			!articleKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			let renditionRaw = body["rendition"] as? String,
			let rendition = ArticleHighlightRenderState.Rendition(rawValue: renditionRaw) else { return nil }
		state = ArticleHighlightRenderState(
			generation: generation, articleKey: articleKey, rendition: rendition
		)
	}

	private static func uint64(_ value: Any?) -> UInt64? {
		if let value = value as? UInt64 { return value }
		if let value = value as? Int, value >= 0 { return UInt64(value) }
		if let value = value as? NSNumber, value.int64Value >= 0 { return value.uint64Value }
		return nil
	}
}

struct ArticleHighlightTapMessage {
	let id: UUID
	let renderState: ArticleHighlightRenderState
	let rect: CGRect

	init?(body: Any) {
		guard let body = body as? [String: Any],
			let idString = body["id"] as? String,
			let id = UUID(uuidString: idString),
			let messageState = ArticleHighlightMessageRenderState(body: body) else {
			return nil
		}
		let rect = body["rect"] as? [String: Any]
		self.id = id
		self.renderState = messageState.state
		self.rect = CGRect(
			x: Self.double(rect?["x"]), y: Self.double(rect?["y"]),
			width: Self.double(rect?["width"]), height: Self.double(rect?["height"])
		)
	}

	private static func double(_ value: Any?) -> Double {
		(value as? NSNumber)?.doubleValue ?? 0
	}
}

struct ArticleHighlightRemovalRequest {
	let id: UUID
	let renderState: ArticleHighlightRenderState

	func performIfCurrent(
		isCurrent: (ArticleHighlightRenderState) -> Bool,
		perform: (UUID, ArticleHighlightRenderState) -> Void
	) {
		guard isCurrent(renderState) else { return }
		perform(id, renderState)
	}
}

@MainActor protocol WebViewControllerDelegate: AnyObject {
	func webViewController(_: WebViewController, articleExtractorButtonStateDidUpdate: ArticleExtractorButtonState)
}

final class WebViewController: UIViewController {

	private struct MessageName {
		static let imageWasClicked = "imageWasClicked"
		static let imageWasShown = "imageWasShown"
		static let showFeedInspector = "showFeedInspector"
		static let highlightSelectionChanged = "highlightSelectionChanged"
		static let highlightSelectionCompleted = "highlightSelectionCompleted"
		static let highlightWasTapped = "highlightWasTapped"

		static let all = [
			imageWasClicked, imageWasShown, showFeedInspector, highlightSelectionChanged,
			highlightSelectionCompleted, highlightWasTapped
		]
	}

	private var topShowBarsView: UIView!
	private var bottomShowBarsView: UIView!
	private var topShowBarsViewConstraint: NSLayoutConstraint!
	private var bottomShowBarsViewConstraint: NSLayoutConstraint!

	private var webView: PreloadedWebView? {
		return view.subviews[0] as? PreloadedWebView
	}

	private lazy var contextMenuInteraction = UIContextMenuInteraction(delegate: self)
	private var isFullScreenAvailable: Bool {
		return AppDefaults.shared.articleFullscreenAvailable && traitCollection.userInterfaceIdiom == .phone
	}
	private lazy var articleIconSchemeHandler = ArticleIconSchemeHandler(coordinator: coordinator)
	private lazy var transition = ImageTransition(controller: self)
	private var clickedImageCompletion: (() -> Void)?
	private let highlightLifecycle = ArticleHighlightLifecycle()
	private let highlightInsertionGate = ArticleHighlightInsertionGate()
	private var highlightRecords = [UUID: NetNewsWireHighlightRecord]()
	private weak var highlightNavigation: WKNavigation?
	private var articleRenderGeneration: UInt64 = 0
	private var completedArticleRenderGeneration: UInt64?
	private var highlightRenderTask: Task<Void, Never>?
	private var highlightMutationTask: Task<Void, Never>?

	private var articleExtractor: ArticleExtractor?
	var extractedArticle: ExtractedArticle? {
		didSet {
			windowScrollY = 0
		}
	}
	var isShowingExtractedArticle = false {
		didSet {
			if AppDefaults.shared.isShowingExtractedArticle != isShowingExtractedArticle {
				AppDefaults.shared.isShowingExtractedArticle = isShowingExtractedArticle
			}
		}
	}

	var articleExtractorButtonState: ArticleExtractorButtonState = .off {
		didSet {
			delegate?.webViewController(self, articleExtractorButtonStateDidUpdate: articleExtractorButtonState)
		}
	}

	weak var coordinator: SceneCoordinator!
	weak var delegate: WebViewControllerDelegate?
	let highlightActions: NetNewsWireHighlightActions

	init(highlightActions: NetNewsWireHighlightActions) {
		self.highlightActions = highlightActions
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("WebViewController does not support storyboard construction.")
	}

	private(set) var article: Article?

	let scrollPositionQueue = CoalescingQueue(name: "Article Scroll Position", interval: 0.3, maxInterval: 0.3)
	var windowScrollY = 0 {
		didSet {
			if windowScrollY != AppDefaults.shared.articleWindowScrollY {
				AppDefaults.shared.articleWindowScrollY = windowScrollY
			}
		}
	}
	private var restoreWindowScrollY: Int?

	override func viewDidLoad() {
		super.viewDidLoad()

		NotificationCenter.default.addObserver(self, selector: #selector(feedIconDidBecomeAvailable(_:)), name: .feedIconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(avatarDidBecomeAvailable(_:)), name: .AvatarDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(faviconDidBecomeAvailable(_:)), name: .FaviconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(currentArticleThemeDidChangeNotification(_:)), name: .CurrentArticleThemeDidChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(currentArticleThemeDidChangeNotification(_:)), name: .netNewsWireFeatureAppearanceDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleSceneDidEnterBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)

		// Configure the tap zones
		configureTopShowBarsView()
		configureBottomShowBarsView()

		loadWebView()
	}

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		if isFullScreenAvailable && AppDefaults.shared.logicalArticleFullscreenEnabled {
			updateBottomSafeAreaForFullScreen()
		}
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		// Pause in-flight media before the view goes away. Leaving a video playing during
		// dismissal lets WebKit's full-screen entry continuation fire on a stale view
		// hierarchy and trip a RELEASE_ASSERT in WebFullScreenManagerProxy on iOS 26.
		stopWebViewActivity()
	}

	// MARK: Notifications

	@objc func handleSceneDidEnterBackground(_ notification: Notification) {
		// The share sheet is a popover on iPad. Opening the article in another browser
		// from it backgrounds NetNewsWire mid-presentation, orphaning the popover so it
		// can't be dismissed by tapping outside on return. Dismiss it on backgrounding. (#4269)
		if presentedViewController is UIActivityViewController {
			dismiss(animated: false)
		}
	}

	@objc func feedIconDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	@objc func avatarDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	@objc func faviconDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	@objc func currentArticleThemeDidChangeNotification(_ note: Notification) {
		applyFeatureAppearance()
		loadWebView()
	}

	// MARK: Actions

	@objc func showBars(_ sender: Any) {
		showBars()
	}

	// MARK: API

	func setArticle(_ article: Article?, updateView: Bool = true) {
		stopArticleExtractor()

		if article != self.article {
			self.article = article
			if updateView {
				if article?.feed?.readerViewAlwaysEnabled == true {
					startArticleExtractor()
				}
				windowScrollY = 0
				loadWebView()
			}
		}
	}

	func setScrollPosition(isShowingExtractedArticle: Bool, articleWindowScrollY: Int) {
		if isShowingExtractedArticle {
			switch articleExtractor?.state {
			case .ready:
				restoreWindowScrollY = articleWindowScrollY
				startArticleExtractor()
			case .complete:
				windowScrollY = articleWindowScrollY
				loadWebView()
			case .processing:
				restoreWindowScrollY = articleWindowScrollY
			default:
				restoreWindowScrollY = articleWindowScrollY
				startArticleExtractor()
			}
		} else {
			windowScrollY = articleWindowScrollY
			loadWebView()
		}
	}

	func focus() {
		webView?.becomeFirstResponder()
	}

	func selectedPlainText() async -> String? {
		guard let value = try? await webView?.evaluateJavaScript("window.getSelection().toString()"),
			let text = value as? String else { return nil }
		return Self.normalizedSelectedPlainText(text)
	}

	/// Captures only the rendered article container, along with the base URL used by the
	/// document at render time. Callers must perform their article/web-view identity checks.
	var currentRenderGeneration: UInt64? { articleRenderGeneration == 0 ? nil : articleRenderGeneration }

	func acceptsRender(generation: UInt64) -> Bool {
		guard let webView, let state = highlightLifecycle.currentState else { return false }
		return articleRenderGeneration == generation && state.generation == generation && highlightLifecycle.accepts(webView: webView, state: state)
	}

	var isRenderComplete: Bool { completedArticleRenderGeneration == articleRenderGeneration }

	func renderedArticleContainer(generation: UInt64) async -> (html: String, baseURL: URL)? {
		guard let webView, acceptsRender(generation: generation), isRenderComplete,
			let value = try? await webView.evaluateJavaScript("(() => { const article = document.querySelector('article'); return article ? { html: article.outerHTML, baseURL: document.baseURI } : null; })()"),
			let result = value as? [String: Any],
			let html = result["html"] as? String,
			let baseString = result["baseURL"] as? String,
			let baseURL = URL(string: baseString),
			acceptsRender(generation: generation),
			!html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return nil
		}
		return (html, baseURL)
	}

	func highlightRecordsForPosting() async -> ([NetNewsWireHighlightRecord], [UUID: Int]) {
		let records = sortedHighlightRecords()
		guard let webView, let state = highlightLifecycle.currentState,
			highlightLifecycle.accepts(webView: webView, state: state),
			let value = try? await webView.evaluateJavaScript("window.nnwHighlights.positions()"),
			highlightLifecycle.accepts(webView: webView, state: state) else {
			return (records, [:])
		}
		return (records, highlightPositions(from: value))
	}

	static func normalizedSelectedPlainText(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	func canScrollDown() -> Bool {
		guard let webView = webView else { return false }
		return webView.scrollView.contentOffset.y < finalScrollPosition(scrollingUp: false)
	}

	func canScrollUp() -> Bool {
		guard let webView = webView else { return false }
		return webView.scrollView.contentOffset.y > finalScrollPosition(scrollingUp: true)
	}

	private func scrollPage(up scrollingUp: Bool) {
		guard let webView, let windowScene = webView.window?.windowScene else {
			return
		}

		let overlap = 2 * UIFont.systemFont(ofSize: UIFont.systemFontSize).lineHeight * windowScene.screen.scale
		let scrollToY: CGFloat = {
			let scrollDistance = webView.scrollView.layoutMarginsGuide.layoutFrame.height - overlap
			let fullScroll = webView.scrollView.contentOffset.y + (scrollingUp ? -scrollDistance : scrollDistance)
			let final = finalScrollPosition(scrollingUp: scrollingUp)
			return (scrollingUp ? fullScroll > final : fullScroll < final) ? fullScroll : final
		}()

		let convertedPoint = self.view.convert(CGPoint(x: 0, y: 0), to: webView.scrollView)
		let scrollToPoint = CGPoint(x: convertedPoint.x, y: scrollToY)
		webView.scrollView.setContentOffset(scrollToPoint, animated: true)
	}

	func scrollPageDown() {
		scrollPage(up: false)
	}

	func scrollPageUp() {
		scrollPage(up: true)
	}

	func hideClickedImage() {
		webView?.evaluateJavaScript("hideClickedImage();")
	}

	func showClickedImage(completion: @escaping () -> Void) {
		clickedImageCompletion = completion
		webView?.evaluateJavaScript("showClickedImage();")
	}

	func fullReload() {
		loadWebView(replaceExistingWebView: true)
	}

	func showBars(animated: Bool = true) {
		AppDefaults.shared.articleFullscreenEnabled = false
		coordinator.showStatusBar()
		topShowBarsViewConstraint?.constant = 0
		bottomShowBarsViewConstraint?.constant = 0
		navigationController?.setNavigationBarHidden(false, animated: animated)
		navigationController?.setToolbarHidden(false, animated: animated)
		additionalSafeAreaInsets.bottom = 0
		setBottomScrollEdgeEffectHidden(false)
		updateTopScrollEdgeEffectForFeatureAppearance()
		configureContextMenuInteraction()
	}

	func hideBars() {
		if isFullScreenAvailable {
			AppDefaults.shared.articleFullscreenEnabled = true
			coordinator.hideStatusBar()
			topShowBarsViewConstraint?.constant = -44.0
			bottomShowBarsViewConstraint?.constant = 44.0
			navigationController?.setNavigationBarHidden(true, animated: true)
			navigationController?.setToolbarHidden(true, animated: true)
			setBottomScrollEdgeEffectHidden(true)
			configureContextMenuInteraction()
		}
	}

	func toggleArticleExtractor() {

		guard let article = article else {
			return
		}

		guard articleExtractor?.state != .processing else {
			stopArticleExtractor()
			loadWebView()
			return
		}

		guard !isShowingExtractedArticle else {
			isShowingExtractedArticle = false
			loadWebView()
			articleExtractorButtonState = .off
			return
		}

		if let articleExtractor = articleExtractor {
			if article.preferredLink == articleExtractor.articleLink {
				isShowingExtractedArticle = true
				loadWebView()
				articleExtractorButtonState = .on
			}
		} else {
			startArticleExtractor()
		}

	}

	func stopArticleExtractorIfProcessing() {
		if articleExtractor?.state == .processing {
			stopArticleExtractor()
		}
	}

	func stopWebViewActivity() {
		if let webView = webView {
			stopMediaPlayback(webView)
			cancelImageLoad(webView)
		}
	}

	func showActivityDialog(popOverBarButtonItem: UIBarButtonItem? = nil) {
		guard let url = article?.preferredURL else { return }
		let activityViewController = UIActivityViewController(url: url, title: article?.title, applicationActivities: [FindInArticleActivity(), OpenInBrowserActivity()])
		activityViewController.popoverPresentationController?.barButtonItem = popOverBarButtonItem
		present(activityViewController, animated: true)
	}

	func openInAppBrowser() {
		guard let url = article?.preferredURL else { return }
		if AppDefaults.shared.useSystemBrowser {
			UIApplication.shared.open(url, options: [:])
		} else {
			openURLInSafariViewController(url)
		}
	}
}

// MARK: ArticleExtractorDelegate

extension WebViewController: ArticleExtractorDelegate {

	func articleExtractionDidFail(with: Error) {
		stopArticleExtractor()
		articleExtractorButtonState = .error
		loadWebView()
	}

	func articleExtractionDidComplete(extractedArticle: ExtractedArticle) {
		if articleExtractor?.state != .cancelled {
			self.extractedArticle = extractedArticle
			if let restoreWindowScrollY = restoreWindowScrollY {
				windowScrollY = restoreWindowScrollY
			}
			isShowingExtractedArticle = true
			loadWebView()
			articleExtractorButtonState = .on
		}
	}

}

// MARK: UIContextMenuInteractionDelegate

extension WebViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {

		return UIContextMenuConfiguration(identifier: nil, previewProvider: contextMenuPreviewProvider) { [weak self] _ in
			guard let self = self else { return nil }

			var menus = [UIMenu]()

			var navActions = [UIAction]()
			if let action = self.prevArticleAction() {
				navActions.append(action)
			}
			if let action = self.nextArticleAction() {
				navActions.append(action)
			}
			if !navActions.isEmpty {
				menus.append(UIMenu(title: "", options: .displayInline, children: navActions))
			}

			var toggleActions = [UIAction]()
			if let action = self.toggleReadAction() {
				toggleActions.append(action)
			}
			toggleActions.append(self.toggleStarredAction())
			menus.append(UIMenu(title: "", options: .displayInline, children: toggleActions))

			if let action = self.nextUnreadArticleAction() {
				menus.append(UIMenu(title: "", options: .displayInline, children: [action]))
			}

			menus.append(UIMenu(title: "", options: .displayInline, children: [self.toggleArticleExtractorAction()]))
			menus.append(UIMenu(title: "", options: .displayInline, children: [self.shareAction()]))

			return UIMenu(title: "", children: menus)
        }
    }

	func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
		coordinator.showBrowserForCurrentArticle()
	}

}

// MARK: WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		if let webView = webView as? PreloadedWebView,
			self.webView === webView, navigation === highlightNavigation {
			completedArticleRenderGeneration = articleRenderGeneration
		}
		if let webView = webView as? PreloadedWebView,
			self.webView === webView, navigation === highlightNavigation,
			let state = highlightLifecycle.currentState,
			highlightLifecycle.accepts(webView: webView, state: state) {
			highlightRenderTask?.cancel()
			highlightRenderTask = Task { [weak self, weak webView] in
				guard let self, let webView else { return }
				await self.prepareAndRestoreHighlights(in: webView, state: state)
			}
		}
		for (index, view) in view.subviews.enumerated() {
			if index != 0, let oldWebView = view as? PreloadedWebView {
				detachHighlightHandlers(from: oldWebView)
				oldWebView.navigationDelegate = nil
				oldWebView.uiDelegate = nil
				oldWebView.scrollView.delegate = nil
				oldWebView.removeFromSuperview()
			}
		}
	}

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {

		if navigationAction.navigationType == .linkActivated {
			guard let url = navigationAction.request.url else {
				decisionHandler(.allow)
				return
			}

			let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
			if components?.scheme == "http" || components?.scheme == "https" {
				decisionHandler(.cancel)
				if AppDefaults.shared.useSystemBrowser {
					UIApplication.shared.open(url, options: [:])
				} else {
					UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { didOpen in
						guard didOpen == false else {
							return
						}
						self.openURLInSafariViewController(url)
					}
				}

			} else if components?.scheme == "mailto" {
				decisionHandler(.cancel)

				guard let emailAddress = url.percentEncodedEmailAddress else {
					return
				}

				if UIApplication.shared.canOpenURL(emailAddress) {
					UIApplication.shared.open(emailAddress, options: [.universalLinksOnly: false], completionHandler: nil)
				} else {
					let alert = UIAlertController(title: NNWLocalizedString("Error", comment: "Error"), message: NNWLocalizedString("This device cannot send emails.", comment: "This device cannot send emails."), preferredStyle: .alert)
					alert.addAction(.init(title: NNWLocalizedString("Dismiss", comment: "Dismiss"), style: .cancel, handler: nil))
					self.present(alert, animated: true, completion: nil)
				}
			} else if components?.scheme == "tel" {
				decisionHandler(.cancel)

				if UIApplication.shared.canOpenURL(url) {
					UIApplication.shared.open(url, options: [.universalLinksOnly: false], completionHandler: nil)
				}

			} else {
				decisionHandler(.allow)
			}
		} else {
			decisionHandler(.allow)
		}
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		fullReload()
	}

}

// MARK: WKUIDelegate

extension WebViewController: WKUIDelegate {

	func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo, willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
		// We need to have at least an unimplemented WKUIDelegate assigned to the WKWebView.  This makes the
		// link preview launch Safari when the link preview is tapped.  In theory, you should be able to get
		// the link from the elementInfo above and transition to SFSafariViewController instead of launching
		// Safari.  As the time of this writing, the link in elementInfo is always nil.  ¯\_(ツ)_/¯
	}

	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		guard let url = navigationAction.request.url else {
			return nil
		}

		openURL(url)
		return nil
	}

}

// MARK: WKScriptMessageHandler

extension WebViewController: WKScriptMessageHandler {

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		switch message.name {
		case MessageName.imageWasShown:
			clickedImageCompletion?()
		case MessageName.imageWasClicked:
			imageWasClicked(body: message.body as? String)
		case MessageName.showFeedInspector:
			if let feed = article?.feed {
				coordinator.showFeedInspector(for: feed)
			}
		case MessageName.highlightSelectionChanged:
			if let webView = message.webView {
				highlightSelectionChanged(in: webView, body: message.body)
			}
		case MessageName.highlightSelectionCompleted:
			if let webView = message.webView {
				highlightSelectionCompleted(in: webView, body: message.body)
			}
		case MessageName.highlightWasTapped:
			if let webView = message.webView {
				highlightWasTapped(in: webView, body: message.body)
			}
		default:
			return
		}
	}

}

// MARK: PreloadedWebViewHighlightDelegate

extension WebViewController: PreloadedWebViewHighlightDelegate {
	func preloadedWebViewCanHighlightCurrentSelection(_ webView: PreloadedWebView) -> Bool {
		highlightActions.isEnabled && highlightLifecycle.selectionIsEligible
			&& highlightLifecycle.accepts(webView: webView, state: highlightLifecycle.currentState)
	}

	func preloadedWebViewDidRequestHighlight(_ webView: PreloadedWebView) {
		guard preloadedWebViewCanHighlightCurrentSelection(webView) else { return }
		addHighlight(from: webView)
	}
}

// MARK: UIViewControllerTransitioningDelegate

extension WebViewController: UIViewControllerTransitioningDelegate {

	func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
		transition.presenting = true
		return transition
	}

	func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
		transition.presenting = false
		return transition
	}
}

// MARK:

extension WebViewController: UIScrollViewDelegate {

	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		scrollPositionQueue.add(self, #selector(scrollPositionDidChange))
	}

	@objc func scrollPositionDidChange() {
		webView?.evaluateJavaScript("window.scrollY") { (scrollY, error) in
			guard error == nil else { return }
			let javascriptScrollY = scrollY as? Int ?? 0
			// I don't know why this value gets returned sometimes, but it is in error
			guard javascriptScrollY != 33554432 else { return }
			self.windowScrollY = javascriptScrollY
		}
	}
}

// MARK: JSON

private struct ImageClickMessage: Codable {
	let x: Float
	let y: Float
	let width: Float
	let height: Float
	let imageTitle: String?
	let imageURL: String
}

private struct ArticleHighlightAnchor {
	let selectedText: String
	let prefixContext: String
	let suffixContext: String
	let startOffset: Int
	let endOffset: Int
	let domRangeData: Data?
	let renditionKindRaw: String
	let renderedTextFingerprint: String

	init?(value: Any) {
		guard let value = value as? [String: Any],
			let selectedText = value["selectedText"] as? String,
			!selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			let prefixContext = value["prefixContext"] as? String,
			let suffixContext = value["suffixContext"] as? String,
			let startOffset = (value["startOffset"] as? NSNumber)?.intValue,
			let endOffset = (value["endOffset"] as? NSNumber)?.intValue,
			startOffset >= 0, endOffset > startOffset,
			let renditionKindRaw = value["renditionKindRaw"] as? String,
			let renderedTextFingerprint = value["renderedTextFingerprint"] as? String,
			!renderedTextFingerprint.isEmpty else { return nil }
		self.selectedText = selectedText
		self.prefixContext = prefixContext
		self.suffixContext = suffixContext
		self.startOffset = startOffset
		self.endOffset = endOffset
		self.renditionKindRaw = renditionKindRaw
		self.renderedTextFingerprint = renderedTextFingerprint
		if let domRange = value["domRangeData"], JSONSerialization.isValidJSONObject(domRange) {
			self.domRangeData = try? JSONSerialization.data(withJSONObject: domRange)
		} else {
			self.domRangeData = nil
		}
	}
}

// MARK: Private

private extension WebViewController {

	func applyFeatureAppearance() {
		applyFeatureAppearance(to: webView)
	}

	func applyFeatureAppearance(to webView: PreloadedWebView?) {
		NetNewsWireFeatureTheme.applyArticleDetailBackground(
			to: view,
			webView,
			webView?.scrollView
		)
		webView?.isOpaque = NetNewsWireFeatureTheme.appearance == nil
	}

	func loadWebView(replaceExistingWebView: Bool = false) {
		guard isViewLoaded else { return }

		if !replaceExistingWebView, let webView = webView {
			self.renderPage(webView)
			return
		}

		coordinator.webViewProvider.dequeueWebView { webView in

			webView.ready {

				// Add the webview
				webView.translatesAutoresizingMaskIntoConstraints = false
				self.view.insertSubview(webView, at: 0)
				NSLayoutConstraint.activate([
					self.view.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
					self.view.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
					self.view.topAnchor.constraint(equalTo: webView.topAnchor),
					self.view.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
				])

				// UISplitViewController reports the wrong size to WKWebView which can cause horizontal
				// rubberbanding on the iPad.  This interferes with our UIPageViewController preventing
				// us from easily swiping between WKWebViews.  This hack fixes that.
				webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: -1, bottom: 0, right: 0)

				webView.scrollView.setZoomScale(1.0, animated: false)

				self.view.setNeedsLayout()
				self.view.layoutIfNeeded()

				// Configure the webview
				webView.navigationDelegate = self
				webView.uiDelegate = self
				webView.scrollView.delegate = self
				self.configureContextMenuInteraction()

				// Remove possible existing message handlers
				for name in MessageName.all {
					webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
				}

				// Add handlers
				for name in MessageName.all {
					webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: name)
				}
				webView.setHighlightDelegate(self)

				self.renderPage(webView)
			}
		}
	}

	func renderPage(_ webView: PreloadedWebView?) {
		applyFeatureAppearance(to: webView)

		guard let webView = webView else { return }

		let theme = ArticleThemesManager.shared.currentTheme
		let rendering: ArticleRenderer.Rendering

		if let articleExtractor = articleExtractor, articleExtractor.state == .processing {
			rendering = ArticleRenderer.loadingHTML(theme: theme)
		} else if let articleExtractor = articleExtractor, articleExtractor.state == .failedToParse, let article = article {
			rendering = ArticleRenderer.articleHTML(article: article, theme: theme)
		} else if let article = article, let extractedArticle = extractedArticle {
			if isShowingExtractedArticle {
				rendering = ArticleRenderer.articleHTML(article: article, extractedArticle: extractedArticle, theme: theme)
			} else {
				rendering = ArticleRenderer.articleHTML(article: article, theme: theme)
			}
		} else if let article = article {
			rendering = ArticleRenderer.articleHTML(article: article, theme: theme)
		} else {
			rendering = ArticleRenderer.noSelectionHTML(theme: theme)
		}

		let substitutions = [
			"title": rendering.title,
			"baseURL": rendering.baseURL,
			"style": rendering.style,
			"body": rendering.html,
			"windowScrollY": String(windowScrollY)
		]

		var html = try! MacroProcessor.renderedText(withTemplate: ArticleRenderer.page.html, substitutions: substitutions)
		html = ArticleRenderingSpecialCases.filterHTMLIfNeeded(baseURL: rendering.baseURL, html: html)

		// Uncomment when you want to debug HTML and CSS for an article.
		// If you’re running in the simulator, this will write the file to a location on your Mac.
//		let debugFolderURL = AppConfig.dataSubfolder(named: "debug")
//		let fileURL = debugFolderURL.appendingPathComponent("article.html")
//		try? html.write(to: fileURL, atomically: true, encoding: .utf8)
//		print("article.html written to \(fileURL.path)")

		WebViewConfiguration.addContentBlockingRules(to: webView)
		articleRenderGeneration &+= 1
		completedArticleRenderGeneration = nil
		let articleKey = ArticleHighlightIdentity.articleKey(feedURL: article?.feed?.url, uniqueID: article?.uniqueID)
		let rendition: ArticleHighlightRenderState.Rendition = isShowingExtractedArticle ? .readerView : .feedBody
		invalidateHighlightRender(in: webView, articleKey: articleKey, rendition: rendition)
		highlightNavigation = webView.loadHTMLString(html, baseURL: URL(string: rendering.baseURL))
	}

	func invalidateHighlightRender(
		in webView: PreloadedWebView,
		articleKey: String?,
		rendition: ArticleHighlightRenderState.Rendition
	) {
		highlightRenderTask?.cancel()
		highlightRenderTask = nil
		highlightMutationTask?.cancel()
		highlightMutationTask = nil
		highlightRecords = [:]
		webView.updateHighlightSelectionEligibility(false)
		_ = highlightLifecycle.beginRender(webView: webView, articleKey: articleKey, rendition: rendition)
	}

	func detachHighlightHandlers(from webView: PreloadedWebView) {
		webView.setHighlightDelegate(nil)
		for name in MessageName.all {
			webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
		}
	}

	func prepareAndRestoreHighlights(in webView: PreloadedWebView, state: ArticleHighlightRenderState) async {
		guard highlightLifecycle.accepts(webView: webView, state: state) else { return }
		let prepareScript = "window.nnwHighlights.prepare(\(state.generation), \(ArticleHighlightJavaScriptJSON.encode(state.rendition.rawValue) ?? "null"), \(ArticleHighlightJavaScriptJSON.encode(state.articleKey) ?? "null"))"
		guard let prepared = try? await webView.evaluateJavaScript(prepareScript) as? Bool, prepared,
			highlightLifecycle.accepts(webView: webView, state: state), !Task.isCancelled else { return }

		guard let records = try? await highlightActions.load(state.articleKey),
			highlightLifecycle.accepts(webView: webView, state: state), !Task.isCancelled else { return }
		highlightRecords = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
		await restoreHighlights(in: webView, state: state)
		guard highlightLifecycle.accepts(webView: webView, state: state), !Task.isCancelled else { return }
		startHighlightObservation(in: webView, state: state)
	}

	func startHighlightObservation(in webView: PreloadedWebView, state: ArticleHighlightRenderState) {
		highlightLifecycle.observation?.cancel()
		highlightLifecycle.observation = highlightActions.observe(state.articleKey) { [weak self, weak webView] records in
			guard let self, let webView, self.highlightLifecycle.accepts(webView: webView, state: state) else { return }
			self.highlightRecords = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
			self.enqueueHighlightRestore(in: webView, state: state)
		} _: {
			// The app bridge owns sanitized feedback; existing marks remain readable.
		}
	}

	func restoreHighlights(in webView: PreloadedWebView, state: ArticleHighlightRenderState) async {
		guard highlightLifecycle.accepts(webView: webView, state: state) else { return }
		let records = sortedHighlightRecords().map(highlightRecordJSON)
		_ = try? await ArticleHighlightJavaScriptBridge.restore(records, in: webView)
		guard highlightLifecycle.accepts(webView: webView, state: state), !Task.isCancelled else { return }
		webView.updateHighlightSelectionEligibility(false)
		highlightLifecycle.selectionIsEligible = false
	}

	@discardableResult
	func enqueueHighlightRestore(in webView: PreloadedWebView, state: ArticleHighlightRenderState) -> Task<Void, Never> {
		let previousTask = highlightRenderTask
		let task = Task { [weak self, weak webView] in
			await previousTask?.value
			guard let self, let webView,
				self.highlightLifecycle.accepts(webView: webView, state: state), !Task.isCancelled else { return }
			await self.restoreHighlights(in: webView, state: state)
		}
		highlightRenderTask = task
		return task
	}

	func highlightSelectionChanged(in messageWebView: WKWebView, body: Any) {
		guard let webView = messageWebView as? PreloadedWebView,
			let body = body as? [String: Any],
			let messageState = ArticleHighlightMessageRenderState(body: body),
			highlightLifecycle.accepts(webView: webView, state: messageState.state) else { return }
		let selectedText = body["selectedText"] as? String ?? ""
		let overlap = body["overlapsSavedHighlight"] as? Bool ?? true
		let eligible = ArticleHighlightSelectionEligibility.isEligible(
			enabled: highlightActions.isEnabled,
			articleKey: highlightLifecycle.currentState?.articleKey,
			selectedText: selectedText,
			overlapsSavedHighlight: overlap
		)
		highlightLifecycle.selectionIsEligible = eligible
		webView.updateHighlightSelectionEligibility(eligible)
	}

	func highlightSelectionCompleted(in messageWebView: WKWebView, body: Any) {
		guard let webView = messageWebView as? PreloadedWebView,
			let body = body as? [String: Any],
			let messageState = ArticleHighlightMessageRenderState(body: body),
			highlightLifecycle.accepts(webView: webView, state: messageState.state),
			let anchorValue = body["anchor"],
			let anchor = ArticleHighlightAnchor(value: anchorValue),
			anchor.renditionKindRaw == messageState.state.rendition.rawValue else { return }
		addHighlight(anchor: anchor, from: webView, state: messageState.state)
	}

	func highlightWasTapped(in messageWebView: WKWebView, body: Any) {
		guard let webView = messageWebView as? PreloadedWebView,
			let message = ArticleHighlightTapMessage(body: body),
			highlightLifecycle.accepts(webView: webView, state: message.renderState),
			highlightRecords[message.id] != nil else { return }
		let request = ArticleHighlightRemovalRequest(id: message.id, renderState: message.renderState)

		let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
		alert.addAction(UIAlertAction(
			title: NNWLocalizedString("Remove Highlight", comment: "Remove saved article highlight"),
			style: .destructive
		) { [weak self, weak webView] _ in
			guard let self, let webView else { return }
			request.performIfCurrent(isCurrent: { state in
				self.highlightLifecycle.accepts(webView: webView, state: state)
			}) { id, state in
				self.removeHighlight(id, from: webView, state: state)
			}
		})
		alert.addAction(UIAlertAction(title: NNWLocalizedString("Cancel", comment: "Cancel button"), style: .cancel))
		if let popover = alert.popoverPresentationController {
			popover.sourceView = webView
			let sourceRect = message.rect.intersection(webView.bounds)
			popover.sourceRect = sourceRect.isNull || sourceRect.isEmpty
				? CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
				: sourceRect
		}
		present(alert, animated: true)
	}

	func addHighlight(from webView: PreloadedWebView) {
		guard let state = highlightLifecycle.currentState,
			highlightLifecycle.accepts(webView: webView, state: state),
			let article else { return }
		let articleTitle = article.title ?? ""
		let byline = article.byline().trimmingCharacters(in: .whitespacesAndNewlines)
		let creator = byline.isEmpty ? article.feed?.nameForDisplay : byline
		let preferredURL = article.preferredURL

		highlightMutationTask?.cancel()
		highlightMutationTask = Task { [weak self, weak webView] in
			guard let self, let webView,
				self.highlightLifecycle.accepts(webView: webView, state: state) else { return }
			_ = try? await webView.evaluateJavaScript(
				"window.nnwHighlights.cancelSelectionCompletion()"
			)
			guard self.highlightLifecycle.accepts(webView: webView, state: state),
				let value = try? await ArticleHighlightJavaScriptBridge.makeSelectionAnchor(in: webView),
				self.highlightLifecycle.accepts(webView: webView, state: state), !Task.isCancelled,
				let anchor = ArticleHighlightAnchor(value: value),
				anchor.renditionKindRaw == state.rendition.rawValue else { return }
			await self.persistHighlight(
				anchor, from: webView, state: state, articleTitle: articleTitle,
				creator: creator, preferredURL: preferredURL
			)
		}
	}

	func addHighlight(
		anchor: ArticleHighlightAnchor,
		from webView: PreloadedWebView,
		state: ArticleHighlightRenderState
	) {
		guard highlightActions.isEnabled,
			highlightLifecycle.accepts(webView: webView, state: state),
			let article else { return }
		let articleTitle = article.title ?? ""
		let byline = article.byline().trimmingCharacters(in: .whitespacesAndNewlines)
		let creator = byline.isEmpty ? article.feed?.nameForDisplay : byline
		let preferredURL = article.preferredURL

		highlightMutationTask?.cancel()
		highlightMutationTask = Task { [weak self, weak webView] in
			guard let self, let webView else { return }
			await self.persistHighlight(
				anchor, from: webView, state: state, articleTitle: articleTitle,
				creator: creator, preferredURL: preferredURL
			)
		}
	}

	func persistHighlight(
		_ anchor: ArticleHighlightAnchor,
		from webView: PreloadedWebView,
		state: ArticleHighlightRenderState,
		articleTitle: String,
		creator: String?,
		preferredURL: URL?
	) async {
		guard highlightActions.isEnabled,
			highlightLifecycle.accepts(webView: webView, state: state),
			!Task.isCancelled,
			anchor.renditionKindRaw == state.rendition.rawValue,
			!hasHighlight(matching: anchor) else { return }
		let insertionKey = ArticleHighlightInsertionKey(
			articleKey: state.articleKey, renditionKindRaw: anchor.renditionKindRaw,
			selectedText: anchor.selectedText, startOffset: anchor.startOffset,
			endOffset: anchor.endOffset, renderedTextFingerprint: anchor.renderedTextFingerprint
		)
		guard highlightInsertionGate.reserve(insertionKey) else { return }
		defer { highlightInsertionGate.release(insertionKey) }

		let now = Date()
		let record = NetNewsWireHighlightRecord(
			id: UUID(), articleKey: state.articleKey, selectedText: anchor.selectedText,
			prefixContext: anchor.prefixContext, suffixContext: anchor.suffixContext,
			startOffset: anchor.startOffset, endOffset: anchor.endOffset,
			domRangeData: anchor.domRangeData, renditionKindRaw: anchor.renditionKindRaw,
			renderedTextFingerprint: anchor.renderedTextFingerprint,
			articleTitle: articleTitle, creator: creator, preferredURL: preferredURL,
			createdAt: now, updatedAt: now
		)
		do {
			try await ArticleHighlightMutation.insertBeforeDecoration {
				try await self.highlightActions.insert(record)
			} decorate: {
				guard self.highlightLifecycle.accepts(webView: webView, state: state), !Task.isCancelled else { return }
				self.highlightRecords[record.id] = record
				await self.enqueueHighlightRestore(in: webView, state: state).value
			}
		} catch {
			// The app bridge reports sanitized feedback. Do not expose persistence errors here.
		}
	}

	func hasHighlight(matching anchor: ArticleHighlightAnchor) -> Bool {
		highlightRecords.values.contains {
			$0.selectedText == anchor.selectedText
				&& $0.startOffset == anchor.startOffset
				&& $0.endOffset == anchor.endOffset
				&& $0.renditionKindRaw == anchor.renditionKindRaw
				&& $0.renderedTextFingerprint == anchor.renderedTextFingerprint
		}
	}

	func removeHighlight(_ id: UUID, from webView: PreloadedWebView, state: ArticleHighlightRenderState) {
		guard highlightLifecycle.accepts(webView: webView, state: state) else { return }
		highlightMutationTask?.cancel()
		highlightMutationTask = Task { [weak self, weak webView] in
			guard let self, let webView else { return }
			do {
				try await ArticleHighlightMutation.deleteBeforeRemoval(isCurrent: {
					self.highlightLifecycle.accepts(webView: webView, state: state) && !Task.isCancelled
				}) {
					try await self.highlightActions.delete(id)
				} remove: {
					self.highlightRecords[id] = nil
					let idJSON = ArticleHighlightJavaScriptJSON.encode(id.uuidString.lowercased()) ?? "null"
					_ = try? await webView.evaluateJavaScript("window.nnwHighlights.remove(\(idJSON))")
				}
			} catch {
				// Keep the mark in place when deletion fails; feedback is owned by the app bridge.
			}
		}
	}

	func sortedHighlightRecords() -> [NetNewsWireHighlightRecord] {
		highlightRecords.values.sorted {
			$0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
		}
	}

	func highlightRecordJSON(_ record: NetNewsWireHighlightRecord) -> [String: Any] {
		var value: [String: Any] = [
			"id": record.id.uuidString.lowercased(), "selectedText": record.selectedText,
			"prefixContext": record.prefixContext, "suffixContext": record.suffixContext,
			"startOffset": record.startOffset, "endOffset": record.endOffset,
			"renditionKindRaw": record.renditionKindRaw,
			"renderedTextFingerprint": record.renderedTextFingerprint,
			"createdAt": record.createdAt.timeIntervalSince1970
		]
		if let data = record.domRangeData,
			let domRange = try? JSONSerialization.jsonObject(with: data) {
			value["domRangeData"] = domRange
		}
		return value
	}

	func highlightPositions(from value: Any) -> [UUID: Int] {
		guard let values = value as? [[String: Any]] else { return [:] }
		return Dictionary(uniqueKeysWithValues: values.compactMap { position in
			guard let idString = position["id"] as? String, let id = UUID(uuidString: idString),
				let offset = (position["startOffset"] as? NSNumber)?.intValue else { return nil }
			return (id, offset)
		})
	}

	func finalScrollPosition(scrollingUp: Bool) -> CGFloat {
		guard let webView = webView else { return 0 }

		if scrollingUp {
			return -webView.scrollView.safeAreaInsets.top
		} else {
			return webView.scrollView.contentSize.height - webView.scrollView.bounds.height + webView.scrollView.safeAreaInsets.bottom
		}
	}

	func startArticleExtractor() {
		guard articleExtractor == nil else { return }
		if let link = article?.preferredLink, let extractor = ArticleExtractor(link, delegate: self) {
			extractor.process()
			articleExtractor = extractor
			articleExtractorButtonState = .animated
		}
	}

	func stopArticleExtractor() {
		articleExtractor?.cancel()
		articleExtractor = nil
		isShowingExtractedArticle = false
		articleExtractorButtonState = .off
	}

	func reloadArticleImage() {
		guard let article = article else { return }

		var components = URLComponents()
		components.scheme = ArticleRenderer.imageIconScheme
		components.path = article.articleID

		if let imageSrc = components.string {
			webView?.evaluateJavaScript("reloadArticleImage(\"\(imageSrc)\")")
		}
	}

	func imageWasClicked(body: String?) {
		guard let webView, let body else { return }

		let data = Data(body.utf8)
		guard let clickMessage = try? JSONDecoder().decode(ImageClickMessage.self, from: data) else {
			return
		}

		guard let imageURL = URL(string: clickMessage.imageURL) else { return }

		Downloader.shared.download(imageURL) { [weak self] downloadResponse, error in
			guard let self, let data = downloadResponse.data, error == nil, !data.isEmpty,
				  let image = UIImage(data: data) else {
				return
			}
			self.showFullScreenImage(image: image, clickMessage: clickMessage, webView: webView)
		}
	}

	private func showFullScreenImage(image: UIImage, clickMessage: ImageClickMessage, webView: WKWebView) {

		let y = CGFloat(clickMessage.y) + webView.safeAreaInsets.top
		let rect = CGRect(x: CGFloat(clickMessage.x), y: y, width: CGFloat(clickMessage.width), height: CGFloat(clickMessage.height))
		transition.originFrame = webView.convert(rect, to: nil)

		if navigationController?.navigationBar.isHidden ?? false {
			transition.maskFrame = webView.convert(webView.frame, to: nil)
		} else {
			transition.maskFrame = webView.convert(webView.safeAreaLayoutGuide.layoutFrame, to: nil)
		}

		transition.originImage = image

		coordinator.showFullScreenImage(image: image, imageTitle: clickMessage.imageTitle, transitioningDelegate: self)
	}

	func stopMediaPlayback(_ webView: WKWebView) {
		webView.evaluateJavaScript("stopMediaPlayback();")
	}

	func cancelImageLoad(_ webView: WKWebView) {
		webView.evaluateJavaScript("cancelImageLoad();")
	}

	func configureTopShowBarsView() {
		topShowBarsView = UIView()
		topShowBarsView.backgroundColor = .clear
		topShowBarsView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(topShowBarsView)

		if AppDefaults.shared.logicalArticleFullscreenEnabled {
			topShowBarsViewConstraint = view.topAnchor.constraint(equalTo: topShowBarsView.bottomAnchor, constant: -44.0)
		} else {
			topShowBarsViewConstraint = view.topAnchor.constraint(equalTo: topShowBarsView.bottomAnchor, constant: 0.0)
		}

		NSLayoutConstraint.activate([
			topShowBarsViewConstraint,
			view.leadingAnchor.constraint(equalTo: topShowBarsView.leadingAnchor),
			view.trailingAnchor.constraint(equalTo: topShowBarsView.trailingAnchor),
			topShowBarsView.heightAnchor.constraint(equalToConstant: 44.0)
		])
		topShowBarsView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showBars(_:))))
	}

	func configureBottomShowBarsView() {
		bottomShowBarsView = UIView()
		bottomShowBarsView.backgroundColor = .clear
		bottomShowBarsView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(bottomShowBarsView)
		if AppDefaults.shared.logicalArticleFullscreenEnabled {
			bottomShowBarsViewConstraint = view.bottomAnchor.constraint(equalTo: bottomShowBarsView.topAnchor, constant: 44.0)
		} else {
			bottomShowBarsViewConstraint = view.bottomAnchor.constraint(equalTo: bottomShowBarsView.topAnchor, constant: 0.0)
		}
		NSLayoutConstraint.activate([
			bottomShowBarsViewConstraint,
			view.leadingAnchor.constraint(equalTo: bottomShowBarsView.leadingAnchor),
			view.trailingAnchor.constraint(equalTo: bottomShowBarsView.trailingAnchor),
			bottomShowBarsView.heightAnchor.constraint(equalToConstant: 44.0)
		])
		bottomShowBarsView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showBars(_:))))
	}

	func updateBottomSafeAreaForFullScreen() {
		let rawBottom = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
		additionalSafeAreaInsets.bottom = -rawBottom
	}

	/// Hide or show the toolbar scroll edge effect at the bottom of the web view.
	///
	/// Hidden when entering fullscreen so a residual effect doesn't obscure the
	/// bottom of the article.
	///
	/// <https://github.com/Ranchero-Software/NetNewsWire/issues/5298>
	func setBottomScrollEdgeEffectHidden(_ hidden: Bool) {
		guard #available(iOS 26, *) else {
			return
		}
		guard let scrollView = webView?.scrollView else {
			return
		}
		scrollView.bottomEdgeEffect.isHidden = hidden
	}

	func updateTopScrollEdgeEffectForFeatureAppearance() {
		NetNewsWireFeatureTheme.updateTopScrollEdgeEffect(for: webView?.scrollView)
	}

	func configureContextMenuInteraction() {
		if isFullScreenAvailable {
			if navigationController?.isNavigationBarHidden ?? false {
				webView?.addInteraction(contextMenuInteraction)
			} else {
				webView?.removeInteraction(contextMenuInteraction)
			}
		}
	}

	func contextMenuPreviewProvider() -> UIViewController {
		let previewProvider = UIStoryboard.main.instantiateController(ofType: ContextMenuPreviewViewController.self)
		previewProvider.article = article
		return previewProvider
	}

	func prevArticleAction() -> UIAction? {
		guard coordinator.isPrevArticleAvailable else { return nil }
		let title = NNWLocalizedString("Previous Article", comment: "Previous Article")
		return UIAction(title: title, image: Assets.Images.prevArticle) { [weak self] _ in
			self?.coordinator.selectPrevArticle()
		}
	}

	func nextArticleAction() -> UIAction? {
		guard coordinator.isNextArticleAvailable else { return nil }
		let title = NNWLocalizedString("Next Article", comment: "Next Article")
		return UIAction(title: title, image: Assets.Images.nextArticle) { [weak self] _ in
			self?.coordinator.selectNextArticle()
		}
	}

	func toggleReadAction() -> UIAction? {
		guard let article = article, !article.status.read || article.isAvailableToMarkUnread else { return nil }

		let title = article.status.read ? NNWLocalizedString("Mark as Unread", comment: "Command") : NNWLocalizedString("Mark as Read", comment: "Command")
		let readImage = article.status.read ? Assets.Images.circleClosed : Assets.Images.circleOpen
		return UIAction(title: title, image: readImage) { [weak self] _ in
			self?.coordinator.toggleReadForCurrentArticle()
		}
	}

	func toggleStarredAction() -> UIAction {
		let starred = article?.status.starred ?? false
		let title = starred ? NNWLocalizedString("Mark as Unstarred", comment: "Command") : NNWLocalizedString("Mark as Starred", comment: "Command")
		let starredImage = starred ? Assets.Images.starOpen : Assets.Images.starClosed
		return UIAction(title: title, image: starredImage) { [weak self] _ in
			self?.coordinator.toggleStarredForCurrentArticle()
		}
	}

	func nextUnreadArticleAction() -> UIAction? {
		guard coordinator.isNextUnreadAvailable else { return nil }
		let title = NNWLocalizedString("Next Unread Article", comment: "Next Unread Article")
		return UIAction(title: title, image: Assets.Images.nextUnread) { [weak self] _ in
			self?.coordinator.selectNextUnread()
		}
	}

	func toggleArticleExtractorAction() -> UIAction {
		let extracted = articleExtractorButtonState == .on
		let title = extracted ? NNWLocalizedString("Show Feed Article", comment: "Show Feed Article") : NNWLocalizedString("Show Reader View", comment: "Show Reader View")
		let extractorImage = extracted ? Assets.Images.articleExtractorOff : Assets.Images.articleExtractorOn
		return UIAction(title: title, image: extractorImage) { [weak self] _ in
			self?.toggleArticleExtractor()
		}
	}

	func shareAction() -> UIAction {
		let title = NNWLocalizedString("Share", comment: "Share button")
		return UIAction(title: title, image: Assets.Images.share) { [weak self] _ in
			self?.showActivityDialog()
		}
	}

	// If the resource cannot be opened with an installed app, present the web view.
	func openURL(_ url: URL) {
		UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { didOpen in
			assert(Thread.isMainThread)
			guard didOpen == false else {
				return
			}
			self.openURLInSafariViewController(url)
		}
	}

	func openURLInSafariViewController(_ url: URL) {
		guard let viewController = SFSafariViewController.safeSafariViewController(url) else {
			return
		}
		present(viewController, animated: true)
	}
}

// MARK: Find in Article

private struct FindInArticleOptions: Codable {
	var text: String
	var caseSensitive = false
	var regex = false
}

internal struct FindInArticleState: Codable {
	struct WebViewClientRect: Codable {
		let x: Double
		let y: Double
		let width: Double
		let height: Double
	}

	struct FindInArticleResult: Codable {
		let rects: [WebViewClientRect]
		let bounds: WebViewClientRect
		let index: UInt
		let matchGroups: [String]
	}

	let index: UInt?
	let results: [FindInArticleResult]
	let count: UInt
}

extension WebViewController {

	func searchText(_ searchText: String, completionHandler: @escaping (FindInArticleState) -> Void) {
		guard let json = try? JSONEncoder().encode(FindInArticleOptions(text: searchText)) else {
			return
		}
		let encoded = json.base64EncodedString()

		webView?.evaluateJavaScript("updateFind(\"\(encoded)\")") { (result, error) in
			guard error == nil,
				let b64 = result as? String,
				let rawData = Data(base64Encoded: b64),
				let findState = try? JSONDecoder().decode(FindInArticleState.self, from: rawData) else {
					return
			}

			completionHandler(findState)
		}
	}

	func endSearch() {
		webView?.evaluateJavaScript("endFind()")
	}

	func selectNextSearchResult() {
		webView?.evaluateJavaScript("selectNextResult()")
	}

	func selectPreviousSearchResult() {
		webView?.evaluateJavaScript("selectPreviousResult()")
	}

}
