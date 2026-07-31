import XCTest
@testable import NetNewsWireFeature

@MainActor
final class NetNewsWireHighlightActionsTests: XCTestCase {
	func testRecordExportsEveryPlainHighlightValue() {
		let id = UUID()
		let domRangeData = Data([0x01, 0x02])
		let preferredURL = URL(string: "https://example.com/article")!
		let createdAt = Date(timeIntervalSince1970: 100)
		let updatedAt = Date(timeIntervalSince1970: 200)
		let record = NetNewsWireHighlightRecord(
			id: id,
			articleKey: "account:article",
			selectedText: "Selection",
			prefixContext: "Before ",
			suffixContext: " after",
			startOffset: 7,
			endOffset: 16,
			domRangeData: domRangeData,
			renditionKindRaw: "feedHTML",
			renderedTextFingerprint: "fingerprint",
			articleTitle: "Article",
			creator: "Author",
			preferredURL: preferredURL,
			createdAt: createdAt,
			updatedAt: updatedAt
		)

		XCTAssertEqual(record.id, id)
		XCTAssertEqual(record.articleKey, "account:article")
		XCTAssertEqual(record.selectedText, "Selection")
		XCTAssertEqual(record.prefixContext, "Before ")
		XCTAssertEqual(record.suffixContext, " after")
		XCTAssertEqual(record.startOffset, 7)
		XCTAssertEqual(record.endOffset, 16)
		XCTAssertEqual(record.domRangeData, domRangeData)
		XCTAssertEqual(record.renditionKindRaw, "feedHTML")
		XCTAssertEqual(record.renderedTextFingerprint, "fingerprint")
		XCTAssertEqual(record.articleTitle, "Article")
		XCTAssertEqual(record.creator, "Author")
		XCTAssertEqual(record.preferredURL, preferredURL)
		XCTAssertEqual(record.createdAt, createdAt)
		XCTAssertEqual(record.updatedAt, updatedAt)
		assertSendable(record)
	}

	func testObservationCancellationIsIdempotent() {
		var cancellationCount = 0
		let observation = NetNewsWireHighlightObservation {
			cancellationCount += 1
		}

		observation.cancel()
		observation.cancel()

		XCTAssertEqual(cancellationCount, 1)
	}

	func testDisabledActionsReportUnavailable() async {
		let actions = NetNewsWireHighlightActions.disabled
		var failureCount = 0

		XCTAssertFalse(actions.isEnabled)
		await assertUnavailable { try await actions.load("article") }
		await assertUnavailable { try await actions.insert(Self.makeRecord()) }
		await assertUnavailable { try await actions.delete(UUID()) }

		let observation = actions.observe("article", { _ in
			XCTFail("Disabled observation must not emit records.")
		}, {
			failureCount += 1
		})
		observation.cancel()
		observation.cancel()

		XCTAssertEqual(failureCount, 1)
	}

	func testArticleConstructionKeepsInjectedActionsForEveryWebController() async throws {
		var injectedLoadCount = 0
		var otherLoadCount = 0
		let injectedActions = makeActions {
			injectedLoadCount += 1
		}
		let otherActions = makeActions {
			otherLoadCount += 1
		}
		let articleController = ArticleViewController.instantiate(
			from: .main,
			highlightActions: injectedActions
		)

		let currentController = articleController.createWebViewController(nil)
		let prefetchedController = articleController.createWebViewController(nil, updateView: false)
		let separatelyConstructedController = WebViewController(highlightActions: otherActions)
		_ = try await currentController.highlightActions.load("current")
		_ = try await prefetchedController.highlightActions.load("prefetched")
		_ = try await separatelyConstructedController.highlightActions.load("other")

		XCTAssertEqual(injectedLoadCount, 2)
		XCTAssertEqual(otherLoadCount, 1)
	}

	private func assertUnavailable<T>(operation: () async throws -> T) async {
		do {
			_ = try await operation()
			XCTFail("Expected unavailable error.")
		} catch {
			XCTAssertEqual(error as? NetNewsWireHighlightActionError, .unavailable)
		}
	}

	private static func makeRecord() -> NetNewsWireHighlightRecord {
		NetNewsWireHighlightRecord(
			id: UUID(), articleKey: "article", selectedText: "Selection",
			prefixContext: "", suffixContext: "", startOffset: 0, endOffset: 9,
			domRangeData: nil, renditionKindRaw: "feedHTML",
			renderedTextFingerprint: "fingerprint", articleTitle: "Article",
			creator: nil, preferredURL: nil, createdAt: .now, updatedAt: .now
		)
	}

	private func makeActions(didLoad: @escaping () -> Void) -> NetNewsWireHighlightActions {
		NetNewsWireHighlightActions(
			load: { _ in
				didLoad()
				return []
			},
			insert: { _ in },
			delete: { _ in },
			observe: { _, _, _ in NetNewsWireHighlightObservation(cancel: {}) }
		)
	}

	private func assertSendable<T: Sendable>(_ value: T) {}
}
