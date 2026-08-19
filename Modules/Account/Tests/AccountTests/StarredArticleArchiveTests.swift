import XCTest
import RSCore
@testable import Account

@MainActor
final class StarredArticleArchiveTests: XCTestCase {
	private var account: Account!

	override func setUp() async throws {
		if NetNewsWireEnvironment.current == nil {
			let root = FileManager.default.temporaryDirectory.appendingPathComponent("Account-Starred-Archive-Tests", isDirectory: true)
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			try NetNewsWireEnvironment.configure(.init(
				mode: .embedded,
				dataDirectoryURL: root.appendingPathComponent("Data", isDirectory: true),
				cacheDirectoryURL: root.appendingPathComponent("Cache", isDirectory: true),
				userDefaultsSuiteName: "Account.StarredArchiveTests",
				cloudKitContainerIdentifier: "iCloud.example.tests",
				resourceBundle: .main
			))
		}
		account = TestAccountManager.shared.createAccount(type: .onMyMac)
	}

	override func tearDown() async throws {
		TestAccountManager.shared.deleteAccount(account)
		account = nil
	}

	func testCodecUsesJSONFeedAndRoundTripsExtensionMetadata() throws {
		let archive = makeArchive(provider: .init(accountType: .feedly, server: "HTTPS://API.FEEDLY.COM/"))
		let data = try archive.encoded()
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

		XCTAssertEqual(object["version"] as? String, StarredArticleArchive.jsonFeedVersion)
		XCTAssertNotNil(object["_static_evolution"])
		XCTAssertEqual(try StarredArticleArchive.decode(data), archive)
		XCTAssertEqual(archive.metadata.provider.server, "https://api.feedly.com")
	}

	func testProviderCompatibilityAllowsLocalAndRequiresMatchingServiceAndServer() {
		let source = StarredArticleArchiveProvider(accountType: .freshRSS, server: "https://feeds.example.com/")

		XCTAssertTrue(source.isCompatible(with: .init(accountType: .onMyMac, server: nil)))
		XCTAssertTrue(source.isCompatible(with: .init(accountType: .freshRSS, server: "HTTPS://FEEDS.EXAMPLE.COM")))
		XCTAssertFalse(source.isCompatible(with: .init(accountType: .freshRSS, server: "https://other.example.com")))
		XCTAssertFalse(source.isCompatible(with: .init(accountType: .feedly, server: "https://feeds.example.com")))
	}

	func testDecoderRejectsDuplicatePortableArticleIdentities() throws {
		let item = makeItem()
		let duplicate = StarredArticleArchive.Item(
			id: "another-id",
			url: item.url,
			externalURL: item.externalURL,
			title: item.title,
			contentHTML: item.contentHTML,
			contentText: item.contentText,
			summary: item.summary,
			image: item.image,
			datePublished: item.datePublished,
			dateModified: item.dateModified,
			authors: item.authors,
			metadata: item.metadata
		)
		let archive = StarredArticleArchive(title: "Duplicates", items: [item, duplicate], provider: .init(accountType: .onMyMac, server: nil))

		XCTAssertThrowsError(try StarredArticleArchive.decode(archive.encoded())) { error in
			XCTAssertEqual(error as? StarredArticleArchive.Error, .duplicateItems)
		}
	}

	func testLocalImportCreatesVisibleStarredArticlesWithoutExportingArchiveFeedsAsSubscriptions() async throws {
		let archive = makeArchive(provider: .init(accountType: .feedbin, server: "api.feedbin.com"))

		let result = try await account.importStarredArticles(from: archive)
		let articles = await account.fetchArticlesAsync(.starred())

		XCTAssertEqual(result.added, 1)
		XCTAssertEqual(result.rejected, 0)
		XCTAssertEqual(articles.count, 1)
		XCTAssertEqual(articles.first?.title, "A Saved Article")
		XCTAssertEqual(articles.first?.status.read, false)
		XCTAssertNotNil(account.existingFolder(withExternalID: "netnewswire.starred-article-archive"))
		XCTAssertFalse(account.OPMLString(indentLevel: 0, allowCustomAttributes: false).contains("nnw-starred-archive:"))
		XCTAssertTrue(account.OPMLString(indentLevel: 0, allowCustomAttributes: true).contains("nnw-starred-archive:"))
	}

	func testLocalReimportIsIdempotentAndCanBeExportedAgain() async throws {
		let archive = makeArchive(provider: .init(accountType: .cloudKit, server: nil))
		_ = try await account.importStarredArticles(from: archive)

		let secondResult = try await account.importStarredArticles(from: archive)
		let exported = await account.makeStarredArticleArchive(exportedAt: archive.metadata.exportedAt)

		XCTAssertEqual(secondResult.added, 0)
		XCTAssertEqual(secondResult.updated, 0)
		XCTAssertEqual(secondResult.unchanged, 1)
		XCTAssertEqual(exported.items.count, 1)
		XCTAssertEqual(exported.items.first?.metadata.feedURL, "https://example.com/feed.xml")
		XCTAssertEqual(exported.items.first?.metadata.uniqueID, "article-guid")
	}

	func testLocalImportDoesNotAdoptAUserFolderWithTheArchiveDisplayName() async throws {
		let userFolder = account.ensureFolder(with: "Imported Starred Articles")
		let archive = makeArchive(provider: .init(accountType: .feedly, server: "api.feedly.com"))

		_ = try await account.importStarredArticles(from: archive)
		let archiveFolder = account.existingFolder(withExternalID: "netnewswire.starred-article-archive")

		XCTAssertNotNil(userFolder)
		XCTAssertNotNil(archiveFolder)
		XCTAssertFalse(userFolder === archiveFolder)
		XCTAssertEqual(archiveFolder?.nameForDisplay, "Imported Starred Articles (2)")
	}

	func testOrdinaryFeedMovedIntoArchiveFolderRemainsInSubscriptionExport() async throws {
		_ = try await account.importStarredArticles(from: makeArchive(provider: .init(accountType: .onMyMac, server: nil)))
		let archiveFolder = try XCTUnwrap(account.existingFolder(withExternalID: "netnewswire.starred-article-archive"))
		let ordinaryFeed = account.createFeed(with: "Ordinary", url: "https://ordinary.example/feed", feedID: "https://ordinary.example/feed", homePageURL: nil)
		archiveFolder.addFeedToTreeAtTopLevel(ordinaryFeed)

		let exportedOPML = account.OPMLString(indentLevel: 0, allowCustomAttributes: false)

		XCTAssertTrue(exportedOPML.contains("https://ordinary.example/feed"))
		XCTAssertFalse(exportedOPML.contains("nnw-starred-archive:"))
	}

	func testImportRejectsItemsNotMarkedStarred() async throws {
		let item = makeItem(starred: false)
		let archive = StarredArticleArchive(
			title: "Invalid",
			items: [item],
			provider: .init(accountType: .feedly, server: "api.feedly.com")
		)

		let result = try await account.importStarredArticles(from: archive)
		let articles = await account.fetchArticlesAsync(.starred())

		XCTAssertEqual(result.rejected, 1)
		XCTAssertTrue(articles.isEmpty)
	}

	private func makeArchive(provider: StarredArticleArchiveProvider) -> StarredArticleArchive {
		StarredArticleArchive(
			title: "Saved",
			items: [makeItem()],
			provider: provider,
			exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
	}

	private func makeItem(starred: Bool = true) -> StarredArticleArchive.Item {
		StarredArticleArchive.Item(
			id: "https://example.com/feed.xml\narticle-guid",
			url: "https://example.com/article",
			externalURL: nil,
			title: "A Saved Article",
			contentHTML: "<p>Saved body</p>",
			contentText: "Saved body",
			summary: "Summary",
			image: "https://example.com/image.jpg",
			datePublished: Date(timeIntervalSince1970: 1_699_000_000),
			dateModified: nil,
			authors: [.init(name: "Writer", url: nil, avatar: nil)],
			metadata: .init(
				articleID: "provider-article-id",
				uniqueID: "article-guid",
				feedID: "provider-feed-id",
				feedURL: "https://example.com/feed.xml",
				feedTitle: "Example Feed",
				feedHomePageURL: "https://example.com",
				dateArrived: Date(timeIntervalSince1970: 1_699_000_100),
				read: false,
				starred: starred
			)
		)
	}
}
