import XCTest
@testable import NetNewsWireFeature

final class ArticleHighlightModelTests: XCTestCase {
	func testArticleIdentityUsesStableVersionedLengthPrefixedHash() throws {
		let key = try XCTUnwrap(ArticleHighlightIdentity.articleKey(
			feedURL: "https://example.com/feed",
			uniqueID: "article-1"
		))

		XCTAssertEqual(
			key,
			"nnw-feed-article:v1:2d5ac9a6fdc4bae9a7ce28b788004987fe80fbd790bbaa5f7849d99af531c62f"
		)
		XCTAssertEqual(
			ArticleHighlightIdentity.articleKey(
				feedURL: "https://example.com/feed",
				uniqueID: "article-1"
			),
			key
		)
		XCTAssertNotNil(key.range(
			of: #"^nnw-feed-article:v1:[0-9a-f]{64}$"#,
			options: .regularExpression
		))
	}

	func testArticleIdentityChangesForEitherExactInput() {
		let original = ArticleHighlightIdentity.articleKey(
			feedURL: "https://example.com/feed",
			uniqueID: "article-1"
		)

		XCTAssertNotEqual(
			original,
			ArticleHighlightIdentity.articleKey(
				feedURL: "https://example.com/feed/",
				uniqueID: "article-1"
			)
		)
		XCTAssertNotEqual(
			original,
			ArticleHighlightIdentity.articleKey(
				feedURL: "https://example.com/feed",
				uniqueID: "article-2"
			)
		)
	}

	func testArticleIdentityRejectsMissingOrBlankInputs() {
		XCTAssertNil(ArticleHighlightIdentity.articleKey(feedURL: nil, uniqueID: "article"))
		XCTAssertNil(ArticleHighlightIdentity.articleKey(feedURL: "feed", uniqueID: nil))
		XCTAssertNil(ArticleHighlightIdentity.articleKey(feedURL: "", uniqueID: "article"))
		XCTAssertNil(ArticleHighlightIdentity.articleKey(feedURL: " \n\t", uniqueID: "article"))
		XCTAssertNil(ArticleHighlightIdentity.articleKey(feedURL: "feed", uniqueID: ""))
		XCTAssertNil(ArticleHighlightIdentity.articleKey(feedURL: "feed", uniqueID: " \n\t"))
	}

	func testQuotationOrdersResolvedRecordsByOffsetBeforeUnresolvedRecords() throws {
		let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
		let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
		let unresolvedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
		let records = [
			makeRecord(id: unresolvedID, selectedText: "Unresolved", createdAt: Date(timeIntervalSince1970: 0)),
			makeRecord(id: secondID, selectedText: "Second", createdAt: Date(timeIntervalSince1970: 20)),
			makeRecord(id: firstID, selectedText: "First", createdAt: Date(timeIntervalSince1970: 30))
		]

		let quotation = ArticleHighlightMarkdown.quotation(
			records: records,
			resolvedOffsets: [firstID: 5, secondID: 10]
		)

		XCTAssertEqual(quotation, "First\n\nSecond\n\nUnresolved")
	}

	func testQuotationUsesCreationThenUUIDForEqualOrUnresolvedOffsets() throws {
		let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
		let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
		let thirdID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
		let records = [
			makeRecord(id: thirdID, selectedText: "Third", createdAt: Date(timeIntervalSince1970: 20)),
			makeRecord(id: secondID, selectedText: "Second", createdAt: Date(timeIntervalSince1970: 10)),
			makeRecord(id: firstID, selectedText: "First", createdAt: Date(timeIntervalSince1970: 10))
		]

		XCTAssertEqual(
			ArticleHighlightMarkdown.quotation(records: records, resolvedOffsets: [:]),
			"First\n\nSecond\n\nThird"
		)
		XCTAssertEqual(
			ArticleHighlightMarkdown.quotation(
				records: records,
				resolvedOffsets: [firstID: 4, secondID: 4, thirdID: 4]
			),
			"First\n\nSecond\n\nThird"
		)
	}

	func testQuotationTrimsSelectionsDropsBlanksAndJoinsWithOneBlankLine() throws {
		let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
		let blankID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
		let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
		let records = [
			makeRecord(id: firstID, selectedText: " \n First selection \t"),
			makeRecord(id: blankID, selectedText: " \n\t "),
			makeRecord(id: secondID, selectedText: "Second selection\n")
		]

		XCTAssertEqual(
			ArticleHighlightMarkdown.quotation(records: records, resolvedOffsets: [:]),
			"First selection\n\nSecond selection"
		)
		XCTAssertNil(ArticleHighlightMarkdown.quotation(
			records: [makeRecord(selectedText: " \n\t ")],
			resolvedOffsets: [:]
		))
	}

	func testRichTextUsesMarkdownOrderAndRetainsPlainFallbackForUnresolvedFragments() throws {
		let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
		let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
		let records = [
			makeRecord(id: secondID, selectedText: "Second", createdAt: Date(timeIntervalSince1970: 20)),
			makeRecord(id: firstID, selectedText: "First", createdAt: Date(timeIntervalSince1970: 30))
		]
		let rich = NetNewsWireHighlightRichText(
			id: firstID,
			selectedText: "First",
			html: "First <a href=\"/first\">link</a>",
			baseURL: URL(string: "https://example.com/article")
		)

		let fragments = ArticleHighlightMarkdown.richText(
			records: records,
			resolvedOffsets: [firstID: 5, secondID: 10],
			resolvedRichText: [firstID: rich]
		)

		XCTAssertEqual(fragments.map(\.id), [firstID, secondID])
		XCTAssertEqual(fragments.map(\.selectedText), ["First", "Second"])
		XCTAssertEqual(fragments.first?.html, rich.html)
		XCTAssertNil(fragments.last?.html)
	}

	func testRenderStateAcceptsOnlyMatchingGenerationArticleAndRendition() {
		let state = ArticleHighlightRenderState(
			generation: 7,
			articleKey: "article-key",
			rendition: .feedBody
		)

		XCTAssertEqual(state.rendition.rawValue, "v1:feed-body")
		XCTAssertEqual(ArticleHighlightRenderState.Rendition.readerView.rawValue, "v1:reader-view")
		XCTAssertTrue(state.accepts(
			generation: 7,
			articleKey: "article-key",
			rendition: .feedBody
		))
		XCTAssertFalse(state.accepts(
			generation: 8,
			articleKey: "article-key",
			rendition: .feedBody
		))
		XCTAssertFalse(state.accepts(
			generation: 7,
			articleKey: "other-article",
			rendition: .feedBody
		))
		XCTAssertFalse(state.accepts(
			generation: 7,
			articleKey: "article-key",
			rendition: .readerView
		))
	}

	private func makeRecord(
		id: UUID = UUID(),
		selectedText: String,
		createdAt: Date = Date(timeIntervalSince1970: 0)
	) -> NetNewsWireHighlightRecord {
		NetNewsWireHighlightRecord(
			id: id, articleKey: "article", selectedText: selectedText,
			prefixContext: "", suffixContext: "", startOffset: 0, endOffset: 0,
			domRangeData: nil, renditionKindRaw: "v1:feed-body",
			renderedTextFingerprint: "fingerprint", articleTitle: "Article",
			creator: nil, preferredURL: nil, createdAt: createdAt, updatedAt: createdAt
		)
	}
}
