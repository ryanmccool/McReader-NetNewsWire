//
//  CloudKitRemoteNotificationOperation.swift
//  Account
//
//  Created by Maurice Parker on 5/2/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import os
import RSCore
import CloudKitSync
import ActivityLog

@MainActor final class CloudKitRemoteNotificationOperation: MainThreadOperation, @unchecked Sendable {
	private weak var accountZone: CloudKitAccountZone?
	private weak var articlesZone: CloudKitArticlesZone?
	private let accountID: String
	private let accountDisplayName: String
	nonisolated(unsafe) private var userInfo: [AnyHashable: Any]
	private static let logger = cloudKitLogger
	private(set) var notificationError: Error?
	private(set) var notificationResult = CloudKitRemoteNotificationResult.notHandled

	init(accountZone: CloudKitAccountZone, articlesZone: CloudKitArticlesZone, accountID: String, accountDisplayName: String, userInfo: [AnyHashable: Any]) {
		self.accountZone = accountZone
		self.articlesZone = articlesZone
		self.accountID = accountID
		self.accountDisplayName = accountDisplayName
		self.userInfo = userInfo
		super.init(name: "CloudKitRemoteNotificationOperation")
	}

	override func run() {
		guard let accountZone, let articlesZone else {
			didComplete()
			return
		}

		Task { @MainActor in
			let activityLog = ActivityLog.shared
			let owner = ActivityOwner.account(accountID: accountID, displayName: accountDisplayName)
			let taskNumber = activityLog.nextTaskNumberString()

			let accountZoneActivityID = activityLog.createActivity(owner: owner, kind: .refreshFeedList, detail: "Receiving account changes \(taskNumber)")
			activityLog.didStart(id: accountZoneActivityID)

			Self.logger.debug("iCloud: Processing remote notification")
			do {
				let result = try await accountZone.receiveRemoteNotification(userInfo: userInfo)
				notificationResult = notificationResult.merging(result)
				activityLog.didComplete(id: accountZoneActivityID)
			} catch {
				notificationError = error
				activityLog.didFail(id: accountZoneActivityID, error: error)
			}

			let articlesZoneActivityID = activityLog.createActivity(owner: owner, kind: .refreshArticleStatuses, detail: "Receiving article changes \(taskNumber)")
			activityLog.didStart(id: articlesZoneActivityID)
			do {
				let result = try await articlesZone.receiveRemoteNotification(userInfo: self.userInfo)
				notificationResult = notificationResult.merging(result)
				activityLog.didComplete(id: articlesZoneActivityID)
			} catch {
				notificationError = notificationError ?? error
				activityLog.didFail(id: articlesZoneActivityID, error: error)
			}

			Self.logger.debug("iCloud: Finished processing remote notification")
			didComplete()
		}
	}
}
