//
//  CloudKitOPMLImport.swift
//  Account
//

import Foundation
import RSParser

public struct OPMLImportResult: Sendable, Equatable {

	public var added = 0
	public var updated = 0
	public var unchanged = 0
	public var repositioned = 0
	public var rejected = 0
	public var committedButNotApplied = false
}

public struct OPMLImportPartialFailure: Error {

	public let result: OPMLImportResult
	public let underlyingError: Error

	init(result: OPMLImportResult, underlyingError: Error) {
		self.result = result
		self.underlyingError = underlyingError
	}
}

struct CloudKitOPMLImportPlan: Sendable, Equatable {

	let feeds: [PlannedCloudKitFeed]
	let rejectedCount: Int
}

struct PlannedCloudKitFeed: Sendable, Equatable {

	let urlString: String
	let editedName: String?
	let homePageURL: String?
	let isTopLevel: Bool
	let folderNames: Set<String>
}

struct CloudKitFeedUpsertResult: Sendable, Equatable {

	let wasAdded: Bool
	let metadataChanged: Bool
	let placementChanged: Bool

	var isUnchanged: Bool {
		!wasAdded && !metadataChanged && !placementChanged
	}
}

enum CloudKitOPMLPlanner {

	static func makePlan(items: [OPMLItem]) throws -> CloudKitOPMLImportPlan {
		var feeds = [PlannedCloudKitFeed]()
		var indexesByURL = [String: Int]()
		var rejectedCount = 0

		func add(_ item: OPMLItem, folderName: String?) throws {
			if let specifier = item.feedSpecifier {
				do {
					try validateFeedURL(specifier.feedURL)
				} catch AccountError.invalidParameter {
					rejectedCount += 1
					return
				}

				if let index = indexesByURL[specifier.feedURL] {
					let existing = feeds[index]
					var folderNames = existing.folderNames
					if let folderName {
						folderNames.insert(folderName)
					}
					feeds[index] = PlannedCloudKitFeed(
						urlString: existing.urlString,
						editedName: existing.editedName,
						homePageURL: existing.homePageURL,
						isTopLevel: existing.isTopLevel || folderName == nil,
						folderNames: folderNames
					)
					return
				}

				indexesByURL[specifier.feedURL] = feeds.count
				feeds.append(PlannedCloudKitFeed(
					urlString: specifier.feedURL,
					editedName: specifier.title,
					homePageURL: specifier.homePageURL,
					isTopLevel: folderName == nil,
					folderNames: folderName.map { [$0] } ?? []
				))
				return
			}

			let childFolderName = item.titleFromAttributes ?? folderName
			for child in item.children ?? [] {
				try add(child, folderName: childFolderName)
			}
		}

		for item in items {
			try add(item, folderName: nil)
		}

		guard !feeds.isEmpty else {
			throw AccountError.invalidParameter
		}
		return CloudKitOPMLImportPlan(feeds: feeds, rejectedCount: rejectedCount)
	}

	private static func validateFeedURL(_ urlString: String) throws {
		guard let url = URL(string: urlString),
			url.absoluteString == urlString,
			let components = URLComponents(string: urlString),
			let scheme = components.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			let host = components.host,
			!host.isEmpty else {
			throw AccountError.invalidParameter
		}
	}
}
