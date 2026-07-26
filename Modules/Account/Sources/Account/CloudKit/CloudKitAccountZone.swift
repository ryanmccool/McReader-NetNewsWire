//
//  CloudKitAccountZone.swift
//  Account
//
//  Created by Maurice Parker on 3/21/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import os
import RSCore
import RSWeb
import RSParser
import CloudKit
import CloudKitSync

enum CloudKitAbsenceResult {
	static func isSatisfied(error: Error, targetRecordIDs: Set<CKRecord.ID>) -> Bool {
		let underlyingError = (error as? CloudKitError)?.error ?? error
		guard let cloudKitError = underlyingError as? CKError else {
			return false
		}
		if cloudKitError.code == .unknownItem {
			return true
		}
		guard cloudKitError.code == .partialFailure,
			let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: CKError],
			!partialErrors.isEmpty else {
			return false
		}
		return partialErrors.allSatisfy { itemID, error in
			guard let recordID = itemID as? CKRecord.ID else {
				return false
			}
			return targetRecordIDs.contains(recordID) && error.code == .unknownItem
		}
	}
}

enum CloudKitAccountZoneError: LocalizedError {
	case unknown
	case duplicateFolderName(String)
	var errorDescription: String? {
		switch self {
		case .duplicateFolderName(let name):
			return String(format: NSLocalizedString("The iCloud account contains more than one folder named \"%@\". Rename one folder and try again.", comment: "Duplicate iCloud folder name."), name)
		case .unknown:
			return NSLocalizedString("An unexpected CloudKit error occurred.", comment: "An unexpected CloudKit error occurred.")
		}
	}
}

@MainActor final class CloudKitAccountZone: CloudKitZone {
	var zoneID: CKRecordZone.ID
	let userDefaults: UserDefaults

    weak var container: CKContainer?
	let database: CKDatabase?
	var delegate: CloudKitZoneDelegate?
	var fetchChangesPageHandler: CloudKitZoneFetchPageHandler?

	struct CloudKitFeed {
		static let recordType = "AccountWebFeed"
		struct Fields {
			static let url = "url"
			static let name = "name"
			static let editedName = "editedName"
			static let homePageURL = "homePageURL"
			static let containerExternalIDs = "containerExternalIDs"
		}
	}

	struct CloudKitContainer {
		static let recordType = "AccountContainer"
		struct Fields {
			static let isAccount = "isAccount"
			static let name = "name"
		}
	}

	init(container: CKContainer?, userDefaults: UserDefaults) {
		self.container = container
		self.database = container?.privateCloudDatabase
		self.zoneID = CKRecordZone.ID(zoneName: "Account", ownerName: CKCurrentUserDefaultName)
		self.userDefaults = userDefaults
	}

	func importOPML(rootExternalID: String, plan: CloudKitOPMLImportPlan) async throws -> OPMLImportResult {
		var folders = try await inventoryFolders()
		for name in Set(plan.feeds.flatMap(\.folderNames)).sorted() where folders[name] == nil {
			let record = newContainerCKRecord(name: name)
			try await save(record)
			folders[name] = record
		}

		var importResult = OPMLImportResult()
		for plannedFeed in plan.feeds {
			var placements = Set(plannedFeed.folderNames.compactMap { folders[$0]?.externalID })
			guard placements.count == plannedFeed.folderNames.count else {
				throw CloudKitAccountZoneError.unknown
			}
			if plannedFeed.isTopLevel {
				placements.insert(rootExternalID)
			}

			let result = try await upsertFeed(
				urlString: plannedFeed.urlString,
				name: nil,
				editedName: plannedFeed.editedName,
				homePageURL: plannedFeed.homePageURL,
				containerExternalIDs: placements
			)
			if result.wasAdded {
				importResult.added += 1
			} else if result.isUnchanged {
				importResult.unchanged += 1
			} else {
				if result.metadataChanged {
					importResult.updated += 1
				}
				if result.placementChanged {
					importResult.repositioned += 1
				}
			}
		}
		return importResult
	}

	///  Persist a feed record to iCloud and return the external key
	func createFeed(url: String, name: String?, editedName: String?, homePageURL: String?, container: Container) async throws -> String {
		guard let containerExternalID = container.externalID else {
			throw CloudKitZoneError.corruptAccount
		}
		_ = try await upsertFeed(
			urlString: url,
			name: name,
			editedName: editedName,
			homePageURL: homePageURL,
			containerExternalIDs: [containerExternalID]
		)
		return url.md5String
	}

	func inventoryFolders() async throws -> [String: CKRecord] {
		let query = CKQuery(recordType: CloudKitContainer.recordType, predicate: NSPredicate(value: true))
		return try Self.folderInventory(records: await self.query(query), rootExternalID: "")
	}

	func upsertFeed(
		urlString: String,
		name: String?,
		editedName: String?,
		homePageURL: String?,
		containerExternalIDs: Set<String>
	) async throws -> CloudKitFeedUpsertResult {
		try await Self.upsertFeed(
			urlString: urlString,
			name: name,
			editedName: editedName,
			homePageURL: homePageURL,
			containerExternalIDs: containerExternalIDs,
			zoneID: zoneID,
			fetch: { try await self.fetch(externalID: $0) },
			save: { try await self.saveUnchanged($0) }
		)
	}

	/// Rename the given feed
	func renameFeed(_ feed: Feed, editedName: String?) async throws {
		guard let externalID = feed.externalID else {
			throw CloudKitZoneError.corruptAccount
		}

		let recordID = CKRecord.ID(recordName: externalID, zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitFeed.recordType, recordID: recordID)
		record[CloudKitFeed.Fields.editedName] = editedName

		try await save(record)
	}

	/// Removes a feed from a container and optionally deletes it, returning true if deleted
	func removeFeed(_ feed: Feed, from: Container) async throws -> Bool {
		guard let fromContainerExternalID = from.externalID, let feedExternalID = feed.externalID else {
			throw CloudKitZoneError.corruptAccount
		}
		let targetRecordID = CKRecord.ID(recordName: feedExternalID, zoneID: zoneID)

		do {
			let record = try await fetch(externalID: feedExternalID)

			if let containerExternalIDs = record[CloudKitFeed.Fields.containerExternalIDs] as? [String] {
				var containerExternalIDSet = Set(containerExternalIDs)
				containerExternalIDSet.remove(fromContainerExternalID)

				if containerExternalIDSet.isEmpty {
					try await delete(externalID: feedExternalID)
					return true
				} else {
					record[CloudKitFeed.Fields.containerExternalIDs] = Array(containerExternalIDSet)
					try await save(record)
					return false
				}
			}
			return false
		} catch {
			if CloudKitAbsenceResult.isSatisfied(error: error, targetRecordIDs: [targetRecordID]) {
				return true
			}
			throw error
		}
	}

	func moveFeed(_ feed: Feed, from: Container, to: Container) async throws {
		guard let fromContainerExternalID = from.externalID, let toContainerExternalID = to.externalID else {
			throw CloudKitZoneError.corruptAccount
		}

		let record = try await fetch(externalID: feed.externalID)
		if let containerExternalIDs = record[CloudKitFeed.Fields.containerExternalIDs] as? [String] {
			var containerExternalIDSet = Set(containerExternalIDs)
			containerExternalIDSet.remove(fromContainerExternalID)
			containerExternalIDSet.insert(toContainerExternalID)
			record[CloudKitFeed.Fields.containerExternalIDs] = Array(containerExternalIDSet)
			try await save(record)
		}
	}

	func addFeed(_ feed: Feed, to: Container) async throws {
		guard let toContainerExternalID = to.externalID else {
			throw CloudKitZoneError.corruptAccount
		}

		let record = try await fetch(externalID: feed.externalID)
		if let containerExternalIDs = record[CloudKitFeed.Fields.containerExternalIDs] as? [String] {
			var containerExternalIDSet = Set(containerExternalIDs)
			containerExternalIDSet.insert(toContainerExternalID)
			record[CloudKitFeed.Fields.containerExternalIDs] = Array(containerExternalIDSet)
			try await save(record)
		}
	}

	func findFeedExternalIDs(for folder: Folder) async throws -> [String] {
		guard let folderExternalID = folder.externalID else {
			throw CloudKitAccountZoneError.unknown
		}

		let predicate = NSPredicate(format: "containerExternalIDs CONTAINS %@", folderExternalID)
		let ckQuery = CKQuery(recordType: CloudKitFeed.recordType, predicate: predicate)

		let records = try await query(ckQuery)
		return records.map { $0.externalID }
	}

	private func findOrCreateAccount(completion: @escaping @Sendable (Result<String, Error>) -> Void) {
		let predicate = NSPredicate(format: "isAccount = \"1\"")
		let ckQuery = CKQuery(recordType: CloudKitContainer.recordType, predicate: predicate)
		guard let database else {
			completion(.failure(CloudKitZoneError.databaseUnavailable))
			return
		}

		database.fetch(withQuery: ckQuery, inZoneWith: zoneID, desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults) { [weak self] result in
			Task { @MainActor [weak self] in
				guard let self else {
					completion(.failure(CloudKitZoneError.unknown))
					return
				}

				switch result {
				case .success(let (matchResults, _)):
					var records = [CKRecord]()
					for (_, result) in matchResults {
						do {
							records.append(try result.get())
						} catch {
							completion(.failure(error))
							return
						}
					}
					if !records.isEmpty {
						completion(.success(records[0].externalID))
					} else {
						do {
							let externalID = try await self.createContainer(name: "Account", isAccount: true)
							completion(.success(externalID))
						} catch let createError {
							completion(.failure(createError))
						}
					}
				case .failure(let error):
					switch CloudKitZoneResult.resolve(error) {
					case .success:
						do {
							let externalID = try await self.createContainer(name: "Account", isAccount: true)
							completion(.success(externalID))
						} catch let createError {
							completion(.failure(createError))
						}
					case .retry(let timeToWait):
						await self.delaySeconds(timeToWait)
						self.findOrCreateAccount(completion: completion)
					case .zoneNotFound, .userDeletedZone:
						self.createZoneRecord { result in
							switch result {
							case .success:
								self.findOrCreateAccount(completion: completion)
							case .failure(let error):
								completion(.failure(CloudKitError(error)))
							}
						}
					default:
						do {
							let externalID = try await self.createContainer(name: "Account", isAccount: true)
							completion(.success(externalID))
						} catch let createError {
							completion(.failure(createError))
						}
					}
				}
			}
		}
	}

	func createFolder(name: String) async throws -> String {
		try await createContainer(name: name, isAccount: false)
	}

	func renameFolder(_ folder: Folder, to name: String) async throws {
		guard let externalID = folder.externalID else {
			throw CloudKitZoneError.corruptAccount
		}

		let recordID = CKRecord.ID(recordName: externalID, zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitContainer.recordType, recordID: recordID)
		record[CloudKitContainer.Fields.name] = name

		try await save(record)
	}

	func removeFolder(_ folder: Folder) async throws {
		try await delete(externalID: folder.externalID)
	}

	// MARK: - Async Wrappers

	func findOrCreateAccount() async throws -> String {
		try await withCheckedThrowingContinuation { continuation in
			findOrCreateAccount { result in
				continuation.resume(with: result)
			}
		}
	}
}

private extension CloudKitAccountZone {
	func newContainerCKRecord(name: String) -> CKRecord {
		let record = CKRecord(recordType: CloudKitContainer.recordType, recordID: generateRecordID())
		record[CloudKitContainer.Fields.name] = name
		record[CloudKitContainer.Fields.isAccount] = "0"
		return record
	}

	func createContainer(name: String, isAccount: Bool) async throws -> String {
		let record = CKRecord(recordType: CloudKitContainer.recordType, recordID: generateRecordID())
		record[CloudKitContainer.Fields.name] = name
		record[CloudKitContainer.Fields.isAccount] = isAccount ? "1" : "0"

		try await save(record)
		return record.externalID
	}
}

extension CloudKitAccountZone {
	static func folderInventory(records: [CKRecord], rootExternalID: String) throws -> [String: CKRecord] {
		var folders = [String: CKRecord]()
		for record in records where record.externalID != rootExternalID {
			if record[CloudKitContainer.Fields.isAccount] as? String == "1" {
				continue
			}
			guard let name = record[CloudKitContainer.Fields.name] as? String else {
				throw CloudKitAccountZoneError.unknown
			}
			guard folders[name] == nil else {
				throw CloudKitAccountZoneError.duplicateFolderName(name)
			}
			folders[name] = record
		}
		return folders
	}

	static func upsertFeed(
		urlString: String,
		name: String?,
		editedName: String?,
		homePageURL: String?,
		containerExternalIDs: Set<String>,
		zoneID: CKRecordZone.ID,
		fetch: (String) async throws -> CKRecord,
		save: (CKRecord) async throws -> Void
	) async throws -> CloudKitFeedUpsertResult {
		let externalID = urlString.md5String

		func apply(to record: CKRecord, wasAdded: Bool) -> CloudKitFeedUpsertResult {
			let oldURL = record[CloudKitFeed.Fields.url] as? String
			let oldName = record[CloudKitFeed.Fields.name] as? String
			let oldEditedName = record[CloudKitFeed.Fields.editedName] as? String
			let oldHomePageURL = record[CloudKitFeed.Fields.homePageURL] as? String
			let oldPlacements = Set(record[CloudKitFeed.Fields.containerExternalIDs] as? [String] ?? [])

			record[CloudKitFeed.Fields.url] = urlString
			if let name {
				record[CloudKitFeed.Fields.name] = name
			}
			record[CloudKitFeed.Fields.editedName] = editedName
			if let homePageURL {
				record[CloudKitFeed.Fields.homePageURL] = homePageURL
			}
			record[CloudKitFeed.Fields.containerExternalIDs] = containerExternalIDs.sorted()

			guard !wasAdded else {
				return CloudKitFeedUpsertResult(wasAdded: true, metadataChanged: false, placementChanged: false)
			}
			let metadataChanged = oldURL != urlString
				|| (name != nil && oldName != name)
				|| oldEditedName != editedName
				|| (homePageURL != nil && oldHomePageURL != homePageURL)
			return CloudKitFeedUpsertResult(
				wasAdded: false,
				metadataChanged: metadataChanged,
				placementChanged: oldPlacements != containerExternalIDs
			)
		}

		func fetchedRecord() async throws -> CKRecord? {
			do {
				return try await fetch(externalID)
			} catch {
				guard cloudKitErrorCode(error) == .unknownItem else {
					throw error
				}
				return nil
			}
		}

		let existingRecord = try await fetchedRecord()
		let record = existingRecord ?? CKRecord(
			recordType: CloudKitFeed.recordType,
			recordID: CKRecord.ID(recordName: externalID, zoneID: zoneID)
		)
		let result = apply(to: record, wasAdded: existingRecord == nil)
		guard !result.isUnchanged else {
			return result
		}

		do {
			try await save(record)
			return result
		} catch {
			guard cloudKitErrorCode(error) == .serverRecordChanged else {
				throw error
			}
			let refetched = try await fetch(externalID)
			let retryResult = apply(to: refetched, wasAdded: false)
			if !retryResult.isUnchanged {
				try await save(refetched)
			}
			return retryResult
		}
	}

	private static func cloudKitErrorCode(_ error: Error) -> CKError.Code? {
		let ckError: CKError?
		if let cloudKitError = error as? CloudKitError {
			ckError = cloudKitError.error as? CKError
		} else {
			ckError = error as? CKError
		}
		guard let ckError else {
			return nil
		}
		if ckError.code == .partialFailure,
			let errors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: CKError],
			errors.count == 1 {
			return errors.values.first?.code
		}
		return ckError.code
	}
}
