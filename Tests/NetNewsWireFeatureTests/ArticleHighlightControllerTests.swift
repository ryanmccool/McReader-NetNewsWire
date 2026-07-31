import XCTest
import WebKit
@testable import NetNewsWireFeature

@MainActor
final class ArticleHighlightControllerTests: XCTestCase {
	func testSelectionEligibilityRequiresEnabledStableIdentityNonblankTextAndNoOverlap() {
		XCTAssertTrue(ArticleHighlightSelectionEligibility.isEligible(
			enabled: true, articleKey: "article", selectedText: "Selection", overlapsSavedHighlight: false
		))
		XCTAssertFalse(ArticleHighlightSelectionEligibility.isEligible(
			enabled: false, articleKey: "article", selectedText: "Selection", overlapsSavedHighlight: false
		))
		XCTAssertFalse(ArticleHighlightSelectionEligibility.isEligible(
			enabled: true, articleKey: nil, selectedText: "Selection", overlapsSavedHighlight: false
		))
		XCTAssertFalse(ArticleHighlightSelectionEligibility.isEligible(
			enabled: true, articleKey: "article", selectedText: " \n\t", overlapsSavedHighlight: false
		))
		XCTAssertFalse(ArticleHighlightSelectionEligibility.isEligible(
			enabled: true, articleKey: "article", selectedText: "Selection", overlapsSavedHighlight: true
		))
	}

	func testEachRenderInvalidationAdvancesGenerationAndRejectsPreviousState() {
		let lifecycle = ArticleHighlightLifecycle()
		let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		let articleState = lifecycle.beginRender(webView: webView, articleKey: "article-1", rendition: .feedBody)
		let renditionState = lifecycle.beginRender(webView: webView, articleKey: "article-1", rendition: .readerView)
		let rerenderState = lifecycle.beginRender(webView: webView, articleKey: "article-1", rendition: .readerView)
		let nextArticleState = lifecycle.beginRender(webView: webView, articleKey: "article-2", rendition: .feedBody)

		XCTAssertEqual(
			[articleState?.generation, renditionState?.generation, rerenderState?.generation, nextArticleState?.generation],
			[1, 2, 3, 4]
		)
		XCTAssertFalse(lifecycle.accepts(webView: webView, state: articleState))
		XCTAssertFalse(lifecycle.accepts(webView: webView, state: renditionState))
		XCTAssertFalse(lifecycle.accepts(webView: webView, state: rerenderState))
		XCTAssertTrue(lifecycle.accepts(webView: webView, state: nextArticleState))
	}

	func testRenderInvalidationCancelsObservationAndClearsSelectionEligibility() {
		var cancellationCount = 0
		let lifecycle = ArticleHighlightLifecycle()
		let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		_ = lifecycle.beginRender(webView: webView, articleKey: "article", rendition: .feedBody)
		lifecycle.selectionIsEligible = true
		lifecycle.observation = NetNewsWireHighlightObservation { cancellationCount += 1 }

		_ = lifecycle.beginRender(webView: webView, articleKey: "article", rendition: .feedBody)

		XCTAssertEqual(cancellationCount, 1)
		XCTAssertFalse(lifecycle.selectionIsEligible)
		XCTAssertNil(lifecycle.observation)
	}

	func testLifecycleRejectsDifferentWebViewAndStaleMessageGeneration() throws {
		let lifecycle = ArticleHighlightLifecycle()
		let currentWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		let staleWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		let state = try XCTUnwrap(lifecycle.beginRender(webView: currentWebView, articleKey: "article", rendition: .feedBody))

		XCTAssertFalse(lifecycle.accepts(webView: staleWebView, state: state))
		XCTAssertFalse(lifecycle.accepts(webView: currentWebView, generation: state.generation + 1))
		XCTAssertTrue(lifecycle.accepts(webView: currentWebView, generation: state.generation))
	}

	func testInsertCompletesBeforeDecoration() async throws {
		var events = [String]()

		try await ArticleHighlightMutation.insertBeforeDecoration {
			events.append("insert")
		} decorate: {
			events.append("decorate")
		}

		XCTAssertEqual(events, ["insert", "decorate"])
	}

	func testFailedInsertDoesNotDecorate() async {
		var decorated = false

		do {
			try await ArticleHighlightMutation.insertBeforeDecoration {
				throw TestError.expected
			} decorate: {
				decorated = true
			}
			XCTFail("Expected insert to fail")
		} catch {
			XCTAssertEqual(error as? TestError, .expected)
		}

		XCTAssertFalse(decorated)
	}

	func testDeleteCompletesBeforeDOMRemoval() async throws {
		var events = [String]()

		try await ArticleHighlightMutation.deleteBeforeRemoval(isCurrent: { true }) {
			events.append("delete")
		} remove: {
			events.append("remove")
		}

		XCTAssertEqual(events, ["delete", "remove"])
	}

	func testFailedDeleteDoesNotRemoveDOMMark() async {
		var removed = false

		do {
			try await ArticleHighlightMutation.deleteBeforeRemoval(isCurrent: { true }) {
				throw TestError.expected
			} remove: {
				removed = true
			}
			XCTFail("Expected delete to fail")
		} catch {
			XCTAssertEqual(error as? TestError, .expected)
		}

		XCTAssertFalse(removed)
	}

	func testStaleRemoveRejectsBeforePersistenceDelete() async throws {
		var deleteCount = 0
		var removeCount = 0

		try await ArticleHighlightMutation.deleteBeforeRemoval(isCurrent: { false }) {
			deleteCount += 1
		} remove: {
			removeCount += 1
		}

		XCTAssertEqual(deleteCount, 0)
		XCTAssertEqual(removeCount, 0)
	}

	func testRemoveRechecksStateAfterDeleteBeforeDOMMutation() async throws {
		var isCurrent = true
		var removeCount = 0

		try await ArticleHighlightMutation.deleteBeforeRemoval(isCurrent: { isCurrent }) {
			isCurrent = false
		} remove: {
			removeCount += 1
		}

		XCTAssertEqual(removeCount, 0)
	}

	func testTapMessageRoutesOnlyValidUUIDAndGeneration() throws {
		let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000007"))
		let message = try XCTUnwrap(ArticleHighlightTapMessage(body: [
			"id": id.uuidString.lowercased(),
			"generation": 12,
			"articleKey": "article-key",
			"rendition": "v1:feed-body",
			"rect": ["x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0]
		]))

		XCTAssertEqual(message.id, id)
		XCTAssertEqual(message.renderState, ArticleHighlightRenderState(
			generation: 12, articleKey: "article-key", rendition: .feedBody
		))
		XCTAssertEqual(message.rect, CGRect(x: 1, y: 2, width: 3, height: 4))
		XCTAssertNil(ArticleHighlightTapMessage(body: ["id": "not-a-uuid", "generation": 12]))
	}

	func testMessageRenderStateRejectsArticleKeyAndRenditionMismatch() throws {
		let lifecycle = ArticleHighlightLifecycle()
		let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		let currentState = try XCTUnwrap(lifecycle.beginRender(
			webView: webView, articleKey: "article-key", rendition: .feedBody
		))
		let matching = try XCTUnwrap(ArticleHighlightMessageRenderState(body: [
			"generation": currentState.generation,
			"articleKey": currentState.articleKey,
			"rendition": currentState.rendition.rawValue
		]))
		let wrongArticle = try XCTUnwrap(ArticleHighlightMessageRenderState(body: [
			"generation": currentState.generation,
			"articleKey": "other-article",
			"rendition": currentState.rendition.rawValue
		]))
		let wrongRendition = try XCTUnwrap(ArticleHighlightMessageRenderState(body: [
			"generation": currentState.generation,
			"articleKey": currentState.articleKey,
			"rendition": ArticleHighlightRenderState.Rendition.readerView.rawValue
		]))

		XCTAssertTrue(lifecycle.accepts(webView: webView, state: matching.state))
		XCTAssertFalse(lifecycle.accepts(webView: webView, state: wrongArticle.state))
		XCTAssertFalse(lifecycle.accepts(webView: webView, state: wrongRendition.state))
	}

	func testRetainedTapRemovalStateIsRejectedAfterRenderChange() throws {
		let lifecycle = ArticleHighlightLifecycle()
		let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		let acceptedState = try XCTUnwrap(lifecycle.beginRender(
			webView: webView, articleKey: "article-key", rendition: .feedBody
		))
		let message = try XCTUnwrap(ArticleHighlightTapMessage(body: [
			"id": "00000000-0000-0000-0000-000000000007",
			"generation": acceptedState.generation,
			"articleKey": acceptedState.articleKey,
			"rendition": acceptedState.rendition.rawValue
		]))
		let request = ArticleHighlightRemovalRequest(id: message.id, renderState: message.renderState)
		var removeCount = 0
		let retainedAlertCallback = {
			request.performIfCurrent(isCurrent: { state in
				lifecycle.accepts(webView: webView, state: state)
			}) { _, _ in
				removeCount += 1
			}
		}
		_ = lifecycle.beginRender(webView: webView, articleKey: "next-article", rendition: .readerView)

		retainedAlertCallback()
		XCTAssertEqual(removeCount, 0)
	}

	func testPooledWebViewResetsDelegateAndCachedEligibilityWhenDetached() {
		let webView = PreloadedWebView(frame: .zero, configuration: WKWebViewConfiguration())
		let delegate = HighlightDelegate()
		webView.setHighlightDelegate(delegate)
		webView.updateHighlightSelectionEligibility(true)

		XCTAssertTrue(webView.hasHighlightDelegate)
		XCTAssertTrue(webView.cachedHighlightSelectionEligibility)

		webView.setHighlightDelegate(nil)

		XCTAssertFalse(webView.hasHighlightDelegate)
		XCTAssertFalse(webView.cachedHighlightSelectionEligibility)
	}
}

private extension ArticleHighlightControllerTests {
	enum TestError: Error, Equatable {
		case expected
	}

	final class HighlightDelegate: PreloadedWebViewHighlightDelegate {
		func preloadedWebViewCanHighlightCurrentSelection(_: PreloadedWebView) -> Bool { true }
		func preloadedWebViewDidRequestHighlight(_: PreloadedWebView) {}
	}
}
