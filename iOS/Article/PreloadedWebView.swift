//
//  PreloadedWebView.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 2/25/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import Foundation
import UIKit
import WebKit
import RSCore

@MainActor protocol PreloadedWebViewHighlightDelegate: AnyObject {
	func preloadedWebViewCanHighlightCurrentSelection(_: PreloadedWebView) -> Bool
	func preloadedWebViewDidRequestHighlight(_: PreloadedWebView)
}

final class PreloadedWebView: WKWebView {

	private var isReady: Bool = false
	private var readyCompletion: (() -> Void)?
	private weak var highlightDelegate: PreloadedWebViewHighlightDelegate?
	private(set) var cachedHighlightSelectionEligibility = false
	var hasHighlightDelegate: Bool { highlightDelegate != nil }

	init(articleIconSchemeHandler: ArticleIconSchemeHandler) {
		let configuration = WebViewConfiguration.configuration(with: articleIconSchemeHandler)
		super.init(frame: .zero, configuration: configuration)
		observeUserDefaults()
	}

	override init(frame: CGRect, configuration: WKWebViewConfiguration) {
		super.init(frame: frame, configuration: configuration)
		observeUserDefaults()
	}

	private func observeUserDefaults() {
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?.userDefaultsDidChange()
			}
		}
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)

	}

	func preload() {
		navigationDelegate = self
		loadFileURL(ArticleRenderer.blank.url, allowingReadAccessTo: ArticleRenderer.blank.baseURL)
	}

	func ready(completion: @escaping () -> Void) {
		if isReady {
			completeRequest(completion: completion)
		} else {
			readyCompletion = completion
		}
	}

	func userDefaultsDidChange() {
		if configuration.defaultWebpagePreferences.allowsContentJavaScript != AppDefaults.shared.isArticleContentJavascriptEnabled {
			configuration.defaultWebpagePreferences.allowsContentJavaScript = AppDefaults.shared.isArticleContentJavascriptEnabled
			reload()
		}
	}

	func setHighlightDelegate(_ delegate: PreloadedWebViewHighlightDelegate?) {
		highlightDelegate = delegate
		cachedHighlightSelectionEligibility = false
	}

	func updateHighlightSelectionEligibility(_ isEligible: Bool) {
		cachedHighlightSelectionEligibility = isEligible
	}

	override func buildMenu(with builder: any UIMenuBuilder) {
		super.buildMenu(with: builder)
		let command = UICommand(
			title: NNWLocalizedString("Highlight", comment: "Article selection command"),
			action: #selector(highlightCurrentSelection(_:))
		)
		builder.insertSibling(UIMenu(options: .displayInline, children: [command]), afterMenu: .standardEdit)
	}

	override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
		if action == #selector(highlightCurrentSelection(_:)) {
			return cachedHighlightSelectionEligibility
				&& highlightDelegate?.preloadedWebViewCanHighlightCurrentSelection(self) == true
		}
		return super.canPerformAction(action, withSender: sender)
	}

	@objc private func highlightCurrentSelection(_ sender: Any?) {
		guard canPerformAction(#selector(highlightCurrentSelection(_:)), withSender: sender) else {
			return
		}
		highlightDelegate?.preloadedWebViewDidRequestHighlight(self)
	}
}

// MARK: WKScriptMessageHandler

extension PreloadedWebView: WKNavigationDelegate {

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		isReady = true
		if let completion = readyCompletion {
			completeRequest(completion: completion)
			readyCompletion = nil
		}
	}
}

// MARK: Private

private extension PreloadedWebView {

	func completeRequest(completion: @escaping () -> Void) {
		isReady = false
		navigationDelegate = nil
		completion()
	}
}
