import XCTest
import UIKit
@testable import NetNewsWireFeature

@MainActor
final class NetNewsWirePublishingActionsTests: XCTestCase {
	override class func setUp() {
		super.setUp()
		try! NetNewsWireFeatureTestEnvironment.configure()
	}

	func testCaptureExportsOnlyPlainPublishingValues() {
		let url = URL(string: "https://example.com/article")!
		let capture = NetNewsWirePublishingCapture(
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
			"selectedText", "title", "creator", "preferredURL", "renderedArticleHTML", "renderedArticleBaseURL"
		])
		assertSendable(capture)
	}

	func testPublishingIntentsArePlainSendableValues() {
		XCTAssertEqual(NetNewsWirePublishingIntent.capture, .capture)
		XCTAssertEqual(NetNewsWirePublishingIntent.postAs(.quotation), .postAs(.quotation))
		XCTAssertEqual(NetNewsWirePublishingIntent.postAs(.blogmark), .postAs(.blogmark))
		XCTAssertEqual(NetNewsWirePublishingIntent.postAs(.note), .postAs(.note))
		assertSendable(NetNewsWirePublishingIntent.capture)
		assertSendable(NetNewsWirePublishingIntent.postAs(.quotation))
	}

	func testPublishingActionsSendCaptureAndIntent() {
		let expectedCapture = NetNewsWirePublishingCapture(
			selectedText: nil,
			title: "Article",
			creator: nil,
			preferredURL: URL(string: "https://example.com/article")!
		)
		var receivedCapture: NetNewsWirePublishingCapture?
		var receivedIntent: NetNewsWirePublishingIntent?
		let actions = NetNewsWirePublishingActions { capture, intent in
			receivedCapture = capture
			receivedIntent = intent
		}

		actions.send(expectedCapture, .postAs(.blogmark))

		XCTAssertEqual(receivedCapture, expectedCapture)
		XCTAssertEqual(receivedIntent, .postAs(.blogmark))
	}

	func testPublishingActionsShareMarkdownWhenEnabled() {
		let expectedCapture = NetNewsWirePublishingCapture(
			selectedText: "Saved highlight",
			title: "Article",
			creator: "Author",
			preferredURL: URL(string: "https://example.com/article")!
		)
		var receivedCapture: NetNewsWirePublishingCapture?
		let actions = NetNewsWirePublishingActions(
			send: { _, _ in },
			shareMarkdown: { receivedCapture = $0 }
		)

		actions.shareMarkdown(expectedCapture)

		XCTAssertEqual(receivedCapture, expectedCapture)
	}

	func testMarkdownSharingUsesRenderedHighlightsWithoutReloadingTheStore() throws {
		let laterID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
		let earlierID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
		let base = NetNewsWirePublishingCapture(
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

	func testDisabledPublishingActionsAreNoOp() {
		let capture = NetNewsWirePublishingCapture(
			selectedText: nil,
			title: "Article",
			creator: nil,
			preferredURL: URL(string: "https://example.com/article")!
		)

		NetNewsWirePublishingActions.disabled.send(capture, .capture)
	}

	func testSelectedPlainTextNormalizationTrimsAndRejectsBlankText() {
		XCTAssertEqual(WebViewController.normalizedSelectedPlainText("  selected text\n"), "selected text")
		XCTAssertNil(WebViewController.normalizedSelectedPlainText(" \n\t "))
	}

	func testPublishingMenuAccessibilityLabelPreservesDisabledShareLabel() {
		let localize = { (key: String, comment: String) in "\(key)|\(comment)" }

		XCTAssertEqual(NetNewsWirePublishingMenuText.accessibilityLabel(
			actionsEnabled: false,
			existingLabel: "Share",
			localize: localize
		), "Share")
		XCTAssertEqual(NetNewsWirePublishingMenuText.accessibilityLabel(
			actionsEnabled: true,
			existingLabel: "Share",
			localize: localize
		), "Publishing actions|Publishing actions accessibility label")
	}

	func testPublishingMenuTitlesUseCommandLocalizationKeys() {
		let titles = NetNewsWirePublishingMenuText.actionTitles { key, comment in
			"\(key)|\(comment)"
		}

		XCTAssertEqual(titles.captureLink, "Capture Link|Command")
		XCTAssertEqual(titles.postQuote, "Post Quote...|Command")
		XCTAssertEqual(titles.postLink, "Post Link...|Command")
		XCTAssertEqual(titles.postNote, "Post Note...|Command")
		XCTAssertEqual(titles.captureSelection, "Capture Selection|Command")
		XCTAssertEqual(titles.postHighlights, "Post Highlights...|Command")
		XCTAssertEqual(titles.shareMarkdown, "Share as Markdown...|Command")
		XCTAssertEqual(titles.shareMarkdownArticle, "Share Full Article as Markdown...|Command")
	}

	func testArticleMenuKeepsSharingInItsOwnLeadingSectionAndPostLabelsWhole() throws {
		let controller = ArticleViewController.instantiate(from: .main, highlightActions: .disabled)
		controller.publishingActions = NetNewsWirePublishingActions(
			send: { _, _ in },
			shareMarkdown: { _ in }
		)

		let menu = controller.makePublishingMenu()
		let sections = menu.children.compactMap { $0 as? UIMenu }
		XCTAssertEqual(sections.count, 2)
		XCTAssertEqual(
			sections[0].children.compactMap { ($0 as? UIAction)?.title },
			["Share", "Share as Markdown...", "Share Full Article as Markdown..."]
		)
		let publishingTitles = sections[1].children.compactMap { ($0 as? UIAction)?.title }
		XCTAssertTrue(publishingTitles.contains("Post Quote..."))
		XCTAssertTrue(publishingTitles.contains("Post Link..."))
		XCTAssertTrue(publishingTitles.contains("Post Note..."))
	}

	func testRichCaptureCarriesRenderedArticleAndBaseURLThroughShareCallback() throws {
		let baseURL = try XCTUnwrap(URL(string: "https://example.com/article"))
		let capture = NetNewsWirePublishingCapture(
			selectedText: "highlight",
			title: "Article",
			creator: nil,
			preferredURL: baseURL,
			renderedArticleHTML: "<article><p>Rendered</p></article>",
			renderedArticleBaseURL: baseURL
		)
		var received: NetNewsWirePublishingCapture?
		let actions = NetNewsWirePublishingActions(
			send: { _, _ in },
			shareMarkdown: { received = $0 }
		)

		actions.shareMarkdown(capture)

		XCTAssertEqual(received?.renderedArticleHTML, capture.renderedArticleHTML)
		XCTAssertEqual(received?.renderedArticleBaseURL, baseURL)
	}

	func testHighlightCaptureFreshLoadsAndUsesResolvedPostingOrder() async throws {
		let resolvedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
		let unresolvedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
		let persistedURL = try XCTUnwrap(URL(string: "https://example.com/persisted"))
		var loads = 0
		var currentRecords = [
			makeRecord(id: unresolvedID, selectedText: "Unresolved", preferredURL: persistedURL),
			makeRecord(id: resolvedID, selectedText: "Resolved", preferredURL: persistedURL)
		]
		let load = { (_: String) async throws -> [NetNewsWireHighlightRecord] in
			loads += 1
			return currentRecords
		}

		let availableCapture = await NetNewsWireHighlightPublishing.capture(
			articleKey: "article-key",
			currentTitle: "Current title",
			currentCreator: "Current creator",
			currentPreferredURL: nil,
			load: load,
			resolvedPositions: { [resolvedID: 4] }
		)
		XCTAssertNotNil(availableCapture)

		currentRecords[0] = makeRecord(
			id: unresolvedID,
			selectedText: "Fresh unresolved",
			preferredURL: persistedURL
		)
		let tappedCapture = await NetNewsWireHighlightPublishing.capture(
			articleKey: "article-key",
			currentTitle: "Current title",
			currentCreator: "Current creator",
			currentPreferredURL: nil,
			load: load,
			resolvedPositions: { [resolvedID: 4] }
		)

		XCTAssertEqual(loads, 2)
		XCTAssertEqual(tappedCapture?.selectedText, "Resolved\n\nFresh unresolved")
		XCTAssertEqual(tappedCapture?.preferredURL, persistedURL)

		var received: [(NetNewsWirePublishingCapture, NetNewsWirePublishingIntent)] = []
		let actions = NetNewsWirePublishingActions { received.append(($0, $1)) }
		if let tappedCapture {
			actions.send(tappedCapture, .postAs(.quotation))
		}
		XCTAssertEqual(received.count, 1)
		XCTAssertEqual(received.first?.0, tappedCapture)
		XCTAssertEqual(received.first?.1, .postAs(.quotation))
	}

	func testHighlightCaptureRequiresNonblankTextAndCurrentOrPersistedURL() async {
		let blank = makeRecord(selectedText: " \n\t ", preferredURL: nil)
		let textWithoutURL = makeRecord(selectedText: "Excerpt", preferredURL: nil)
		let textWithInvalidURL = makeRecord(selectedText: "Excerpt", preferredURL: URL(string: "relative"))

		let blankCapture = await NetNewsWireHighlightPublishing.capture(
			articleKey: "article-key",
			currentTitle: "Title",
			currentCreator: nil,
			currentPreferredURL: URL(string: "https://example.com/current"),
			load: { _ in [blank] },
			resolvedPositions: { [:] }
		)
		let missingURLCapture = await NetNewsWireHighlightPublishing.capture(
			articleKey: "article-key",
			currentTitle: "Title",
			currentCreator: nil,
			currentPreferredURL: nil,
			load: { _ in [textWithoutURL] },
			resolvedPositions: { [:] }
		)
		let invalidURLCapture = await NetNewsWireHighlightPublishing.capture(
			articleKey: "article-key",
			currentTitle: "Title",
			currentCreator: nil,
			currentPreferredURL: nil,
			load: { _ in [textWithInvalidURL] },
			resolvedPositions: { [:] }
		)

		XCTAssertNil(blankCapture)
		XCTAssertNil(missingURLCapture)
		XCTAssertNil(invalidURLCapture)
	}

	func testResolvedHighlightActionRejectsNewArticleBeforeLoadAndFreshLoadsValidTap() async throws {
		let articleAWebView = NSObject()
		let articleBWebView = NSObject()
		let action = NetNewsWireHighlightPostAction(
			articleKey: "article-a",
			webViewController: articleAWebView
		)
		let url = try XCTUnwrap(URL(string: "https://example.com/article-a"))
		var loads = 0
		var posts = [NetNewsWirePublishingCapture]()
		var currentRecords = [makeRecord(selectedText: "Initial excerpt", preferredURL: url)]
		let invoke: @MainActor (String, AnyObject) async -> Void = { articleKey, webViewController in
			await action.perform(
				currentArticleKey: articleKey,
				currentWebViewController: webViewController
			) {
				let capture = await NetNewsWireHighlightPublishing.capture(
					articleKey: "article-a",
					currentTitle: "Article A",
					currentCreator: nil,
					currentPreferredURL: url,
					load: { _ in
						loads += 1
						return currentRecords
					},
					resolvedPositions: { [:] }
				)
				if let capture {
					posts.append(capture)
				}
			}
		}

		await invoke("article-b", articleAWebView)
		await invoke("article-a", articleBWebView)
		await invoke("article-b", articleBWebView)
		XCTAssertEqual(loads, 0)
		XCTAssertTrue(posts.isEmpty)

		currentRecords = [makeRecord(selectedText: "Fresh excerpt", preferredURL: url)]
		await invoke("article-a", articleAWebView)
		XCTAssertEqual(loads, 1)
		XCTAssertEqual(posts.map(\.selectedText), ["Fresh excerpt"])
	}

	private func assertSendable<T: Sendable>(_ value: T) {}

	private func makeRecord(
		id: UUID = UUID(),
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
