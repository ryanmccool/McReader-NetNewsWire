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
