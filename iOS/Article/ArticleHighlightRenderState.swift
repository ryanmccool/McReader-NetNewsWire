import Foundation

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
