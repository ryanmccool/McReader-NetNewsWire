import Foundation
import Articles
import RSParser

public struct StarredArticleArchiveProvider: Codable, Equatable, Sendable {
	public let accountType: AccountType
	public let server: String?

	public init(accountType: AccountType, server: String?) {
		self.accountType = accountType
		self.server = Self.normalizedServer(server)
	}

	public func isCompatible(with destination: StarredArticleArchiveProvider) -> Bool {
		guard destination.accountType != .onMyMac else { return true }
		return accountType == destination.accountType && server == destination.server
	}

	private static func normalizedServer(_ value: String?) -> String? {
		guard let value else { return nil }
		let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines)).lowercased()
		return normalized.isEmpty ? nil : normalized
	}
}

public struct StarredArticleArchive: Codable, Equatable, Sendable {
	public static let jsonFeedVersion = "https://jsonfeed.org/version/1.1"
	public static let formatVersion = 1
	public static let maximumByteCount = 100 * 1_024 * 1_024
	public static let maximumItemCount = 10_000

	public let version: String
	public let title: String
	public let items: [Item]
	public let metadata: Metadata

	public init(title: String, items: [Item], provider: StarredArticleArchiveProvider, exportedAt: Date = .now) {
		self.version = Self.jsonFeedVersion
		self.title = title
		self.items = items
		self.metadata = Metadata(formatVersion: Self.formatVersion, provider: provider, exportedAt: exportedAt)
	}

	public func encoded() throws -> Data {
		guard items.count <= Self.maximumItemCount else { throw Error.tooManyItems }
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let data = try encoder.encode(self)
		guard data.count <= Self.maximumByteCount else { throw Error.fileTooLarge }
		return data
	}

	public static func decode(contentsOf url: URL) throws -> StarredArticleArchive {
		let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
		guard byteCount.map({ $0 <= maximumByteCount }) ?? false else { throw Error.fileTooLarge }
		return try decode(Data(contentsOf: url, options: .mappedIfSafe))
	}

	public static func decode(_ data: Data) throws -> StarredArticleArchive {
		guard data.count <= maximumByteCount else { throw Error.fileTooLarge }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let archive = try decoder.decode(Self.self, from: data)
		guard archive.version == jsonFeedVersion,
			archive.metadata.formatVersion == formatVersion else {
			throw Error.unsupportedVersion
		}
		guard archive.items.count <= maximumItemCount else { throw Error.tooManyItems }
		let identities = Set(archive.items.map { "\($0.metadata.feedURL)\n\($0.metadata.uniqueID)" })
		guard identities.count == archive.items.count else { throw Error.duplicateItems }
		return archive
	}

	public struct Metadata: Codable, Equatable, Sendable {
		public let formatVersion: Int
		public let provider: StarredArticleArchiveProvider
		public let exportedAt: Date
	}

	public struct Item: Codable, Equatable, Sendable {
		public let id: String
		public let url: String?
		public let externalURL: String?
		public let title: String?
		public let contentHTML: String?
		public let contentText: String?
		public let summary: String?
		public let image: String?
		public let datePublished: Date?
		public let dateModified: Date?
		public let authors: [Author]
		public let metadata: ItemMetadata

		public init(
			id: String,
			url: String?,
			externalURL: String?,
			title: String?,
			contentHTML: String?,
			contentText: String?,
			summary: String?,
			image: String?,
			datePublished: Date?,
			dateModified: Date?,
			authors: [Author],
			metadata: ItemMetadata
		) {
			self.id = id
			self.url = url
			self.externalURL = externalURL
			self.title = title
			self.contentHTML = contentHTML
			self.contentText = contentHTML == nil && contentText == nil ? summary ?? "" : contentText
			self.summary = summary
			self.image = image
			self.datePublished = datePublished
			self.dateModified = dateModified
			self.authors = authors
			self.metadata = metadata
		}

		enum CodingKeys: String, CodingKey {
			case id, url, title, summary, image, authors
			case externalURL = "external_url"
			case contentHTML = "content_html"
			case contentText = "content_text"
			case datePublished = "date_published"
			case dateModified = "date_modified"
			case metadata = "_static_evolution"
		}
	}

	public struct ItemMetadata: Codable, Equatable, Sendable {
		public let articleID: String
		public let uniqueID: String
		public let feedID: String
		public let feedURL: String
		public let feedTitle: String
		public let feedHomePageURL: String?
		public let dateArrived: Date
		public let read: Bool
		public let starred: Bool

		public init(articleID: String, uniqueID: String, feedID: String, feedURL: String, feedTitle: String, feedHomePageURL: String?, dateArrived: Date, read: Bool, starred: Bool = true) {
			self.articleID = articleID
			self.uniqueID = uniqueID
			self.feedID = feedID
			self.feedURL = feedURL
			self.feedTitle = feedTitle
			self.feedHomePageURL = feedHomePageURL
			self.dateArrived = dateArrived
			self.read = read
			self.starred = starred
		}
	}

	public struct Author: Codable, Equatable, Sendable {
		public let name: String?
		public let url: String?
		public let avatar: String?

		public init(name: String?, url: String?, avatar: String?) {
			self.name = name
			self.url = url
			self.avatar = avatar
		}
	}

	public enum Error: Swift.Error, LocalizedError, Equatable {
		case fileTooLarge
		case tooManyItems
		case unsupportedVersion
		case duplicateItems

		public var errorDescription: String? {
			switch self {
			case .fileTooLarge: "The starred-article archive is too large to import."
			case .tooManyItems: "The starred-article archive contains too many articles."
			case .unsupportedVersion: "This starred-article archive version isn’t supported."
			case .duplicateItems: "The starred-article archive contains duplicate articles."
			}
		}
	}

	enum CodingKeys: String, CodingKey {
		case version, title, items
		case metadata = "_static_evolution"
	}
}

public struct StarredArticleArchiveImportResult: Equatable, Sendable {
	public var added = 0
	public var updated = 0
	public var unchanged = 0
	public var rejected = 0
	public var upstreamSyncFailed = false

	public init() {}
}

public enum StarredArticleArchiveImportError: Error, LocalizedError, Equatable {
	case incompatibleProvider
	case importAlreadyRunning
	case accountRefreshing

	public var errorDescription: String? {
		switch self {
		case .incompatibleProvider: "Choose the local account or an account that uses the archive’s original feed service."
		case .importAlreadyRunning: "A starred-article import is already running for this account."
		case .accountRefreshing: "Starred articles can’t be imported while the selected account is refreshing."
		}
	}
}

@MainActor public extension Account {
	var starredArticleArchiveProvider: StarredArticleArchiveProvider {
		StarredArticleArchiveProvider(accountType: type, server: delegate.server)
	}

	func canImportStarredArticles(from archive: StarredArticleArchive) -> Bool {
		archive.metadata.provider.isCompatible(with: starredArticleArchiveProvider)
	}

	func makeStarredArticleArchive(exportedAt: Date = .now) async -> StarredArticleArchive {
		let articles = await fetchArticlesAsync(.starred())
		let items = articles.map { article in
			let feed = existingFeed(withFeedID: article.feedID)
			let sourceURL = Self.originalFeedURL(from: feed?.url) ?? feed?.url ?? article.feedID
			let metadata = StarredArticleArchive.ItemMetadata(
				articleID: article.articleID,
				uniqueID: article.uniqueID,
				feedID: article.feedID,
				feedURL: sourceURL,
				feedTitle: feed?.nameForDisplay ?? sourceURL,
				feedHomePageURL: feed?.homePageURL,
				dateArrived: article.status.dateArrived,
				read: article.status.read
			)
			return StarredArticleArchive.Item(
				id: "\(sourceURL)\n\(article.uniqueID)",
				url: article.rawLink,
				externalURL: article.rawExternalLink,
				title: article.title,
				contentHTML: article.contentHTML,
				contentText: article.contentText,
				summary: article.summary,
				image: article.rawImageLink,
				datePublished: article.datePublished,
				dateModified: article.dateModified,
				authors: (article.authors ?? []).map { .init(name: $0.name, url: $0.url, avatar: $0.avatarURL) },
				metadata: metadata
			)
		}.sorted { lhs, rhs in
			(lhs.datePublished ?? lhs.metadata.dateArrived) > (rhs.datePublished ?? rhs.metadata.dateArrived)
		}
		return StarredArticleArchive(
			title: "Starred Articles — \(nameForDisplay)",
			items: items,
			provider: starredArticleArchiveProvider,
			exportedAt: exportedAt
		)
	}

	func importStarredArticles(from archive: StarredArticleArchive) async throws -> StarredArticleArchiveImportResult {
		guard canImportStarredArticles(from: archive) else { throw StarredArticleArchiveImportError.incompatibleProvider }
		guard !starredArticleArchiveImportInProgress else { throw StarredArticleArchiveImportError.importAlreadyRunning }
		guard !refreshInProgress else { throw StarredArticleArchiveImportError.accountRefreshing }
		starredArticleArchiveImportInProgress = true
		defer { starredArticleArchiveImportInProgress = false }

		if type == .onMyMac {
			return try await importStarredArticlesLocally(from: archive)
		}
		return try await importStarredArticlesIntoProvider(from: archive)
	}
}

private extension Account {
	static let starredArticleArchiveFolderName = "Imported Starred Articles"
	static let starredArticleArchiveFolderExternalID = "netnewswire.starred-article-archive"
	static let starredArticleArchiveScheme = "nnw-starred-archive:"

	func importStarredArticlesLocally(from archive: StarredArticleArchive) async throws -> StarredArticleArchiveImportResult {
		var result = StarredArticleArchiveImportResult()
		guard let folder = ensureStarredArticleArchiveFolder() else {
			result.rejected = archive.items.count
			return result
		}

		for (feedURL, items) in Dictionary(grouping: archive.items, by: { $0.metadata.feedURL }) {
			let archiveFeedURL = Self.archiveFeedURL(for: feedURL)
			let feed: Feed
			if let existing = existingFeed(withURL: archiveFeedURL) {
				feed = existing
			} else if let first = items.first {
				feed = createFeed(with: first.metadata.feedTitle, url: archiveFeedURL, feedID: archiveFeedURL, homePageURL: first.metadata.feedHomePageURL)
				folder.addFeedToTreeAtTopLevel(feed)
			} else {
				continue
			}

			let validItems = items.filter(\.metadata.starred)
			result.rejected += items.count - validItems.count
			let parsedItems = Set(validItems.map { $0.parsedItem(feedID: feed.feedID, syncServiceID: nil) })
			let changes = await updateAsync(feedID: feed.feedID, parsedItems: parsedItems, deleteOlder: false)
			result.added += changes.new?.count ?? 0
			result.updated += changes.updated?.count ?? 0
			result.unchanged += max(0, validItems.count - (changes.new?.count ?? 0) - (changes.updated?.count ?? 0))

			let statusItems = validItems.map { item in
				(item, Article.calculatedArticleID(feedID: feed.feedID, uniqueID: item.metadata.uniqueID))
			}
			try await restoreArchiveStatuses(statusItems)
		}
		return result
	}

	func ensureStarredArticleArchiveFolder() -> Folder? {
		if let folder = existingFolder(withExternalID: Self.starredArticleArchiveFolderExternalID) {
			return folder
		}
		var name = Self.starredArticleArchiveFolderName
		var suffix = 2
		while existingFolder(with: name) != nil {
			name = "\(Self.starredArticleArchiveFolderName) (\(suffix))"
			suffix += 1
		}
		let folder = ensureFolder(with: name)
		folder?.externalID = Self.starredArticleArchiveFolderExternalID
		return folder
	}

	func importStarredArticlesIntoProvider(from archive: StarredArticleArchive) async throws -> StarredArticleArchiveImportResult {
		var result = StarredArticleArchiveImportResult()
		var parsedByFeedID = [String: Set<ParsedItem>]()
		var statusItems = [(StarredArticleArchive.Item, String)]()

		for item in archive.items {
			guard item.metadata.starred,
				let feed = existingFeed(withURL: item.metadata.feedURL),
				feed.feedID == item.metadata.feedID else {
				result.rejected += 1
				continue
			}
			parsedByFeedID[feed.feedID, default: []].insert(item.parsedItem(feedID: feed.feedID, syncServiceID: item.metadata.articleID))
			statusItems.append((item, item.metadata.articleID))
		}

		let changes = await updateAsync(feedIDsAndItems: parsedByFeedID, defaultRead: true)
		result.added = changes.new?.count ?? 0
		result.updated = changes.updated?.count ?? 0
		result.unchanged = max(0, statusItems.count - result.added - result.updated)
		try await restoreArchiveStatuses(statusItems)
		do {
			try await sendArticleStatus()
		} catch {
			result.upstreamSyncFailed = true
		}
		return result
	}

	func restoreArchiveStatuses(_ statusItems: [(StarredArticleArchive.Item, String)]) async throws {
		let starredIDs = Set(statusItems.map(\.1))
		let readIDs = Set(statusItems.filter { $0.0.metadata.read }.map(\.1))
		let unreadIDs = starredIDs.subtracting(readIDs)
		try await markArticles(articleIDs: starredIDs, statusKey: .starred, flag: true)
		try await markArticles(articleIDs: readIDs, statusKey: .read, flag: true)
		try await markArticles(articleIDs: unreadIDs, statusKey: .read, flag: false)
	}

	static func archiveFeedURL(for sourceURL: String) -> String {
		let data = Data(sourceURL.utf8).base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		return starredArticleArchiveScheme + data
	}

	static func originalFeedURL(from archiveURL: String?) -> String? {
		guard let archiveURL, archiveURL.hasPrefix(starredArticleArchiveScheme) else { return nil }
		var encoded = String(archiveURL.dropFirst(starredArticleArchiveScheme.count))
			.replacingOccurrences(of: "-", with: "+")
			.replacingOccurrences(of: "_", with: "/")
		encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
		guard let data = Data(base64Encoded: encoded) else { return nil }
		return String(data: data, encoding: .utf8)
	}
}

private extension StarredArticleArchive.Item {
	func parsedItem(feedID: String, syncServiceID: String?) -> ParsedItem {
		ParsedItem(
			syncServiceID: syncServiceID,
			uniqueID: metadata.uniqueID,
			feedURL: feedID,
			url: url,
			externalURL: externalURL,
			title: title,
			language: nil,
			contentHTML: contentHTML,
			contentText: contentText,
			markdown: nil,
			summary: summary,
			imageURL: image,
			bannerImageURL: nil,
			datePublished: datePublished,
			dateModified: dateModified,
			authors: Set(authors.map { ParsedAuthor(name: $0.name, url: $0.url, avatarURL: $0.avatar, emailAddress: nil) }),
			tags: nil,
			attachments: nil
		)
	}
}
