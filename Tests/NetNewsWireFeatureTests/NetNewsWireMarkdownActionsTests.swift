import XCTest
import UIKit
@testable import NetNewsWireFeature

@MainActor
final class NetNewsWireMarkdownActionsTests: XCTestCase {
	override class func setUp() {
		super.setUp()
		try! NetNewsWireFeatureTestEnvironment.configure()
	}

	func testMarkdownCaptureExportsOnlyPlainMarkdownValues() {
		let url = URL(string: "https://example.com/article")!
		let capture = NetNewsWireMarkdownCapture(
			selectedText: "Selection",
			title: "Article",
			creator: "Author",
			preferredURL: url
		)

		XCTAssertEqual(capture.selectedText, "Selection")
		XCTAssertEqual(capture.title, "Article")
		XCTAssertEqual(capture.creator, "Author")
		XCTAssertEqual(capture.preferredURL, url)
		XCTAssertEqual(Set(Mirror(reflecting: capture).children.compactMap(\.label)), [
			"selectedText", "title", "creator", "preferredURL", "renderedArticleHTML", "renderedArticleBaseURL", "highlightRichText"
		])
		assertSendable(capture)
	}

	func testMarkdownActionsShareCapture() {
		let expectedCapture = NetNewsWireMarkdownCapture(
			selectedText: "Saved highlight",
			title: "Article",
			creator: "Author",
			preferredURL: URL(string: "https://example.com/article")!
		)
		var receivedCapture: NetNewsWireMarkdownCapture?
		let actions = NetNewsWireMarkdownActions(
			shareMarkdown: { receivedCapture = $0 }
		)

		actions.shareMarkdown(expectedCapture)

		XCTAssertEqual(receivedCapture, expectedCapture)
	}

	func testMarkdownSharingUsesRenderedHighlightsWithoutReloadingTheStore() throws {
		let laterID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
		let earlierID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
		let base = NetNewsWireMarkdownCapture(
			selectedText: nil,
			title: "Article",
			creator: "Author",
			preferredURL: URL(string: "https://example.com/article")!
		)

		let capture = NetNewsWireMarkdownSharing.capture(
			base: base,
			renderedHighlights: [
				makeRecord(id: laterID, selectedText: "Later", preferredURL: base.preferredURL),
				makeRecord(id: earlierID, selectedText: "Earlier", preferredURL: base.preferredURL)
			],
			resolvedPositions: [earlierID: 4, laterID: 40]
		)

		XCTAssertEqual(capture.title, base.title)
		XCTAssertEqual(capture.creator, base.creator)
		XCTAssertEqual(capture.preferredURL, base.preferredURL)
		XCTAssertEqual(capture.selectedText, "Earlier\n\nLater")
	}

	func testDisabledMarkdownActionsAreNoOp() {
		let capture = NetNewsWireMarkdownCapture(
			selectedText: nil,
			title: "Article",
			creator: nil,
			preferredURL: URL(string: "https://example.com/article")!
		)

		NetNewsWireMarkdownActions.disabled.shareMarkdown(capture)
	}

	func testMarkdownMenuAccessibilityLabelPreservesDisabledShareLabel() {
		let localize = { (key: String, comment: String) in "\(key)|\(comment)" }

		XCTAssertEqual(NetNewsWireMarkdownMenuText.accessibilityLabel(
			actionsEnabled: false,
			existingLabel: "Share",
			localize: localize
		), "Share")
		XCTAssertEqual(NetNewsWireMarkdownMenuText.accessibilityLabel(
			actionsEnabled: true,
			existingLabel: "Share",
			localize: localize
		), "Markdown sharing|Markdown sharing accessibility label")
	}

	func testMarkdownMenuTitlesUseCommandLocalizationKeys() {
		let titles = NetNewsWireMarkdownMenuText.actionTitles { key, comment in
			"\(key)|\(comment)"
		}

		XCTAssertEqual(titles.shareMarkdown, "Share as Markdown...|Command")
		XCTAssertEqual(titles.shareMarkdownArticle, "Share Full Article as Markdown...|Command")
	}

	func testArticleMenuContainsOnlyNormalAndMarkdownSharingActions() throws {
		let controller = ArticleViewController.instantiate(from: .main, highlightActions: .disabled)
		controller.markdownActions = NetNewsWireMarkdownActions(
			shareMarkdown: { _ in }
		)

		let menu = controller.makeMarkdownMenu()
		let sections = menu.children.compactMap { $0 as? UIMenu }
		XCTAssertEqual(sections.count, 1)
		XCTAssertEqual(
			sections[0].children.compactMap { ($0 as? UIAction)?.title },
			["Share", "Share as Markdown...", "Share Full Article as Markdown..."]
		)
	}

	func testRichMarkdownCaptureCarriesRenderedArticleAndBaseURLThroughShareCallback() throws {
		let baseURL = try XCTUnwrap(URL(string: "https://example.com/article"))
		let capture = NetNewsWireMarkdownCapture(
			selectedText: "highlight",
			title: "Article",
			creator: nil,
			preferredURL: baseURL,
			renderedArticleHTML: "<article><p>Rendered</p></article>",
			renderedArticleBaseURL: baseURL
		)
		var received: NetNewsWireMarkdownCapture?
		let actions = NetNewsWireMarkdownActions(
			shareMarkdown: { received = $0 }
		)

		actions.shareMarkdown(capture)

		XCTAssertEqual(received?.renderedArticleHTML, capture.renderedArticleHTML)
		XCTAssertEqual(received?.renderedArticleBaseURL, baseURL)
	}

	private func assertSendable<T: Sendable>(_ value: T) {}

	private func makeRecord(
		id: UUID,
		selectedText: String,
		preferredURL: URL?
	) -> NetNewsWireHighlightRecord {
		NetNewsWireHighlightRecord(
			id: id,
			articleKey: "article-key",
			selectedText: selectedText,
			prefixContext: "",
			suffixContext: "",
			startOffset: 0,
			endOffset: selectedText.count,
			domRangeData: nil,
			renditionKindRaw: "v1:feed-body",
			renderedTextFingerprint: "fingerprint",
			articleTitle: "Persisted title",
			creator: "Persisted creator",
			preferredURL: preferredURL,
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0)
		)
	}
}
