import WebKit
import XCTest
@testable import NetNewsWireFeature

@MainActor
final class ArticleHighlightScriptTests: XCTestCase {
	private var webView: WKWebView!
	private var navigationDelegate: NavigationDelegate!
	private var messageRecorder: MessageRecorder!

	override class func setUp() {
		super.setUp()
		try! NetNewsWireFeatureTestEnvironment.configure()
	}

	func testSelectionAnchorNormalizesNFCAndWhitespaceRuns() async throws {
		try await loadArticle("<p id=\"target\">Café \n\t 😀   world</p>")
		try await selectText(in: "target", from: 0, to: 19)

		let anchor = try await objectResult("window.nnwHighlights.makeSelectionAnchor()")

		XCTAssertEqual(anchor["selectedText"] as? String, "Café 😀 world")
	}

	func testSelectionOffsetsUseJavaScriptUTF16Units() async throws {
		try await loadArticle(#"<p id="target">A😀B target end</p>"#)
		try await selectText(in: "target", from: 5, to: 11)

		let anchor = try await objectResult("window.nnwHighlights.makeSelectionAnchor()")

		XCTAssertEqual(anchor["selectedText"] as? String, "target")
		XCTAssertEqual(anchor["startOffset"] as? Int, 5)
		XCTAssertEqual(anchor["endOffset"] as? Int, 11)
	}

	func testSelectionAnchorContainsContextsDOMRangeRenditionAndFingerprint() async throws {
		let prefix = String(repeating: "p", count: 60)
		let suffix = String(repeating: "s", count: 60)
		try await loadArticle("<p id=\"target\">\(prefix)SELECT\(suffix)</p>")
		try await selectText(in: "target", from: 60, to: 66)

		let anchor = try await objectResult("window.nnwHighlights.makeSelectionAnchor()")
		let domRange = try XCTUnwrap(anchor["domRangeData"] as? [String: Any])

		XCTAssertEqual(anchor["selectedText"] as? String, "SELECT")
		XCTAssertEqual((anchor["prefixContext"] as? String)?.utf16.count, 48)
		XCTAssertEqual((anchor["suffixContext"] as? String)?.utf16.count, 48)
		XCTAssertEqual(anchor["startOffset"] as? Int, 60)
		XCTAssertEqual(anchor["endOffset"] as? Int, 66)
		XCTAssertEqual(domRange["version"] as? Int, 1)
		XCTAssertNotNil(domRange["startPath"] as? [Int])
		XCTAssertNotNil(domRange["endPath"] as? [Int])
		XCTAssertEqual(anchor["renditionKindRaw"] as? String, "v1:feed-body")
		let fingerprint = try XCTUnwrap(anchor["renderedTextFingerprint"] as? String)
		XCTAssertEqual(fingerprint, "sha256:90ed657cce31aab09e0a0aa6a62ca674ca4bdfb1b858ff674bdd5b4bab0e537a")

		var record = anchor
		record["id"] = "123e4567-e89b-12d3-a456-426614174000"
		record["createdAt"] = "2026-01-01T00:00:00Z"
		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([record])))")
		XCTAssertEqual(restored.count, 1)
	}

	func testJavaScriptBridgeAwaitsSelectionAnchorAndRestore() async throws {
		try await loadArticle(#"<p id="target">before highlighted text after</p>"#)
		try await selectText(in: "target", from: 7, to: 23)

		let anchorValue = try await ArticleHighlightJavaScriptBridge.makeSelectionAnchor(in: webView)
		var record = try XCTUnwrap(anchorValue as? [String: Any])
		record["id"] = "123e4567-e89b-12d3-a456-426614174000"
		record["createdAt"] = Date().timeIntervalSince1970

		let restoredValue = try await ArticleHighlightJavaScriptBridge.restore([record], in: webView)
		let restored = try XCTUnwrap(restoredValue as? [[String: Any]])
		let markedText = try await stringResult("document.querySelector('mark.nnw-saved-highlight')?.textContent || ''")

		XCTAssertEqual(restored.count, 1)
		XCTAssertEqual(markedText, "highlighted text")
	}

	func testQuoteContextFallbackResolvesUniqueWinnerAndRejectsTie() async throws {
		try await loadArticle(#"<p>alpha repeated omega middle beta repeated gamma</p>"#)
		let unique = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "repeated", prefix: "beta ", suffix: " gamma", start: 33
		)
		let tied = record(
			id: "00000000-0000-0000-0000-000000000002",
			selectedText: "repeated", prefix: "", suffix: "", start: 20
		)

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([unique, tied])))")

		XCTAssertEqual(restored.count, 1)
		XCTAssertEqual(restored.first?["id"] as? String, unique["id"] as? String)
		let markedText = try await stringResult("document.querySelector('mark')?.textContent || ''")
		XCTAssertEqual(markedText, "repeated")
	}

	func testRestoreIgnoresHiddenDuplicateAndReportsVisibleOccurrence() async throws {
		try await loadArticle("""
		<style>.display-none { display: none; } .visibility-hidden { visibility: hidden; }</style>
		<p id="hidden" hidden>before target after</p>
		<p class="display-none">before target after</p>
		<p class="visibility-hidden">before target after</p>
		<details><p>before target after</p></details>
		<p id="visible">before target after</p>
		""")
		let highlight = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "target",
			prefix: "before ",
			suffix: " after",
			start: 7
		)

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([highlight])))")
		let markedParent = try await stringResult("document.querySelector('mark.nnw-saved-highlight')?.closest('p')?.id || ''")
		let visibleMarkCount = try await intResult("document.querySelectorAll('#visible mark.nnw-saved-highlight').length")
		let hiddenMarkCount = try await intResult("document.querySelectorAll('#hidden mark, .display-none mark, .visibility-hidden mark, details:not([open]) mark').length")
		let positions = try await arrayResult("window.nnwHighlights.positions()")

		XCTAssertEqual(restored.count, 1)
		XCTAssertEqual(markedParent, "visible")
		XCTAssertEqual(visibleMarkCount, 1)
		XCTAssertEqual(hiddenMarkCount, 0)
		XCTAssertEqual(positions.first?["id"] as? String, highlight["id"] as? String)
		XCTAssertEqual(positions.first?["startOffset"] as? Int, 7)
		XCTAssertEqual(positions.first?["endOffset"] as? Int, 13)
	}

	func testRestorePreservesRenderedOffscreenContent() async throws {
		try await loadArticle(#"<p id="offscreen" style="position: absolute; left: -10000px">before target after</p>"#)
		let highlight = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "target",
			prefix: "before ",
			suffix: " after",
			start: 7
		)

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([highlight])))")
		let markCount = try await intResult("document.querySelectorAll('#offscreen mark.nnw-saved-highlight').length")
		let positions = try await arrayResult("window.nnwHighlights.positions()")

		XCTAssertEqual(restored.count, 1)
		XCTAssertEqual(markCount, 1)
		XCTAssertEqual(positions.first?["startOffset"] as? Int, 7)
		XCTAssertEqual(positions.first?["endOffset"] as? Int, 13)
	}

	func testRestoreRejectsHiddenDisplayContentsWrapperAndUsesRenderedWrapper() async throws {
		try await loadArticle("""
		<div id="hidden-contents" style="display: contents; visibility: hidden">
			<p style="visibility: visible">before target after</p>
		</div>
		<div id="visible-contents" style="display: contents">
			<p>before target after</p>
		</div>
		""")
		let highlight = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "target",
			prefix: "before ",
			suffix: " after",
			start: 7
		)

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([highlight])))")
		let markedWrapper = try await stringResult("document.querySelector('mark')?.closest('#hidden-contents, #visible-contents')?.id || ''")
		let positions = try await arrayResult("window.nnwHighlights.positions()")

		XCTAssertEqual(restored.count, 1)
		XCTAssertEqual(markedWrapper, "visible-contents")
		XCTAssertEqual(positions.first?["startOffset"] as? Int, 7)
		XCTAssertEqual(positions.first?["endOffset"] as? Int, 13)
	}

	func testRestoreAcceptsAdjacentRangesAndRejectsOverlapDeterministically() async throws {
		try await loadArticle(#"<p>alpha beta gamma</p>"#)
		let first = record(id: "00000000-0000-0000-0000-000000000003", selectedText: "alpha", start: 0, createdAt: "2026-01-01T00:00:00Z")
		let overlapping = record(id: "00000000-0000-0000-0000-000000000001", selectedText: "alpha beta", start: 0, createdAt: "2026-01-02T00:00:00Z")
		let adjacent = record(id: "00000000-0000-0000-0000-000000000002", selectedText: " beta", start: 5, createdAt: "2026-01-03T00:00:00Z")

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([adjacent, overlapping, first])))")
		let ids = restored.compactMap { $0["id"] as? String }

		XCTAssertEqual(ids, [first["id"] as? String, adjacent["id"] as? String].compactMap { $0 })
		let markCount = try await intResult("document.querySelectorAll('mark.nnw-saved-highlight').length")
		XCTAssertEqual(markCount, 2)
	}

	func testDecorationUsesUUIDMarksAndClearUnwrapsAndNormalizes() async throws {
		try await loadArticle(#"<p id="body">alpha beta</p>"#)
		let id = "123e4567-e89b-12d3-a456-426614174000"
		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([record(id: id, selectedText: "alpha", start: 0)])))")

		XCTAssertEqual(restored.count, 1)
		let markedID = try await stringResult("document.querySelector('mark').dataset.nnwHighlightId")
		let markClass = try await stringResult("document.querySelector('mark').className")
		XCTAssertEqual(markedID, id)
		XCTAssertEqual(markClass, "nnw-saved-highlight")

		_ = try await valueResult("window.nnwHighlights.clear()")
		let markCount = try await intResult("document.querySelectorAll('mark.nnw-saved-highlight').length")
		let childCount = try await intResult("document.getElementById('body').childNodes.length")
		let bodyText = try await stringResult("document.getElementById('body').textContent")
		XCTAssertEqual(markCount, 0)
		XCTAssertEqual(childCount, 1)
		XCTAssertEqual(bodyText, "alpha beta")
	}

	func testPositionsReturnsResolvedHighlightsInDocumentOrder() async throws {
		try await loadArticle(#"<p>zero one two</p>"#)
		let later = record(id: "00000000-0000-0000-0000-000000000002", selectedText: "two", start: 9)
		let earlier = record(id: "00000000-0000-0000-0000-000000000001", selectedText: "zero", start: 0)
		_ = try await arrayResult("window.nnwHighlights.restore(\(json([later, earlier])))")

		let positions = try await arrayResult("window.nnwHighlights.positions()")

		let expectedIDs = [earlier["id"] as? String, later["id"] as? String].compactMap { $0 }
		XCTAssertEqual(positions.compactMap { $0["id"] as? String }, expectedIDs)
		XCTAssertEqual(positions.compactMap { $0["startOffset"] as? Int }, [0, 9])
	}

	func testRichTextForPostingCapturesInlineMarkupAndRenderedBaseURL() async throws {
		try await loadArticle(
			#"<p>First <a href="/next">linked</a> highlight</p>"#,
			baseURL: URL(string: "https://example.com/posts/current")
		)
		let highlight = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "First linked highlight",
			start: 0
		)

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([highlight])))")
		let snapshot = try await objectResult("window.nnwHighlights.richTextForPosting()")
		let rich = try XCTUnwrap(snapshot["richText"] as? [[String: Any]])

		XCTAssertEqual(restored.count, 1)
		XCTAssertEqual(snapshot["generation"] as? Int, 42)
		XCTAssertEqual(snapshot["articleKey"] as? String, "article-key")
		XCTAssertEqual(snapshot["rendition"] as? String, "v1:feed-body")
		XCTAssertEqual((snapshot["positions"] as? [[String: Any]])?.first?["id"] as? String, highlight["id"] as? String)
		XCTAssertEqual(rich.first?["id"] as? String, highlight["id"] as? String)
		XCTAssertEqual(rich.first?["selectedText"] as? String, "First linked highlight")
		XCTAssertTrue((rich.first?["html"] as? String)?.contains("href=\"/next\"") == true)
		XCTAssertEqual(rich.first?["baseURL"] as? String, "https://example.com/posts/current")
	}

	func testRichTextForPostingKeepsWholeAndPartialEnclosingLinksWithoutSiblings() async throws {
		try await loadArticle(
			#"<p><a href="/whole">whole link</a> <a href="/partial">before selected after</a></p>"#,
			baseURL: URL(string: "https://example.com/posts/current")
		)
		let whole = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "whole link",
			start: 0
		)
		let partial = record(
			id: "00000000-0000-0000-0000-000000000002",
			selectedText: "selected",
			start: 18
		)

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([whole, partial])))")
		let snapshot = try await objectResult("window.nnwHighlights.richTextForPosting()")
		let rich = try XCTUnwrap(snapshot["richText"] as? [[String: Any]])
		let fragments: [String: String] = Dictionary(uniqueKeysWithValues: rich.compactMap { item in
			guard let id = item["id"] as? String, let html = item["html"] as? String else { return nil }
			return (id, html)
		})
		let wholeID = try XCTUnwrap(whole["id"] as? String)
		let partialID = try XCTUnwrap(partial["id"] as? String)

		XCTAssertEqual(restored.count, 2)
		XCTAssertTrue(fragments[wholeID]?.contains("href=\"/whole\"") == true)
		XCTAssertTrue(fragments[partialID]?.contains("href=\"/partial\"") == true)
		XCTAssertTrue(fragments[partialID]?.contains("selected") == true)
		XCTAssertFalse(fragments[partialID]?.contains("before") == true)
		XCTAssertFalse(fragments[partialID]?.contains("after") == true)
	}

	func testPrepareClearsResolvedStateOnlyWhenRenderIdentityChanges() async throws {
		try await loadArticle(#"<p>alpha beta</p>"#)
		let highlight = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "alpha",
			start: 0
		)
		_ = try await arrayResult("window.nnwHighlights.restore(\(json([highlight])))")

		_ = try await valueResult(#"window.nnwHighlights.prepare(42, "v1:feed-body")"#)
		let identicalPositions = try await arrayResult("window.nnwHighlights.positions()")
		let identicalMarkCount = try await intResult("document.querySelectorAll('#bodyContainer mark.nnw-saved-highlight').length")

		_ = try await valueResult("""
		(() => {
			const oldRoot = document.getElementById("bodyContainer");
			oldRoot.id = "previousBodyContainer";
			const newRoot = document.createElement("div");
			newRoot.id = "bodyContainer";
			newRoot.className = "articleBody";
			newRoot.textContent = "new render";
			document.body.appendChild(newRoot);
			return window.nnwHighlights.prepare(43, "v1:reader-view");
		})()
		""")
		let changedPositions = try await arrayResult("window.nnwHighlights.positions()")
		let previousMarkCount = try await intResult("document.querySelectorAll('#previousBodyContainer mark.nnw-saved-highlight').length")

		XCTAssertEqual(identicalPositions.count, 1)
		XCTAssertEqual(identicalMarkCount, 1)
		XCTAssertTrue(changedPositions.isEmpty)
		XCTAssertEqual(previousMarkCount, 0)
	}

	func testMarkTapPostsUUIDGenerationAndBoundingRectangle() async throws {
		try await loadArticle(#"<p>alpha beta</p>"#)
		let id = "123e4567-e89b-12d3-a456-426614174000"
		_ = try await arrayResult("window.nnwHighlights.restore(\(json([record(id: id, selectedText: "alpha", start: 0)])))")

		_ = try await valueResult("document.querySelector('mark').click()")
		let message = try await messageRecorder.nextMessage(named: "highlightWasTapped")
		let rectangle = try XCTUnwrap(message["rect"] as? [String: Any])

		XCTAssertEqual(message["id"] as? String, id)
		XCTAssertEqual(message["generation"] as? Int, 42)
		XCTAssertEqual(message["articleKey"] as? String, "article-key")
		XCTAssertEqual(message["rendition"] as? String, "v1:feed-body")
		XCTAssertGreaterThan(rectangle["width"] as? Double ?? 0, 0)
		XCTAssertGreaterThan(rectangle["height"] as? Double ?? 0, 0)
	}

	func testSelectionChangePostsCompleteRenderIdentity() async throws {
		try await loadArticle(#"<p id="target">alpha beta</p>"#)

		try await selectText(in: "target", from: 0, to: 5)
		let message = try await messageRecorder.nextMessage(named: "highlightSelectionChanged")

		XCTAssertEqual(message["generation"] as? Int, 42)
		XCTAssertEqual(message["articleKey"] as? String, "article-key")
		XCTAssertEqual(message["rendition"] as? String, "v1:feed-body")
	}

	func testSettledSelectionPostsAutomaticHighlightAnchor() async throws {
		try await loadArticle(#"<p id="target">alpha beta</p>"#)

		try await selectText(in: "target", from: 0, to: 5)
		_ = try await valueResult("document.dispatchEvent(new Event('pointerup'))")
		let message = try await messageRecorder.nextMessage(named: "highlightSelectionCompleted")
		let anchor = try XCTUnwrap(message["anchor"] as? [String: Any])

		XCTAssertEqual(message["generation"] as? Int, 42)
		XCTAssertEqual(message["articleKey"] as? String, "article-key")
		XCTAssertEqual(anchor["selectedText"] as? String, "alpha")
		XCTAssertEqual(anchor["startOffset"] as? Int, 0)
		XCTAssertEqual(anchor["endOffset"] as? Int, 5)
		XCTAssertEqual(anchor["renditionKindRaw"] as? String, "v1:feed-body")
	}

	func testSelectionChangesProduceOnlyOneAutomaticHighlightAnchor() async throws {
		try await loadArticle(#"<p id="target">alpha beta</p>"#)

		try await selectText(in: "target", from: 0, to: 5)
		try await selectText(in: "target", from: 6, to: 10)
		_ = try await valueResult("document.dispatchEvent(new Event('pointerup'))")
		let message = try await messageRecorder.nextMessage(named: "highlightSelectionCompleted")
		try await Task.sleep(for: .milliseconds(300))

		XCTAssertEqual((message["anchor"] as? [String: Any])?["selectedText"] as? String, "beta")
		XCTAssertEqual(messageRecorder.messageCount(named: "highlightSelectionCompleted"), 0)
	}


	func testPointerGestureDoesNotPersistAnIntermediateSelection() async throws {
		try await loadArticle(#"<p id="target">alpha beta</p>"#)

		_ = try await valueResult("document.dispatchEvent(new Event('pointerdown'))")
		try await selectText(in: "target", from: 0, to: 5)
		try await Task.sleep(for: .milliseconds(150))
		try await selectText(in: "target", from: 6, to: 10)
		try await Task.sleep(for: .milliseconds(150))

		XCTAssertEqual(messageRecorder.messageCount(named: "highlightSelectionCompleted"), 0)

		_ = try await valueResult("document.dispatchEvent(new Event('pointerup'))")
		let message = try await messageRecorder.nextMessage(named: "highlightSelectionCompleted")

		XCTAssertEqual((message["anchor"] as? [String: Any])?["selectedText"] as? String, "beta")
	}

	func testCancelledPointerGestureDoesNotBlockTheNextKeyboardSelection() async throws {
		try await loadArticle(#"<p id="target">alpha beta</p>"#)

		_ = try await valueResult("document.dispatchEvent(new Event('pointerdown'))")
		try await selectText(in: "target", from: 0, to: 5)
		_ = try await valueResult("document.dispatchEvent(new Event('pointercancel'))")
		_ = try await valueResult("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Shift', shiftKey: true }))")
		try await selectText(in: "target", from: 6, to: 10)
		_ = try await valueResult("document.dispatchEvent(new KeyboardEvent('keyup', { key: 'Shift' }))")
		_ = try await valueResult("document.dispatchEvent(new Event('selectionchange'))")

		let message = try await messageRecorder.nextMessage(named: "highlightSelectionCompleted")

		XCTAssertEqual((message["anchor"] as? [String: Any])?["selectedText"] as? String, "beta")
	}

	func testRestoreAbortsWhenPrepareChangesGenerationDuringFingerprint() async throws {
		try await loadArticle(#"<p>alpha beta</p>"#)
		let records = json([record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "alpha",
			start: 0
		)])

		let restored = try await arrayResult("""
		(() => {
			const pending = window.nnwHighlights.restore(\(records));
			window.nnwHighlights.prepare(43, "v1:reader-view");
			return pending;
		})()
		""")

		let markCount = try await intResult("document.querySelectorAll('mark.nnw-saved-highlight').length")
		let positions = try await arrayResult("window.nnwHighlights.positions()")
		XCTAssertTrue(restored.isEmpty)
		XCTAssertEqual(markCount, 0)
		XCTAssertTrue(positions.isEmpty)
	}

	func testQuoteFallbackMapsComposedNFCTextToCompleteDecomposedDOMRange() async throws {
		try await loadArticle("<p>before e\u{301} after</p>")
		let highlight = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "é",
			start: 7
		)

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([highlight])))")
		let markedText = try await stringResult("document.querySelector('mark')?.textContent || ''")

		XCTAssertEqual(restored.count, 1)
		XCTAssertEqual(markedText, "e\u{301}")
	}

	func testRestoreRejectsDOMAndQuoteRangesThatEnterOrCrossExcludedSubtrees() async throws {
		try await loadArticle(#"<p id="target">alpha<script>evil</script>beta<style>.x{}</style>gamma</p>"#)
		try await selectText(in: "target", from: 0, to: 5)
		let anchor = try await objectResult("window.nnwHighlights.makeSelectionAnchor()")
		let fingerprint = try XCTUnwrap(anchor["renderedTextFingerprint"] as? String)
		var invalidDOM = record(
			id: "00000000-0000-0000-0000-000000000001",
			selectedText: "evil",
			start: 5
		)
		invalidDOM["renderedTextFingerprint"] = fingerprint
		invalidDOM["domRangeData"] = [
			"version": 1,
			"startPath": [0, 1, 0],
			"startOffset": 0,
			"endPath": [0, 1, 0],
			"endOffset": 4
		]
		let crossingQuote = record(
			id: "00000000-0000-0000-0000-000000000002",
			selectedText: "alphabeta",
			start: 0
		)

		let restored = try await arrayResult("window.nnwHighlights.restore(\(json([invalidDOM, crossingQuote])))")
		let markCount = try await intResult("document.querySelectorAll('mark.nnw-saved-highlight').length")
		let scriptText = try await stringResult("document.querySelector('script').textContent")
		let styleText = try await stringResult("document.querySelector('style').textContent")

		XCTAssertTrue(restored.isEmpty)
		XCTAssertEqual(markCount, 0)
		XCTAssertEqual(scriptText, "evil")
		XCTAssertEqual(styleText, ".x{}")
	}

	func testMarkTapIgnoresMatchingMarkOutsideCurrentRoot() async throws {
		try await loadArticle(#"<p>alpha beta</p>"#)
		_ = try await valueResult("""
		(() => {
			const mark = document.createElement("mark");
			mark.className = "nnw-saved-highlight";
			mark.dataset.nnwHighlightId = "123e4567-e89b-12d3-a456-426614174000";
			mark.textContent = "outside";
			document.body.appendChild(mark);
			mark.click();
			return true;
		})()
		""")
		try await Task.sleep(for: .milliseconds(100))

		XCTAssertEqual(messageRecorder.messageCount(named: "highlightWasTapped"), 0)
	}

	private func loadArticle(_ body: String, baseURL: URL? = nil) async throws {
		let scriptURL = try XCTUnwrap(
			Bundle.netNewsWireFeatureResources.url(forResource: "article_highlights", withExtension: "js")
		)
		let script = try String(contentsOf: scriptURL, encoding: .utf8)
		let configuration = WKWebViewConfiguration()
		configuration.userContentController.addUserScript(WKUserScript(
			source: script,
			injectionTime: .atDocumentStart,
			forMainFrameOnly: true
		))
		messageRecorder = MessageRecorder()
		for name in ["highlightSelectionChanged", "highlightSelectionCompleted", "highlightWasTapped"] {
			configuration.userContentController.add(messageRecorder, name: name)
		}
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
		navigationDelegate = NavigationDelegate()
		webView.navigationDelegate = navigationDelegate
		let loaded = expectation(description: "HTML loaded")
		navigationDelegate.didFinish = { loaded.fulfill() }
		webView.loadHTMLString("<html><body><header>ignored metadata</header><div id=\"bodyContainer\" class=\"articleBody\">\(body)</div></body></html>", baseURL: baseURL)
		await fulfillment(of: [loaded], timeout: 20)
		_ = try await valueResult(#"window.nnwHighlights.prepare(42, "v1:feed-body", "article-key")"#)
	}

	private func selectText(in elementID: String, from start: Int, to end: Int) async throws {
		let script = """
		(() => {
			const node = document.getElementById('\(elementID)').firstChild;
			const range = document.createRange();
			range.setStart(node, \(start));
			range.setEnd(node, \(end));
			const selection = window.getSelection();
			selection.removeAllRanges();
			selection.addRange(range);
			return true;
		})()
		"""
		_ = try await valueResult(script)
	}

	private func record(
		id: String,
		selectedText: String,
		prefix: String = "",
		suffix: String = "",
		start: Int,
		createdAt: String = "2026-01-01T00:00:00Z"
	) -> [String: Any] {
		[
			"id": id,
			"selectedText": selectedText,
			"prefixContext": prefix,
			"suffixContext": suffix,
			"startOffset": start,
			"endOffset": start + selectedText.utf16.count,
			"domRangeData": NSNull(),
			"renditionKindRaw": "v1:feed-body",
			"renderedTextFingerprint": "sha256:" + String(repeating: "0", count: 64),
			"createdAt": createdAt
		]
	}

	private func json(_ object: Any) -> String {
		let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		return String(decoding: data, as: UTF8.self)
	}

	private func objectResult(_ expression: String) async throws -> [String: Any] {
		let value = try await valueResult(expression)
		return try XCTUnwrap(value as? [String: Any])
	}

	private func arrayResult(_ expression: String) async throws -> [[String: Any]] {
		let value = try await valueResult(expression)
		return try XCTUnwrap(value as? [[String: Any]])
	}

	private func stringResult(_ expression: String) async throws -> String {
		let value = try await valueResult(expression)
		return try XCTUnwrap(value as? String)
	}

	private func intResult(_ expression: String) async throws -> Int {
		let value = try await valueResult(expression)
		return try XCTUnwrap(value as? Int)
	}

	private func valueResult(_ expression: String) async throws -> Any? {
		let token = "nnwTest\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
		let start = """
		window['\(token)'] = { done: false };
		Promise.resolve(\(expression)).then(
			value => window['\(token)'] = { done: true, value: JSON.stringify(value === undefined ? null : value) },
			error => window['\(token)'] = { done: true, error: String(error && error.stack ? error.stack : error) }
		);
		true;
		"""
		_ = try await webView.evaluateJavaScript(start)
		for _ in 0..<500 {
			if let resultJSON = try await webView.evaluateJavaScript("window['\(token)'].done ? JSON.stringify(window['\(token)']) : null") as? String,
				let resultData = resultJSON.data(using: .utf8),
				let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
				if let error = result["error"] as? String {
					XCTFail(error)
					throw ScriptError.failed(error)
				}
				guard let valueJSON = result["value"] as? String,
					let valueData = valueJSON.data(using: .utf8) else {
					return nil
				}
				return try JSONSerialization.jsonObject(with: valueData, options: [.fragmentsAllowed])
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		throw ScriptError.timedOut
	}
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
	var didFinish: (() -> Void)?

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		didFinish?()
	}
}

@MainActor
private final class MessageRecorder: NSObject, WKScriptMessageHandler {
	private var messages = [(String, [String: Any])]()

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		if let body = message.body as? [String: Any] {
			messages.append((message.name, body))
		}
	}

	func nextMessage(named name: String) async throws -> [String: Any] {
		for _ in 0..<500 {
			if let index = messages.firstIndex(where: { $0.0 == name }) {
				return messages.remove(at: index).1
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		throw ScriptError.timedOut
	}

	func messageCount(named name: String) -> Int {
		messages.count { $0.0 == name }
	}
}

private enum ScriptError: Error {
	case failed(String)
	case timedOut
}
