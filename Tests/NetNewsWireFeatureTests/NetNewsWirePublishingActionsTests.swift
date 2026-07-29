import XCTest
@testable import NetNewsWireFeature

@MainActor
final class NetNewsWirePublishingActionsTests: XCTestCase {
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
			"selectedText", "title", "creator", "preferredURL"
		])
		assertSendable(capture)
	}

	func testPublishingIntentsArePlainSendableValues() {
		XCTAssertEqual(NetNewsWirePublishingIntent.capture, .capture)
		XCTAssertEqual(NetNewsWirePublishingIntent.post, .post)
		assertSendable(NetNewsWirePublishingIntent.capture)
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

		actions.send(expectedCapture, .post)

		XCTAssertEqual(receivedCapture, expectedCapture)
		XCTAssertEqual(receivedIntent, .post)
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
		XCTAssertEqual(titles.postLink, "Post Link...|Command")
		XCTAssertEqual(titles.captureSelection, "Capture Selection|Command")
		XCTAssertEqual(titles.postSelection, "Post Selection...|Command")
	}

	private func assertSendable<T: Sendable>(_ value: T) {}
}
