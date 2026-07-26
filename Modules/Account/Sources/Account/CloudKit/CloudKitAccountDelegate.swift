//
//  CloudKitAppDelegate.swift
//  Account
//
//  Created by Maurice Parker on 3/18/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import CloudKit
import ErrorLog
import SystemConfiguration
import os
import ActivityLog
import RSCore
import RSParser
import RSWeb
import SyncDatabase

private struct SendableUserDefaults: @unchecked Sendable {
	let value: UserDefaults
}

@MainActor struct CloudKitZoneFactory {
	static func makeZones(
		container: CKContainer?,
		userDefaults: UserDefaults,
		syncArticleContentForUnreadArticles: @escaping @Sendable () -> Bool
	) -> (account: CloudKitAccountZone, articles: CloudKitArticlesZone) {
		(
			CloudKitAccountZone(container: container, userDefaults: userDefaults),
			CloudKitArticlesZone(
				container: container,
				userDefaults: userDefaults,
				syncArticleContentForUnreadArticles: syncArticleContentForUnreadArticles
			)
		)
	}
}
import Articles
import ArticlesDatabase
import Secrets
import CloudKitSync
import FeedFinder

/// Parameters: (error, operation, fileName, functionName, lineNumber)
typealias CloudKitSyncErrorHandler = @Sendable (Error, String, String, String, Int) -> Void

enum CloudKitAccountDelegateError: LocalizedError, Equatable, Sendable {
	case invalidParameter
	case containerUnavailable
	case importUnavailableWhileRefreshing
	case accountNotReady
	case feedDeletedCleanupFailed
	case resetVerificationFailed
	case unknown

	var errorDescription: String? {
		switch self {
		case .containerUnavailable:
			return NSLocalizedString("The iCloud container for feeds is unavailable. Check iCloud access and try again.", comment: "Feeds CloudKit container unavailable.")
		case .importUnavailableWhileRefreshing:
			return NNWLocalizedString("Subscriptions can’t be imported while the iCloud account is refreshing. Wait for the refresh to finish and try again.", comment: "Feeds CloudKit OPML import blocked by refresh.")
		case .accountNotReady:
			return NNWLocalizedString("The iCloud account is still being prepared. Wait a moment and try importing subscriptions again.", comment: "Feeds CloudKit account not ready for OPML import.")
		case .feedDeletedCleanupFailed:
			return NNWLocalizedString("The feed was removed, but its iCloud article cleanup failed. Try again later.", comment: "Feeds CloudKit feed deletion cleanup failed.")
		case .resetVerificationFailed:
			return NNWLocalizedString("The iCloud feed reset did not produce an empty account. Retry the reset.", comment: "Feeds CloudKit reset verification failed.")
		case .invalidParameter, .unknown:
			return NSLocalizedString("An unexpected CloudKit error occurred.", comment: "An unexpected CloudKit error occurred.")
		}
	}

	static func userVisibleError(for error: Error) -> Error {
		let underlyingError = (error as? CloudKitError)?.error ?? error
		let nsError = underlyingError as NSError
		guard nsError.domain == CKErrorDomain,
			let code = CKError.Code(rawValue: nsError.code),
			[.badContainer, .missingEntitlement, .notAuthenticated, .permissionFailure].contains(code) else {
			return error
		}
		return CloudKitAccountDelegateError.containerUnavailable
	}
}

public func cloudKitAccountUserVisibleError(_ error: Error) -> Error {
	CloudKitAccountDelegateError.userVisibleError(for: error)
}

@MainActor public enum CloudKitAccountContainerConfiguration {
	public static let feedsContainerIdentifier = "iCloud.ryanmccool.McReader.Feeds"
	private static var configuredContainer: CKContainer?

	public static func configure(identifier: String) throws {
		guard identifier.hasPrefix("iCloud."), identifier.count > "iCloud.".count else {
			throw CloudKitAccountDelegateError.containerUnavailable
		}
		configuredContainer = CKContainer(identifier: identifier)
	}

	static var container: CKContainer? {
		configuredContainer
	}

	static func isResetContainerIdentifier(_ identifier: String?) -> Bool {
		identifier == feedsContainerIdentifier
	}

	static func isResetAvailable(isEmbedded: Bool, containerIdentifier: String?) -> Bool {
		isEmbedded && isResetContainerIdentifier(containerIdentifier)
	}

	static var resetIsAvailable: Bool {
		guard let environment = NetNewsWireEnvironment.current else {
			return false
		}
		guard case .embedded = environment.mode else {
			return false
		}
		return isResetContainerIdentifier(environment.cloudKitContainerIdentifier)
	}

	static func resolve<Container>(
		configured: Container?,
		defaultContainer: () -> Container
	) -> Container {
		configured ?? defaultContainer()
	}
}

@MainActor final class CloudKitAccountDelegate: AccountDelegate {
	nonisolated private static let logger = cloudKitLogger

	private let syncDatabase: SyncDatabase

	private let container: CKContainer

	private let accountZone: CloudKitAccountZone
	private let articlesZone: CloudKitArticlesZone
	private let syncArticleContentForUnreadArticles: @Sendable () -> Bool

	private let mainThreadOperationQueue = MainThreadOperationQueue()
	private let refresher: LocalAccountRefresher
	private let mutationGate: CloudKitAccountMutationGate
	private var initialSetupTask: Task<Void, Error>?
	private var syncErrorHandler: CloudKitSyncErrorHandler?

	private var lastNoChangeSyncDate: Date?
	private static let noChangeBackoffInterval: TimeInterval = 30 * 60

	weak var account: Account?

	let behaviors: AccountBehaviors = []
	var isOPMLImportInProgress: Bool {
		mutationGate.activeKind == .importOPML
	}

	let server: String? = nil
	var credentials: Credentials?
	var accountSettings: AccountSettings?

	var progressInfo = ProgressInfo() {
		didSet {
			if progressInfo != oldValue {
				postProgressInfoDidChangeNotification()
			}
		}
	}

	private let syncProgress = RSProgress()
	private var syncProgressInfo = ProgressInfo() {
		didSet {
			updateProgress()
		}
	}

	private var refreshProgressInfo = ProgressInfo() {
		didSet {
			updateProgress()
		}
	}

	init(dataFolder: String, mutationGate: CloudKitAccountMutationGate? = nil) {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		self.mutationGate = mutationGate ?? CloudKitAccountMutationGate()
		self.container = CloudKitAccountContainerConfiguration.resolve(
			configured: CloudKitAccountContainerConfiguration.container,
			defaultContainer: CKContainer.default
		)
		let defaults = AppConfig.defaults
		let sendableDefaults = SendableUserDefaults(value: defaults)
		let syncArticleContentForUnreadArticles: @Sendable () -> Bool = {
			sendableDefaults.value.bool(forKey: AccountManager.syncArticleContentForUnreadArticlesKey)
		}
		let zones = CloudKitZoneFactory.makeZones(
			container: container,
			userDefaults: defaults,
			syncArticleContentForUnreadArticles: syncArticleContentForUnreadArticles
		)
		self.syncArticleContentForUnreadArticles = syncArticleContentForUnreadArticles
		self.accountZone = zones.account
		self.articlesZone = zones.articles

		let databaseFilePath = (dataFolder as NSString).appendingPathComponent("Sync.sqlite3")
		self.syncDatabase = SyncDatabase(databasePath: databaseFilePath)

		self.refresher = LocalAccountRefresher()
		self.refresher.delegate = self

		NotificationCenter.default.addObserver(self, selector: #selector(refreshProgressDidChange(_:)), name: .progressInfoDidChange, object: refresher)
		NotificationCenter.default.addObserver(self, selector: #selector(syncProgressDidChange(_:)), name: .progressInfoDidChange, object: syncProgress)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func receiveRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
		do {
			return try await mutationGate.withMutation(kind: .remoteNotification) {
				await self.receiveRemoteNotificationImpl(userInfo: userInfo)
			}
		} catch {
			return false
		}
	}

	private func receiveRemoteNotificationImpl(userInfo: [AnyHashable: Any]) async -> Bool {
		guard let account else {
			return false
		}
		lastNoChangeSyncDate = nil
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		ActivityLog.shared.logCompletedActivity(owner: account.activityOwner, kind: .receiveCloudKitNotification)

		return await withCheckedContinuation { continuation in
			let op = CloudKitRemoteNotificationOperation(accountZone: accountZone, articlesZone: articlesZone, accountID: account.accountID, accountDisplayName: account.nameForDisplay, userInfo: userInfo)
			op.completionBlock = { _ in
				Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
				if let error = op.notificationError {
					self.postSyncError(error, account: account, operation: "Receiving iCloud changes")
					continuation.resume(returning: false)
				} else {
					continuation.resume(returning: op.notificationResult.didChange)
				}
			}
			mainThreadOperationQueue.add(op)
		}
	}

	func refreshAll() async throws {
		try await mutationGate.withMutation(kind: .refresh) {
			try await self.refreshAllImpl()
		}
	}

	private func refreshAllImpl() async throws {
		guard let account else {
			return
		}
		guard refreshProgressInfo.isComplete else {
			return
		}

		syncProgress.reset()

		guard NetworkMonitor.shared.isConnected else {
			return
		}

		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		try await standardRefreshAll(for: account)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func syncArticleStatus() async throws -> Bool {
		try await mutationGate.withMutation(kind: .articleStatus) {
			try await self.syncArticleStatusImpl()
		}
	}

	private func syncArticleStatusImpl() async throws -> Bool {
		guard let account else {
			return false
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")

		if let lastNoChangeSyncDate, Date().timeIntervalSince(lastNoChangeSyncDate) < Self.noChangeBackoffInterval {
			Self.logger.debug("CloudKitAccountDelegate: Skipping sync — no changes on last check, backing off")
			return false
		}

		let sentCount = try await sendArticleStatusImpl(account: account, showProgress: false)
		try await refreshArticleStatusImpl()

		let didReceiveChanges = !(articlesZoneHasNoChanges && accountZoneHasNoChanges)
		let didWork = sentCount > 0 || didReceiveChanges
		if didWork {
			lastNoChangeSyncDate = nil
		} else {
			lastNoChangeSyncDate = Date()
		}

		await cleanUpContentRecordsIfNeeded()
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		return didWork
	}

	private var articlesZoneHasNoChanges: Bool {
		guard let delegate = articlesZone.delegate as? CloudKitArticlesZoneDelegate else {
			return true
		}
		return delegate.lastChangedCount == 0 && delegate.lastDeletedCount == 0
	}

	private var accountZoneHasNoChanges: Bool {
		guard let delegate = accountZone.delegate as? CloudKitAcountZoneDelegate else {
			return true
		}
		return delegate.lastChangedCount == 0 && delegate.lastDeletedCount == 0
	}

	func sendArticleStatus() async throws {
		try await mutationGate.withMutation(kind: .articleStatus) {
			try await self.sendArticleStatusImpl()
		}
	}

	private func sendArticleStatusImpl() async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		_ = try await sendArticleStatusImpl(account: account, showProgress: false)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func refreshArticleStatus() async throws {
		try await mutationGate.withMutation(kind: .articleStatus) {
			try await self.refreshArticleStatusImpl()
		}
	}

	private func refreshArticleStatusImpl() async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			let op = CloudKitReceiveStatusOperation(articlesZone: articlesZone, accountID: account.accountID, accountDisplayName: account.nameForDisplay)
			op.completionBlock = { mainThreadOperation in
				Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
				if let receiveError = op.receiveError {
					continuation.resume(throwing: receiveError)
				} else if mainThreadOperation.isCanceled {
					continuation.resume(throwing: CloudKitAccountDelegateError.unknown)
				} else {
					continuation.resume(returning: ())
				}
			}
			mainThreadOperationQueue.add(op)
		}
	}

	func importOPML(opmlFile: URL) async throws -> OPMLImportResult {
		try await mutationGate.withMutation(kind: .importOPML) {
			try await self.importOPMLImpl(opmlFile: opmlFile)
		}
	}

	private func importOPMLImpl(opmlFile: URL) async throws -> OPMLImportResult {
		guard let account else {
			throw AccountError.invalidParameter
		}
		let rootExternalID = try Self.opmlImportRootExternalID(
			refreshIsComplete: refreshProgressInfo.isComplete,
			syncIsComplete: syncProgressInfo.isComplete,
			rootExternalID: account.externalID
		)

		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		let opmlData = try Data(contentsOf: opmlFile)
		let parserData = ParserData(url: opmlFile.absoluteString, data: opmlData)
		let opmlDocument = try OPMLParser.parseOPML(with: parserData)

		guard let opmlItems = opmlDocument.children else {
			throw AccountError.invalidParameter
		}
		let normalizedItems = OPMLNormalizer.normalize(opmlItems)
		let plan = try CloudKitOPMLPlanner.makePlan(items: normalizedItems)

		syncProgress.addTask()
		defer {
			syncProgress.completeTask()
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		}

		do {
			return try await Self.performOPMLImport(
				save: {
					try await account.logActivity(kind: .importOPML, detail: opmlFile.lastPathComponent) {
						try await self.accountZone.importOPML(rootExternalID: rootExternalID, plan: plan)
					}
				},
				refresh: { try await self.standardRefreshAll(for: account) },
				verify: { Self.opmlImportHasConverged(account: account, rootExternalID: rootExternalID, plan: plan) },
				reportRefreshError: { self.postSyncError($0, account: account, operation: "Refreshing after OPML import") }
			)
		} catch {
			postSyncError(error, account: account, operation: "Importing OPML")
			throw error
		}
	}

	static func performOPMLImport(
		save: () async throws -> OPMLImportResult,
		refresh: () async throws -> Void,
		verify: () -> Bool,
		reportRefreshError: (Error) -> Void
	) async throws -> OPMLImportResult {
		var result = try await save()
		do {
			try await refresh()
			guard verify() else {
				throw CloudKitAccountDelegateError.unknown
			}
		} catch {
			reportRefreshError(error)
			result.committedButNotApplied = !verify()
		}
		return result
	}

	static func opmlImportHasConverged(account: Account, rootExternalID: String, plan: CloudKitOPMLImportPlan) -> Bool {
		for plannedFeed in plan.feeds {
			guard let feed = account.flattenedFeeds().first(where: {
				$0.url == plannedFeed.urlString && $0.externalID == plannedFeed.urlString.md5String
			}) else {
				return false
			}

			var expectedPlacements = Set<String>()
			if plannedFeed.isTopLevel {
				expectedPlacements.insert(rootExternalID)
			}
			for folderName in plannedFeed.folderNames {
				let matches = (account.folders ?? []).filter { $0.name == folderName }
				guard matches.count == 1, let externalID = matches.first?.externalID else {
					return false
				}
				expectedPlacements.insert(externalID)
			}

			let actualPlacements = Set(account.existingContainers(withFeed: feed).compactMap(\.externalID))
			guard actualPlacements == expectedPlacements else {
				return false
			}
		}
		return true
	}

	static func opmlImportRootExternalID(
		refreshIsComplete: Bool,
		syncIsComplete: Bool,
		rootExternalID: String?
	) throws -> String {
		guard refreshIsComplete, syncIsComplete else {
			throw CloudKitAccountDelegateError.importUnavailableWhileRefreshing
		}
		guard let rootExternalID else {
			throw CloudKitAccountDelegateError.accountNotReady
		}
		return rootExternalID
	}

	@discardableResult
	func createFeed(url urlString: String, name: String?, container: Container, validateFeed: Bool) async throws -> Feed {
		try await mutationGate.withMutation(kind: .feed) {
			try await self.createFeedImpl(url: urlString, name: name, container: container, validateFeed: validateFeed)
		}
	}

	private func createFeedImpl(url urlString: String, name: String?, container: Container, validateFeed: Bool) async throws -> Feed {
		guard let account else {
			throw AccountError.invalidParameter
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) url: \(urlString)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete url: \(urlString)")
		}
		guard let url = URL(string: urlString) else {
			throw AccountError.invalidParameter
		}

		let editedName = name == nil || name!.isEmpty ? nil : name
		return try await account.logActivity(kind: .subscribeFeed, detail: urlString) {
			try await createRSSFeed(for: account, url: url, editedName: editedName, container: container, validateFeed: validateFeed)
		}
	}

	func renameFeed(with feed: Feed, to name: String) async throws {
		try await mutationGate.withMutation(kind: .feed) {
			try await self.renameFeedImpl(with: feed, to: name)
		}
	}

	private func renameFeedImpl(with feed: Feed, to name: String) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		let editedName = name.isEmpty ? nil : name
		syncProgress.addTask()
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
			syncProgress.completeTask()
		}

		do {
			try await account.logActivity(kind: .renameFeed, detail: feed.url) {
				try await accountZone.renameFeed(feed, editedName: editedName)
				feed.editedName = name
			}
		} catch {
			postSyncError(error, account: account, operation: "Renaming feed")
			throw error
		}
	}

	func removeFeed(feed: Feed, container: Container) async throws {
		try await mutationGate.withMutation(kind: .feed) {
			try await self.removeFeedImpl(feed: feed, container: container)
		}
	}

	private func removeFeedImpl(feed: Feed, container: Container) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
		}

		// Optimistic local removal — sidebar updates immediately.
		container.removeFeedFromTreeAtTopLevel(feed)

		do {
			try await account.logActivity(kind: .removeFeed, detail: feed.url) {
				try await removeFeedFromCloud(for: account, with: feed, from: container)
			}
		} catch CloudKitZoneError.corruptAccount {
			// Account is corrupt. Leave the feed removed locally to clear the bad state.
		} catch {
			guard Self.feedRemovalNeedsRestore(after: error) else {
				throw error
			}
			container.addFeedToTreeAtTopLevel(feed)
			throw error
		}
	}

	func moveFeed(feed: Feed, sourceContainer: Container, destinationContainer: Container) async throws {
		try await mutationGate.withMutation(kind: .feed) {
			try await self.moveFeedImpl(feed: feed, sourceContainer: sourceContainer, destinationContainer: destinationContainer)
		}
	}

	private func moveFeedImpl(feed: Feed, sourceContainer: Container, destinationContainer: Container) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		syncProgress.addTask()
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
			syncProgress.completeTask()
		}

		do {
			try await account.logActivity(kind: .moveFeed, detail: feed.url) {
				try await accountZone.moveFeed(feed, from: sourceContainer, to: destinationContainer)
				sourceContainer.removeFeedFromTreeAtTopLevel(feed)
				destinationContainer.addFeedToTreeAtTopLevel(feed)
			}
		} catch {
			postSyncError(error, account: account, operation: "Moving feed")
			throw error
		}
	}

	func addFeed(feed: Feed, container: Container) async throws {
		try await mutationGate.withMutation(kind: .feed) {
			try await self.addFeedImpl(feed: feed, container: container)
		}
	}

	private func addFeedImpl(feed: Feed, container: Container) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		syncProgress.addTask()
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
			syncProgress.completeTask()
		}

		do {
			try await account.logActivity(kind: .addFeed, detail: feed.url) {
				try await accountZone.addFeed(feed, to: container)
				container.addFeedToTreeAtTopLevel(feed)
			}
		} catch {
			postSyncError(error, account: account, operation: "Adding feed")
			throw error
		}
	}

	func restoreFeed(feed: Feed, container: any Container) async throws {
		try await mutationGate.withMutation(kind: .feed) {
			try await self.restoreFeedImpl(feed: feed, container: container)
		}
	}

	private func restoreFeedImpl(feed: Feed, container: any Container) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
		}

		// The feed was already validated when first added. Skip Feed Finder and re-create the
		// CloudKit record directly, restoring the local tree position the user expects.
		syncProgress.addTask()

		container.addFeedToTreeAtTopLevel(feed)

		do {
			try await account.logActivity(kind: .restoreFeed, detail: feed.url) {
				let externalID = try await accountZone.createFeed(url: feed.url,
																  name: feed.name,
																  editedName: feed.editedName,
																  homePageURL: feed.homePageURL,
																  container: container)
				feed.externalID = externalID
			}
			syncProgress.completeTask()
		} catch {
			syncProgress.completeTask()
			container.removeFeedFromTreeAtTopLevel(feed)
			postSyncError(error, account: account, operation: "Restoring feed")
			throw error
		}
	}

	func createFolder(name: String) async throws -> Folder {
		try await mutationGate.withMutation(kind: .folder) {
			try await self.createFolderImpl(name: name)
		}
	}

	private func createFolderImpl(name: String) async throws -> Folder {
		guard let account else {
			throw AccountError.invalidParameter
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) name: \(name)")
		syncProgress.addTask()
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete name: \(name)")
			syncProgress.completeTask()
		}

		do {
			return try await account.logActivity(kind: .createFolder, detail: name) {
				let externalID = try await accountZone.createFolder(name: name)
				guard let folder = account.ensureFolder(with: name) else {
					throw AccountError.invalidParameter
				}
				folder.externalID = externalID
				return folder
			}
		} catch {
			postSyncError(error, account: account, operation: "Creating folder")
			throw error
		}
	}

	func renameFolder(with folder: Folder, to name: String) async throws {
		try await mutationGate.withMutation(kind: .folder) {
			try await self.renameFolderImpl(with: folder, to: name)
		}
	}

	private func renameFolderImpl(with folder: Folder, to name: String) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) new name: \(name)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete new name: \(name)")
		}
		syncProgress.addTask()
		defer { syncProgress.completeTask() }

		let oldName = folder.name ?? ""
		do {
			try await account.logActivity(kind: .renameFolder, detail: "\(oldName) → \(name)") {
				try await accountZone.renameFolder(folder, to: name)
				folder.name = name
			}
		} catch {
			postSyncError(error, account: account, operation: "Renaming folder")
			throw error
		}
	}

	func removeFolder(with folder: Folder) async throws {
		try await mutationGate.withMutation(kind: .folder) {
			try await self.removeFolderImpl(with: folder)
		}
	}

	private func removeFolderImpl(with folder: Folder) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) name: \(folder.name ?? "")")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete name: \(folder.name ?? "")")
		}

		let folderName = folder.name ?? ""
		let originalFeeds = folder.topLevelFeeds

		// Optimistic local removal — sidebar updates immediately.
		account.removeFolderFromTree(folder)

		try await account.logActivity(kind: .removeFolder, detail: folderName) {
			syncProgress.addTask()

			let feedExternalIDs: [String]
			do {
				feedExternalIDs = try await accountZone.findFeedExternalIDs(for: folder)
				syncProgress.completeTask()
			} catch {
				syncProgress.completeTask()
				syncProgress.completeTask()
				folder.replaceTopLevelFeeds(originalFeeds)
				account.addFolderToTree(folder)
				postSyncError(error, account: account, operation: "Removing folder")
				throw error
			}

			let feeds = feedExternalIDs.compactMap { account.existingFeed(withExternalID: $0) }
			var failedFeeds: Set<Feed> = []
			var cleanupFailed = false

			await withTaskGroup(of: (Feed, Error?).self) { group in
				for feed in feeds {
					group.addTask {
						do {
							try await account.logActivity(kind: .removeFeed, detail: feed.url) {
								try await self.removeFeedFromCloud(for: account, with: feed, from: folder)
							}
							return (feed, nil)
						} catch {
							Self.logger.error("CloudKit: Remove folder, remove feed error: \(error.localizedDescription)")
							return (feed, error)
						}
					}
				}

				for await (feed, error) in group {
					if let error {
						if Self.feedRemovalNeedsRestore(after: error) {
							failedFeeds.insert(feed)
						} else {
							cleanupFailed = true
						}
						postSyncError(error, account: account, operation: "Removing folder")
					}
				}
			}

			guard failedFeeds.isEmpty else {
				// Best-effort restore: bring the folder back with only the feeds that failed to delete
				// from CloudKit. Successfully-removed feeds stay gone locally to match cloud state.
				syncProgress.completeTask()
				folder.replaceTopLevelFeeds(failedFeeds)
				account.addFolderToTree(folder)
				throw CloudKitAccountDelegateError.unknown
			}

			do {
				try await accountZone.removeFolder(folder)
				syncProgress.completeTask()
			} catch {
				syncProgress.completeTask()
				// All feeds were removed from CloudKit but the folder record removal failed.
				// Restore an empty folder locally so it matches the cloud and the user can retry.
				folder.replaceTopLevelFeeds([])
				account.addFolderToTree(folder)
				throw error
			}
			if cleanupFailed {
				throw CloudKitAccountDelegateError.feedDeletedCleanupFailed
			}
		}
	}

	func restoreFolder(folder: Folder) async throws {
		try await mutationGate.withMutation(kind: .folder) {
			try await self.restoreFolderImpl(folder: folder)
		}
	}

	private func restoreFolderImpl(folder: Folder) async throws {
		guard let account else {
			throw AccountError.invalidParameter
		}
		guard let name = folder.name else {
			throw AccountError.invalidParameter
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) name: \(name)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete name: \(name)")
		}

		let feedsToRestore = folder.topLevelFeeds
		syncProgress.addTasks(1 + feedsToRestore.count)

		do {
			try await account.logActivity(kind: .restoreFolder, detail: name) {
				let externalID = try await accountZone.createFolder(name: name)
				syncProgress.completeTask()

				folder.externalID = externalID
				account.addFolderToTree(folder)

				await withTaskGroup(of: Error?.self) { group in
					for feed in feedsToRestore {
						folder.topLevelFeeds.remove(feed)

						group.addTask {
							do {
								try await self.restoreFeedImpl(feed: feed, container: folder)
								await self.syncProgress.completeTask()
								return nil
							} catch {
								Self.logger.error("CloudKit: Restore folder feed error: \(error.localizedDescription)")
								await self.syncProgress.completeTask()
								return error
							}
						}
					}

					for await error in group {
						if let error {
							postSyncError(error, account: account, operation: "Restoring folder")
						}
					}
				}

				account.addFolderToTree(folder)
			}
		} catch {
			syncProgress.completeTask()
			postSyncError(error, account: account, operation: "Restoring folder")
			throw error
		}
	}

	func markArticles(articleIDs: Set<String>, statusKey: ArticleStatus.Key, flag: Bool) async throws {
		try await Self.performMarkArticlesMutation(
			gate: mutationGate,
			localMutation: {
				await self.markArticlesImpl(articleIDs: articleIDs, statusKey: statusKey, flag: flag)
			},
			flush: {
				guard let account = self.account else { return }
				_ = try await self.sendArticleStatusImpl(account: account, showProgress: false)
			}
		)
	}

	static func performMarkArticlesMutation(
		gate: CloudKitAccountMutationGate,
		localMutation: () async throws -> Bool,
		flush: @escaping () async throws -> Void
	) async throws {
		let shouldFlush = try await gate.withMutation(kind: .articleStatus) {
			try await localMutation()
		}
		guard shouldFlush else { return }
		Task {
			try? await gate.withMutation(kind: .articleStatus) {
				try await flush()
			}
		}
	}

	private func markArticlesImpl(articleIDs: Set<String>, statusKey: ArticleStatus.Key, flag: Bool) async -> Bool {
		guard let account else {
			return false
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")

		let changedArticleIDs = await account.updateStatusesAsync(articleIDs: articleIDs, statusKey: statusKey, flag: flag)
		let syncStatuses = Set(changedArticleIDs.map { articleID in
			SyncStatus(articleID: articleID, key: SyncStatus.Key(statusKey), flag: flag)
		})

		await syncDatabase.insertStatuses(syncStatuses)
		if !syncStatuses.isEmpty {
			lastNoChangeSyncDate = nil
			NotificationCenter.default.post(name: .AccountDidQueueArticleStatuses, object: account)
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		return await syncDatabase.selectPendingCount().map { $0 > 100 } ?? false
	}

	func accountDidInitialize() {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")

		syncErrorHandler = { [weak self] error, operation, fileName, functionName, lineNumber in
			Task { @MainActor [weak self] in
				guard let self, let account = self.account else { return }
				self.postSyncError(error, account: account, operation: operation, fileName: fileName, functionName: functionName, lineNumber: lineNumber)
			}
		}

		accountZone.delegate = CloudKitAcountZoneDelegate(account: account, articlesZone: articlesZone)
		articlesZone.delegate = CloudKitArticlesZoneDelegate(account: account, database: syncDatabase, articlesZone: articlesZone, syncErrorHandler: syncErrorHandler)

		let accountID = account.accountID
		let accountDisplayName = account.nameForDisplay
		func makePageHandler(kind: ActivityKind) -> CloudKitZoneFetchPageHandler {
			let what: String
			switch kind {
			case .refreshArticleStatuses:
				what = "status and content changes"
			case .refreshFeedList:
				what = "feed list changes"
			default:
				what = "changes"
			}
			return { _, changed, deleted, _ in
				let detail = "Fetching \(what) \(ActivityLog.shared.nextTaskNumberString())"
				let message = cloudKitSyncMessage(changed: changed, deleted: deleted)
				ActivityLog.shared.logCompletedActivity(owner: .account(accountID: accountID, displayName: accountDisplayName), kind: kind, detail: detail, message: message)
			}
		}
		accountZone.fetchChangesPageHandler = makePageHandler(kind: .refreshFeedList)
		articlesZone.fetchChangesPageHandler = makePageHandler(kind: .refreshArticleStatuses)

		syncDatabase.resetAllSelectedForProcessing()

		// Check to see if this is a new account and initialize anything we need
		if Self.shouldStartAutomaticInitialSetup(externalID: account.externalID, userDefaults: AppConfig.defaults) {
			initialSetupTask = makeInitialSetupTask(for: account)
		}

	}

	func accountWillBeDeleted() {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		accountZone.resetChangeToken()
		articlesZone.resetChangeToken()
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func deleteZoneIfPresent(_ zoneID: CKRecordZone.ID) async throws {
		guard let configuredIdentifier = CloudKitAccountContainerConfiguration.container?.containerIdentifier,
			configuredIdentifier == container.containerIdentifier,
			CloudKitAccountContainerConfiguration.isResetContainerIdentifier(configuredIdentifier) else {
			throw CloudKitAccountDelegateError.containerUnavailable
		}
		try await accountZone.deleteZoneIfPresent(zoneID)
	}

	func waitForInitialSetup() async throws {
		guard let account else {
			throw CloudKitAccountDelegateError.accountNotReady
		}
		do {
			initialSetupTask = try await Self.awaitInitialSetup(existingTask: initialSetupTask) {
				self.makeInitialSetupTask(for: account)
			}
		} catch {
			initialSetupTask = nil
			throw error
		}
	}

	static func shouldStartAutomaticInitialSetup(externalID: String?, userDefaults: UserDefaults) -> Bool {
		externalID == nil && CloudKitAccountResetCoordinator.persistedPhase(in: userDefaults) == .idle
	}

	static func awaitInitialSetup(
		existingTask: Task<Void, Error>?,
		makeTask: () -> Task<Void, Error>
	) async throws -> Task<Void, Error> {
		if let existingTask {
			do {
				try await existingTask.value
				return existingTask
			} catch {
				// Replace a cached failed task so this invocation performs the retry.
			}
		}
		let task = makeTask()
		try await task.value
		return task
	}

	static func performInitialSetup(
		createAccountZone: () async throws -> Void,
		createArticlesZone: () async throws -> Void,
		createAccountRoot: () async throws -> Void,
		subscribeAccountZone: () async throws -> Void,
		subscribeArticlesZone: () async throws -> Void,
		initialRefresh: () async throws -> Void,
		verifyEmpty: () async throws -> Void
	) async throws {
		try await createAccountZone()
		try await createArticlesZone()
		try await createAccountRoot()
		try await subscribeAccountZone()
		try await subscribeArticlesZone()
		try await initialRefresh()
		try await verifyEmpty()
	}

	func verifyEmptyAccountTree() throws {
		guard let account,
			account.flattenedFeeds().isEmpty,
			account.folders?.isEmpty == true else {
			throw CloudKitAccountDelegateError.resetVerificationFailed
		}
	}

	static func validateCredentials(credentials: Credentials, endpoint: URL?) async throws -> Credentials? {
		nil
	}

	func vacuumDatabases() async {
		guard let account else {
			return
		}
		await account.logActivity(kind: .vacuumDatabase, detail: AppConfig.relativeDataPath(syncDatabase.databasePath)) {
			await syncDatabase.vacuum()
		}
	}

	func fetchCloudKitStats(progress: @escaping CloudKitStatsProgressHandler) async throws -> CloudKitStats {
		try await mutationGate.withMutation(kind: .articleStatus) {
			try await self.fetchCloudKitStatsImpl(progress: progress)
		}
	}

	private func fetchCloudKitStatsImpl(progress: @escaping CloudKitStatsProgressHandler) async throws -> CloudKitStats {
		guard let account else {
			throw CloudKitAccountDelegateError.unknown
		}
		do {
			return try await account.logActivity(kind: .fetchCloudKitStats) {
				try await articlesZone.fetchStats(account: account, progress: progress)
			}
		} catch {
			Self.logger.error("CloudKitAccountDelegate: fetchCloudKitStats error: \(error)")
			postSyncError(error, account: account, operation: "Fetching iCloud stats")
			throw error
		}
	}

	func cleanUpCloudKit(dryRun: Bool, progress: @escaping @MainActor @Sendable (CloudKitCleanUpProgress) -> Void) async throws {
		try await mutationGate.withMutation(kind: .articleStatus) {
			try await self.cleanUpCloudKitImpl(dryRun: dryRun, progress: progress)
		}
	}

	private func cleanUpCloudKitImpl(dryRun: Bool, progress: @escaping @MainActor @Sendable (CloudKitCleanUpProgress) -> Void) async throws {
		guard let account else {
			throw CloudKitAccountDelegateError.unknown
		}
		let syncUnreadContent = AccountManager.shared.syncArticleContentForUnreadArticles
		let detail = dryRun ? "Dry run" : "Manual"
		do {
			try await account.logActivity(kind: .cleanUpCloudKitRecords, detail: detail) {
				try await articlesZone.cleanUpRecordsUsingCache(account: account, syncUnreadContent: syncUnreadContent, dryRun: dryRun, deleteStaleRecords: false, progress: progress)
			}
		} catch {
			Self.logger.error("CloudKitAccountDelegate: cleanUpCloudKit error: \(error)")
			postSyncError(error, account: account, operation: "Cleaning up iCloud records")
			throw error
		}
	}

	// MARK: - Suspend and Resume

	func suspendNetwork() {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		refresher.suspend()
	}

	func resume() {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		refresher.resume()
	}
}

// MARK: - Refresh Progress

private extension CloudKitAccountDelegate {

	func updateProgress() {
		progressInfo = ProgressInfo.combined([refreshProgressInfo, syncProgressInfo])
	}

	@objc func refreshProgressDidChange(_ note: Notification) {
		refreshProgressInfo = refresher.progressInfo
	}

	@objc func syncProgressDidChange(_ note: Notification) {
		syncProgressInfo = syncProgress.progressInfo
	}
}

// MARK: - Activity Log helper

private extension CloudKitAccountDelegate {

	func makeInitialSetupTask(for account: Account) -> Task<Void, Error> {
		let resetOwnsGate = mutationGate.activeKind == .reset
		return Task {
			do {
				if resetOwnsGate {
					try await performInitialSetup(for: account, verifyEmpty: true)
				} else {
					try await mutationGate.withMutation(kind: .refresh) {
						try await self.performInitialSetup(for: account, verifyEmpty: false)
					}
				}
			} catch {
				Self.logger.error("CloudKitAccountDelegate: initial setup error: \(error.localizedDescription)")
				postSyncError(error, account: account, operation: "Creating account")
				throw error
			}
		}
	}

	func performInitialSetup(for account: Account, verifyEmpty: Bool) async throws {
		try await Self.performInitialSetup(
			createAccountZone: { try await self.accountZone.createZoneRecord() },
			createArticlesZone: { try await self.articlesZone.createZoneRecord() },
			createAccountRoot: {
				account.externalID = try await self.accountZone.findOrCreateAccount()
			},
			subscribeAccountZone: {
				try await self.subscribeToZoneChangesWithActivity(account: account, zone: self.accountZone)
			},
			subscribeArticlesZone: {
				try await self.subscribeToZoneChangesWithActivity(account: account, zone: self.articlesZone)
			},
			initialRefresh: { try await self.initialRefreshAll(for: account) },
			verifyEmpty: {
				if verifyEmpty {
					try self.verifyEmptyAccountTree()
				}
			}
		)
	}

	/// Without a successful subscription, this device receives no silent remote-change pushes.
	func subscribeToZoneChangesWithActivity(account: Account, zone: any CloudKitZone) async throws {
		let zoneName = zone.zoneID.zoneName
		do {
			try await account.logActivity(kind: .subscribeToCloudKitZone, detail: zoneName) {
				try await zone.subscribeToZoneChanges()
			}
		} catch {
			Self.logger.error("CloudKitAccountDelegate: subscribeToZoneChanges \(zoneName, privacy: .public) error: \(error.localizedDescription)")
			postSyncError(error, account: account, operation: "Subscribing to zone changes")
			throw error
		}
	}
}

// MARK: - Private

private extension CloudKitAccountDelegate {

	func initialRefreshAll(for account: Account) async throws {
		try await performRefreshAll(for: account, sendArticleStatus: false)
	}

	func standardRefreshAll(for account: Account) async throws {
		try await performRefreshAll(for: account, sendArticleStatus: true)
	}

	func performRefreshAll(for account: Account, sendArticleStatus: Bool) async throws {
		lastNoChangeSyncDate = nil
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) sendArticleStatus: \(sendArticleStatus ? "true" : "false")")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		}

		syncProgress.addTasks(3)

		let activityLog = ActivityLog.shared
		let owner = account.activityOwner

		// Overall .refreshAll activity for this account, wrapping every stage
		// below. Individual activities (fetchChangesInZone, receive/send operations)
		// log their own entries, while this one provides the account-is-refreshing
		// status at the account level.
		let refreshActivityID = activityLog.createActivity(owner: owner, kind: .refreshAll)
		activityLog.didStart(id: refreshActivityID)
		var refreshFinishedSuccessfully = false
		var refreshCompletionMessage: String?
		defer {
			if refreshFinishedSuccessfully {
				activityLog.didComplete(id: refreshActivityID, message: refreshCompletionMessage)
			} else {
				let error = NSError(domain: "CloudKitAccountDelegate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Refresh interrupted"])
				activityLog.didFail(id: refreshActivityID, error: error)
			}
		}

		let fetchChangesDetail = "Fetching account zone changes \(activityLog.nextTaskNumberString())"

		do {
			try await activityLog.logActivity(owner: owner, kind: .refreshFeedList, detail: fetchChangesDetail) {
				try await accountZone.fetchChangesInZone()
			}
			syncProgress.completeTask()
		} catch {
			if case CloudKitZoneError.userDeletedZone = error {
				account.removeFeedsFromTreeAtTopLevel(account.topLevelFeeds)
				for folder in account.folders ?? Set<Folder>() {
					account.removeFolderFromTree(folder)
				}
			}
			postSyncError(error, account: account, operation: "Fetching zone changes")
			syncProgress.reset()
			throw error
		}

		let feeds = account.flattenedFeeds()

		do {
			try await refreshArticleStatusImpl()
			syncProgress.completeTask()
		} catch {
			postSyncError(error, account: account, operation: "Refreshing article status")
			syncProgress.reset()
			throw error
		}

		refresher.accountID = account.accountID
		refresher.publishesRefreshActivity = false
		await refresher.refreshFeeds(feeds)
		refreshCompletionMessage = refresher.refreshStatsMessage

		if sendArticleStatus {
			do {
				_ = try await self.sendArticleStatusImpl(account: account, showProgress: true)
			} catch {
				postSyncError(error, account: account, operation: "Sending article status")
				syncProgress.reset()
				throw error
			}
		}

		syncProgress.reset()
		account.lastRefreshCompletedDate = Date()
		refreshFinishedSuccessfully = true
	}

	func createRSSFeed(for account: Account, url: URL, editedName: String?, container: Container, validateFeed: Bool) async throws -> Feed {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) url: \(url)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete url: \(url)")
		}
		syncProgress.addTasks(5)

		do {
			let feedSpecifiers = try await FeedFinder.find(url: url)
			syncProgress.completeTask()

			guard let bestFeedSpecifier = FeedSpecifier.bestFeed(in: feedSpecifiers),
				  let feedURL = URL(string: bestFeedSpecifier.urlString) else {
				syncProgress.completeTasks(3)
				if validateFeed {
					syncProgress.completeTask()
					throw AccountError.createErrorNotFound
				} else {
					return try await addDeadFeed(account: account, url: url, editedName: editedName, container: container)
				}
			}

			if account.hasFeed(withURL: bestFeedSpecifier.urlString) {
				syncProgress.completeTasks(4)
				throw AccountError.createErrorAlreadySubscribed
			}

			return try await createAndSyncFeed(account: account,
											   feedURL: feedURL,
											   bestFeedSpecifier: bestFeedSpecifier,
											   editedName: editedName,
											   container: container)
		} catch {
			syncProgress.completeTasks(3)
			if validateFeed {
				syncProgress.completeTask()
				throw AccountError.createErrorNotFound
			} else {
				return try await addDeadFeed(account: account, url: url, editedName: editedName, container: container)
			}
		}
	}

	func createAndSyncFeed(account: Account, feedURL: URL, bestFeedSpecifier: FeedSpecifier, editedName: String?, container: Container) async throws -> Feed {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feedURL: \(feedURL)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feedURL: \(feedURL)")
		}
		let feed = account.createFeed(with: nil, url: feedURL.absoluteString, feedID: feedURL.absoluteString, homePageURL: nil)
		feed.editedName = editedName
		container.addFeedToTreeAtTopLevel(feed)

		do {
			let parsedFeed = try await downloadAndParseFeed(feedURL: feedURL, feed: feed)
			try await updateAndCreateFeedInCloud(account: account,
												 feed: feed,
												 parsedFeed: parsedFeed,
												 bestFeedSpecifier: bestFeedSpecifier,
												 editedName: editedName,
												 container: container)
			return feed
		} catch {
			container.removeFeedFromTreeAtTopLevel(feed)
			syncProgress.completeTasks(3)
			throw error
		}
	}

	func downloadAndParseFeed(feedURL: URL, feed: Feed) async throws -> ParsedFeed {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feedURL: \(feedURL)")
		let (parsedFeed, response) = try await InitialFeedDownloader.download(feedURL)
		syncProgress.completeTask()
		feed.lastCheckDate = Date()

		guard let parsedFeed else {
			throw AccountError.createErrorNotFound
		}

		// Save conditional GET info so that first refresh uses conditional GET.
		if let httpResponse = response as? HTTPURLResponse,
		   let conditionalGetInfo = HTTPConditionalGetInfo(urlResponse: httpResponse) {
			feed.conditionalGetInfo = conditionalGetInfo
		}

		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		return parsedFeed
	}

	func updateAndCreateFeedInCloud(account: Account, feed: Feed, parsedFeed: ParsedFeed, bestFeedSpecifier: FeedSpecifier, editedName: String?, container: Container) async throws {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		await account.updateAsync(feed: feed, parsedFeed: parsedFeed)

		let externalID = try await accountZone.createFeed(url: bestFeedSpecifier.urlString,
														  name: parsedFeed.title,
														  editedName: editedName,
														  homePageURL: parsedFeed.homePageURL,
														  container: container)
		syncProgress.completeTask()
		feed.externalID = externalID
		sendNewArticlesToTheCloud(account, feed)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func addDeadFeed(account: Account, url: URL, editedName: String?, container: Container) async throws -> Feed {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		let feed = account.createFeed(with: editedName, url: url.absoluteString, feedID: url.absoluteString, homePageURL: nil)
		container.addFeedToTreeAtTopLevel(feed)

		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
			syncProgress.completeTask()
		}

		do {
			let externalID = try await accountZone.createFeed(url: url.absoluteString,
															  name: editedName,
															  editedName: nil,
															  homePageURL: nil,
															  container: container)
			feed.externalID = externalID
			return feed
		} catch {
			container.removeFeedFromTreeAtTopLevel(feed)
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) error: \(error.localizedDescription)")
			throw error
		}
	}

	func sendNewArticlesToTheCloud(_ account: Account, _ feed: Feed) {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		Task {
			do {
				try await mutationGate.withMutation(kind: .articleStatus) {
					await self.sendNewArticlesToTheCloudImpl(account, feed)
				}
			} catch {
				Self.logger.error("CloudKitAccountDelegate: \(#function, privacy: .public) skipped: \(error.localizedDescription)")
			}
		}
	}

	private func sendNewArticlesToTheCloudImpl(_ account: Account, _ feed: Feed) async {
		do {
			let articles = await account.fetchArticlesAsync(.feed(feed))

			await storeArticleChanges(new: articles, updated: Set<Article>(), deleted: Set<Article>())
			syncProgress.completeTask()

			_ = try await sendArticleStatusImpl(account: account, showProgress: true)

			do {
				_ = try await articlesZone.fetchChangesInZone()
			} catch {
				Self.logger.error("CloudKitAccountDelegate: fetchChangesInZone error: \(error.localizedDescription)")
				if let account = self.account {
					postSyncError(error, account: account, operation: "Fetching zone changes")
				}
			}
		} catch {
			Self.logger.error("CloudKitAccountDelegate: \(#function, privacy: .public) error: \(error.localizedDescription)")
			if let account = self.account {
				postSyncError(error, account: account, operation: "Sending articles")
			}
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func postSyncError(_ error: Error, account: Account, operation: String, fileName: String = #fileID, functionName: String = #function, lineNumber: Int = #line) {
		let userVisibleError = CloudKitAccountDelegateError.userVisibleError(for: error)
		let errorLogUserInfo = ErrorLogUserInfoKey.userInfo(sourceName: account.nameForDisplay, sourceID: account.type.rawValue, operation: operation, errorMessage: AccountError.detailedErrorMessage(userVisibleError), fileName: fileName, functionName: functionName, lineNumber: lineNumber)
		NotificationCenter.default.post(name: .appDidEncounterError, object: self, userInfo: errorLogUserInfo)
	}

	func storeArticleChanges(new: Set<Article>?, updated: Set<Article>?, deleted: Set<Article>?) async {
		// New records with a read status aren't really new, they just didn't have the read article stored
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		await withTaskGroup(of: Void.self) { group in
			if let new = new {
				let filteredNew = new.filter { $0.status.read == false }
				group.addTask {
					await self.insertSyncStatuses(articles: filteredNew, statusKey: .new, flag: true)
				}
			}

			group.addTask {
				await self.insertSyncStatuses(articles: updated, statusKey: .new, flag: false)
			}

			group.addTask {
				await self.insertSyncStatuses(articles: deleted, statusKey: .deleted, flag: true)
			}
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func insertSyncStatuses(articles: Set<Article>?, statusKey: SyncStatus.Key, flag: Bool) async {
		guard let articles = articles, !articles.isEmpty else {
			return
		}
		let syncStatuses = Set(articles.map { article in
			SyncStatus(articleID: article.articleID, key: statusKey, flag: flag)
		})
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		await syncDatabase.insertStatuses(syncStatuses)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	/// Returns the number of statuses successfully sent.
	func sendArticleStatusImpl(account: Account, showProgress: Bool) async throws -> Int {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
			let op = CloudKitSendStatusOperation(account: account,
												 articlesZone: articlesZone,
												 database: syncDatabase,
												 syncArticleContentForUnreadArticles: syncArticleContentForUnreadArticles,
												 syncErrorHandler: syncErrorHandler)
			op.completionBlock = { mainThreadOperation in
				Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
				if mainThreadOperation.isCanceled {
					continuation.resume(throwing: CloudKitAccountDelegateError.unknown)
				} else {
					continuation.resume(returning: op.sentCount)
				}
			}
			mainThreadOperationQueue.add(op)
		}
	}

	func removeFeedFromCloud(for account: Account, with feed: Feed, from container: Container) async throws {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		}

		syncProgress.addTasks(2)

		let deletedFinalRecord: Bool
		do {
			deletedFinalRecord = try await accountZone.removeFeed(feed, from: container)
			syncProgress.completeTask()
		} catch {
			syncProgress.completeTask()
			syncProgress.completeTask()
			postSyncError(error, account: account, operation: "Removing feed")
			throw error
		}

		guard deletedFinalRecord else {
			syncProgress.completeTask()
			return
		}

		do {
			try await Self.completeFeedDeletion(
				deletedFinalRecord: deletedFinalRecord,
				feedExternalID: feed.externalID,
				deleteArticles: { feedExternalID in
					try await self.articlesZone.deleteArticles(feedExternalID, owner: account.activityOwner)
					feed.dropConditionalGetInfo()
				},
				clearSettings: { await account.clearFeedSettings(feed) },
				reportCleanupError: { self.postSyncError($0, account: account, operation: "Removing feed articles") }
			)
			syncProgress.completeTask()
		} catch {
			syncProgress.completeTask()
			throw error
		}
	}

}

extension CloudKitAccountDelegate {
	static func feedRemovalNeedsRestore(after error: Error) -> Bool {
		(error as? CloudKitAccountDelegateError) != .feedDeletedCleanupFailed
	}

	static func completeFeedDeletion(
		deletedFinalRecord: Bool,
		feedExternalID: String?,
		deleteArticles: (String) async throws -> Void,
		clearSettings: () async -> Void,
		reportCleanupError: (Error) -> Void = { _ in }
	) async throws {
		guard deletedFinalRecord else {
			return
		}
		guard let feedExternalID else {
			throw CloudKitZoneError.corruptAccount
		}
		do {
			try await deleteArticles(feedExternalID)
		} catch {
			reportCleanupError(error)
			throw CloudKitAccountDelegateError.feedDeletedCleanupFailed
		}
		await clearSettings()
	}
}

private extension CloudKitAccountDelegate {

	// MARK: - Record Cleanup

	private static let lastCleanUpKey = "cloudkit.lastCleanUpDate"

	func cleanUpContentRecordsIfNeeded() async {
		if AppConfig.defaults.object(forKey: Self.lastCleanUpKey) == nil {
			AppConfig.defaults.set(Date(), forKey: Self.lastCleanUpKey)
			return
		}
		let lastCleanUp = AppConfig.defaults.object(forKey: Self.lastCleanUpKey) as? Date ?? .distantPast
		let sixDaysAgo = Date(timeIntervalSinceNow: -6 * 24 * 60 * 60)
		guard lastCleanUp < sixDaysAgo else {
			return
		}

		guard let account else {
			return
		}

		// Set this unconditionally. If it fails, we don’t want to keep trying, possibly
		// doing a bunch of extra work that will fail. Let it rest until the next go.
		AppConfig.defaults.set(Date(), forKey: Self.lastCleanUpKey)

		Self.logger.info("CloudKitAccountDelegate: running weekly record cleanup")
		do {
			let syncUnreadContent = AccountManager.shared.syncArticleContentForUnreadArticles
			let successMessage: (Int) -> String? = { count in
				count == 0 ? "no records deleted" : "deleted \(count) record\(count == 1 ? "" : "s")"
			}
			let deleted = try await account.logActivity(kind: .cleanUpCloudKitRecords, detail: "Weekly", successMessage: successMessage) { () -> Int in
				try await articlesZone.cleanUpRecords(account: account, syncUnreadContent: syncUnreadContent, dryRun: false, deleteStaleRecords: false)
			}
			Self.logger.info("CloudKitAccountDelegate: weekly cleanup deleted \(deleted, privacy: .public) records")
		} catch {
			Self.logger.error("CloudKitAccountDelegate: weekly cleanup error: \(error.localizedDescription, privacy: .public)")
			postSyncError(error, account: account, operation: "Weekly record cleanup")
		}
	}
}

extension CloudKitAccountDelegate: LocalAccountRefresherDelegate {

	func localAccountRefresher(_ refresher: LocalAccountRefresher, articleChanges: ArticleChanges) {
		Task {
			await storeArticleChanges(new: articleChanges.new,
									  updated: articleChanges.updated,
									  deleted: articleChanges.deleted)
		}
	}
}
