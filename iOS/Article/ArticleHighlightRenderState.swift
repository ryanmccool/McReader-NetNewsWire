import Foundation
import WebKit

struct ArticleHighlightRenderState: Equatable, Sendable {
	enum Rendition: String, Sendable {
		case feedBody = "v1:feed-body"
		case readerView = "v1:reader-view"
	}

	let generation: UInt64
	let articleKey: String
	let rendition: Rendition

	func accepts(generation: UInt64, articleKey: String, rendition: Rendition) -> Bool {
		self.generation == generation && self.articleKey == articleKey && self.rendition == rendition
	}
}

enum ArticleHighlightJavaScriptJSON {
	static func encode(_ value: Any) -> String? {
		guard JSONSerialization.isValidJSONObject([value]),
			let data = try? JSONSerialization.data(withJSONObject: [value]),
			var json = String(data: data, encoding: .utf8) else { return nil }
		json.removeFirst()
		json.removeLast()
		return json
	}
}

@MainActor
enum ArticleHighlightJavaScriptBridge {
	static func makeSelectionAnchor(in webView: WKWebView) async throws -> Any? {
		try await webView.callAsyncJavaScript(
			"return await window.nnwHighlights.makeSelectionAnchor()",
			arguments: [:],
			in: nil,
			contentWorld: .page
		)
	}

	static func restore(_ records: [[String: Any]], in webView: WKWebView) async throws -> Any? {
		try await webView.callAsyncJavaScript(
			"return await window.nnwHighlights.restore(records)",
			arguments: ["records": records],
			in: nil,
			contentWorld: .page
		)
	}
}
