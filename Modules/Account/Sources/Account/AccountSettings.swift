//
//  AccountSettings.swift
//  Account
//
//  Created by Brent Simmons on 3/3/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import RSWeb

/// AccountSettings is backed by UserDefaults.
@MainActor final class AccountSettings {

	private enum Key: String {
		case name
		case isActive
		case username
		case conditionalGetInfo
		case lastArticleFetchStartTime
		case lastRefreshCompletedDate
		case endpointURL
		case externalID
		case imported
	}

	private static let lastModifiedKey = "lastModified"
	private static let etagKey = "etag"

	private let accountID: String
	private let dataFolder: String

	private var plistImported: Bool {
		get {
			AppConfig.defaults.bool(forKey: defaultsKey(.imported))
		}
		set {
			AppConfig.defaults.set(newValue, forKey: defaultsKey(.imported))
		}
	}

	var name: String? {
		get {
			AppConfig.defaults.string(forKey: defaultsKey(.name))
		}
		set {
			AppConfig.defaults.set(newValue, forKey: defaultsKey(.name))
		}
	}

	var isActive: Bool {
		get {
			AppConfig.defaults.bool(forKey: defaultsKey(.isActive))
		}
		set {
			AppConfig.defaults.set(newValue, forKey: defaultsKey(.isActive))
		}
	}

	var username: String? {
		get {
			guard let username = AppConfig.defaults.string(forKey: defaultsKey(.username))?.trimmingWhitespace, !username.isEmpty else {
				return nil
			}
			return username
		}
		set {
			guard let trimmed = newValue?.trimmingWhitespace, !trimmed.isEmpty else {
				return
			}
			AppConfig.defaults.set(trimmed, forKey: defaultsKey(.username))
		}
	}

	func conditionalGetInfo(for endpoint: String) -> HTTPConditionalGetInfo? {
		let key = conditionalGetInfoDefaultsKey(endpoint)
		guard let d = AppConfig.defaults.dictionary(forKey: key) as? [String: String] else {
			return nil
		}
		return HTTPConditionalGetInfo(lastModified: d[Self.lastModifiedKey], etag: d[Self.etagKey])
	}

	func setConditionalGetInfo(_ info: HTTPConditionalGetInfo?, for endpoint: String) {
		let key = conditionalGetInfoDefaultsKey(endpoint)
		if let info {
			var d = [String: String]()
			if let lastModified = info.lastModified {
				d[Self.lastModifiedKey] = lastModified
			}
			if let etag = info.etag {
				d[Self.etagKey] = etag
			}
			AppConfig.defaults.set(d, forKey: key)
		} else {
			AppConfig.defaults.removeObject(forKey: key)
		}
	}

	var lastArticleFetchStartTime: Date? {
		get {
			AppConfig.defaults.object(forKey: defaultsKey(.lastArticleFetchStartTime)) as? Date
		}
		set {
			AppConfig.defaults.set(newValue, forKey: defaultsKey(.lastArticleFetchStartTime))
		}
	}

	var lastRefreshCompletedDate: Date? {
		get {
			AppConfig.defaults.object(forKey: defaultsKey(.lastRefreshCompletedDate)) as? Date
		}
		set {
			AppConfig.defaults.set(newValue, forKey: defaultsKey(.lastRefreshCompletedDate))
		}
	}

	var endpointURL: URL? {
		get {
			guard let urlString = AppConfig.defaults.string(forKey: defaultsKey(.endpointURL))?.trimmingWhitespace, !urlString.isEmpty else {
				return nil
			}
			return URL(string: urlString)
		}
		set {
			guard let trimmed = newValue?.absoluteString.trimmingWhitespace, !trimmed.isEmpty else {
				return
			}
			AppConfig.defaults.set(trimmed, forKey: defaultsKey(.endpointURL))
		}
	}

	var externalID: String? {
		get {
			AppConfig.defaults.string(forKey: defaultsKey(.externalID))
		}
		set {
			AppConfig.defaults.set(newValue, forKey: defaultsKey(.externalID))
		}
	}

	init(accountID: String, dataFolder: String) {
		self.accountID = accountID
		self.dataFolder = dataFolder

		AppConfig.defaults.register(defaults: [defaultsKey(.isActive): true])

		if !self.plistImported {
			if let importedSettings = AccountSettingsImporter.readSettingsFromPlist(accountID: accountID, dataFolder: dataFolder) {
				storeImportedSettings(importedSettings)
			}
			self.plistImported = true
		}

		if self.username == nil || self.endpointURL == nil {
			readMissingSettingsFromPlist(accountID: accountID, dataFolder: dataFolder)
		}
		if self.username == nil || self.endpointURL == nil {
			readMissingSettingsFromDatabase()
		}
	}

	// Call when an expected value is nil — perhaps it couldn’t be read on startup
	// from the settings file. Try again.
	func fetchFromSettingsFileIfNeeded() {
		readMissingSettingsFromPlist(accountID: accountID, dataFolder: dataFolder)
	}

	func deleteSettings() {
		let defaults = AppConfig.defaults
		let prefix = "\(accountID)-"
		for key in defaults.dictionaryRepresentation().keys {
			if key.hasPrefix(prefix) {
				defaults.removeObject(forKey: key)
			}
		}
	}
}

// MARK: - Private

private extension AccountSettings {

	private func defaultsKey(_ key: Key) -> String {
		"\(accountID)-\(key.rawValue)"
	}

	func conditionalGetInfoDefaultsKey(_ endpoint: String) -> String {
		"\(accountID)-\(Key.conditionalGetInfo.rawValue)-\(endpoint)"
	}

	/// Try to read username and endpointURL from Settings.plist
	/// if they weren't found in UserDefaults.
	func readMissingSettingsFromPlist(accountID: String, dataFolder: String) {
		guard let imported = AccountSettingsImporter.readSettingsFromPlist(accountID: accountID, dataFolder: dataFolder) else {
			return
		}
		if self.username == nil, let username = imported.username {
			self.username = username
		}
		if self.endpointURL == nil, let endpointURL = imported.endpointURL {
			self.endpointURL = endpointURL
		}
	}

	/// Fall back to AccountSettingsDatabase for username and endpointURL
	/// if they weren't found in UserDefaults or Settings.plist.
	func readMissingSettingsFromDatabase() {
		let databasePath = AppConfig.dataFolder.appendingPathComponent("AccountSettings.db").path
		guard let database = AccountSettingsDatabase(databasePath: databasePath) else {
			return
		}

		if self.username == nil, let username = database.username(for: accountID) {
			self.username = username
		}
		if self.endpointURL == nil, let urlString = database.endpointURL(for: accountID) {
			self.endpointURL = URL(string: urlString)
		}
	}

	func storeImportedSettings(_ imported: AccountSettingsImporter.ImportedSettings) {
		if self.name == nil {
			self.name = imported.name
		}
		if let isActive = imported.isActive {
			self.isActive = isActive
		}
		if self.username == nil {
			self.username = imported.username
		}
		if self.lastArticleFetchStartTime == nil {
			self.lastArticleFetchStartTime = imported.lastArticleFetchStartTime
		}
		if self.lastRefreshCompletedDate == nil {
			self.lastRefreshCompletedDate = imported.lastRefreshCompletedDate
		}
		if self.endpointURL == nil {
			self.endpointURL = imported.endpointURL
		}
		if self.externalID == nil {
			self.externalID = imported.externalID
		}
		if let conditionalGetInfo = imported.conditionalGetInfo {
			for (endpoint, info) in conditionalGetInfo {
				if self.conditionalGetInfo(for: endpoint) == nil {
					setConditionalGetInfo(info, for: endpoint)
				}
			}
		}
	}
}
