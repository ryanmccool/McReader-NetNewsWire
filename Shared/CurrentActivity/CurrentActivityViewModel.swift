//
//  CurrentActivityViewModel.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 6/9/26.
//

import Foundation
import ActivityLog
import RSCore

struct ActivityDisplayText {
	let title: String
	let detail: String?
}

@MainActor final class CurrentActivityViewModel {

	private(set) var displayedActivities = [Activity]() {
		didSet {
			displayedActivitiesDidChange?()
		}
	}

	var displayedActivitiesDidChange: (() -> Void)?

	private var isObserving = false
	private var updateTimer: Timer?

	private static let updateInterval: TimeInterval = 0.5
	private static let lingerDuration: TimeInterval = 2.0

	func start() {
		if !isObserving {
			NotificationCenter.default.addObserver(self, selector: #selector(handleActivityDidChange(_:)), name: .activityDidChange, object: nil)
			isObserving = true
		}
		scheduleUpdate()
	}

	func stop() {
		if isObserving {
			NotificationCenter.default.removeObserver(self, name: .activityDidChange, object: nil)
			isObserving = false
		}
		invalidateUpdateTimer()
	}

	@objc func handleActivityDidChange(_ notification: Notification) {
		scheduleUpdate()
	}

	static func symbolName(for state: ActivityState) -> String {
		switch state {
		case .pending:
			return "circle"
		case .running:
			return "circle.fill"
		case .completed:
			return "checkmark.circle.fill"
		case .failed:
			return "xmark.circle.fill"
		}
	}

	static func accessibilityLabel(for state: ActivityState) -> String {
		switch state {
		case .pending:
			return NNWLocalizedString("Pending", comment: "Pending")
		case .running:
			return NNWLocalizedString("Running", comment: "Running")
		case .completed:
			return NNWLocalizedString("Completed", comment: "Completed")
		case .failed:
			return NNWLocalizedString("Failed", comment: "Failed")
		}
	}

	static func displayText(for activity: Activity) -> ActivityDisplayText {
		switch activity.kind {
		case .refreshFeedContent(let feedURL):
			if let feedName = activity.detail {
				return ActivityDisplayText(title: feedName, detail: feedURL)
			}
			return ActivityDisplayText(title: feedURL, detail: nil)
		case .findFeed(let urlString):
			return ActivityDisplayText(title: NNWLocalizedString("Finding feed", comment: "Finding feed"), detail: urlString)
		case .fetchFeedCandidate(let urlString):
			return ActivityDisplayText(title: NNWLocalizedString("Fetching", comment: "Fetching"), detail: urlString)
		case .downloadFeedImage(let feedURL):
			return ActivityDisplayText(title: NNWLocalizedString("Downloading image", comment: "Downloading image"), detail: feedURL)
		case .downloadFavicon(let faviconURL):
			return ActivityDisplayText(title: NNWLocalizedString("Downloading favicon", comment: "Downloading favicon"), detail: faviconURL)
		case .downloadAvatar(let avatarURL):
			return ActivityDisplayText(title: NNWLocalizedString("Downloading avatar", comment: "Downloading avatar"), detail: avatarURL)
		case .downloadHTMLMetadata(let urlString):
			return ActivityDisplayText(title: NNWLocalizedString("Downloading metadata", comment: "Downloading metadata"), detail: urlString)
		default:
			return ActivityDisplayText(title: activity.kind.simpleDisplayName ?? "", detail: activity.detail)
		}
	}
}

// MARK: - Private

private extension CurrentActivityViewModel {

	func scheduleUpdate() {
		guard updateTimer == nil else {
			return
		}
		updateTimer = Timer.scheduledTimer(timeInterval: Self.updateInterval, target: self, selector: #selector(update), userInfo: nil, repeats: true)
		update()
	}

	@objc func update() {
		let activities = currentActivities()
		if activities != displayedActivities {
			displayedActivities = activities
		}
		if activities.isEmpty {
			invalidateUpdateTimer()
		}
	}

	func currentActivities() -> [Activity] {
		let manager = ActivityLog.shared

		var activities = [Activity]()
		activities.append(contentsOf: manager.runningActivities)
		activities.append(contentsOf: manager.pendingActivities)

		let now = Date()
		for activity in manager.completedActivities {
			if let endDate = activity.endDate, now.timeIntervalSince(endDate) < Self.lingerDuration {
				activities.append(activity)
			}
		}

		return activities
	}

	func invalidateUpdateTimer() {
		updateTimer?.invalidate()
		updateTimer = nil
	}
}
