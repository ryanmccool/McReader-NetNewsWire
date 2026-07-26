//
//  CloudKitOPMLImportTests.swift
//  AccountTests
//

import XCTest
import RSParser
@testable import Account

final class CloudKitOPMLImportTests: XCTestCase {

	func testPlannerRejectsEmptyPlan() {
		XCTAssertThrowsError(try CloudKitOPMLPlanner.makePlan(items: []))
	}

	func testPlannerRejectsInvalidRelativeAndFileURLs() {
		for urlString in ["not a url", "/relative/feed", "file:///tmp/feed.xml"] {
			XCTAssertThrowsError(try CloudKitOPMLPlanner.makePlan(items: [feed(urlString)]), urlString)
		}
	}

	func testPlannerCollapsesExactDuplicates() throws {
		let plan = try CloudKitOPMLPlanner.makePlan(items: [
			feed("https://example.com/feed", title: "First"),
			feed("https://example.com/feed", title: "Second")
		])

		XCTAssertEqual(plan.feeds, [
			PlannedCloudKitFeed(
				urlString: "https://example.com/feed",
				editedName: "First",
				homePageURL: nil,
				isTopLevel: true,
				folderNames: []
			)
		])
	}

	func testPlannerUnionsExactDuplicatePlacements() throws {
		let items = [
			folder("A", feed("https://example.com/feed")),
			folder("B", feed("https://example.com/feed")),
			feed("https://example.com/feed")
		]

		let plan = try CloudKitOPMLPlanner.makePlan(items: items)

		XCTAssertEqual(plan.feeds.count, 1)
		XCTAssertTrue(plan.feeds[0].isTopLevel)
		XCTAssertEqual(plan.feeds[0].folderNames, Set(["A", "B"]))
	}

	func testPlannerPreservesExactStringDistinctions() throws {
		let plan = try CloudKitOPMLPlanner.makePlan(items: [
			feed("https://example.com/feed"),
			feed("https://example.com/feed/"),
			feed("https://EXAMPLE.com/feed")
		])

		XCTAssertEqual(plan.feeds.map(\.urlString), [
			"https://example.com/feed",
			"https://example.com/feed/",
			"https://EXAMPLE.com/feed"
		])
	}

	private func feed(_ urlString: String, title: String? = nil, homePageURL: String? = nil) -> OPMLItem {
		var attributes = ["xmlUrl": urlString]
		attributes["title"] = title
		attributes["htmlUrl"] = homePageURL
		return OPMLItem(attributes: attributes)
	}

	private func folder(_ name: String, _ children: OPMLItem...) -> OPMLItem {
		let item = OPMLItem(attributes: ["title": name])
		children.forEach(item.addChild)
		return item
	}
}
