//
//  RefreshInterval.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 4/23/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import Foundation
import RSCore

enum RefreshInterval: Int, CaseIterable, Identifiable {
	case manually = 1
	case every30Minutes = 3
	case everyHour = 4
	case every2Hours = 5
	case every4Hours = 6
	case every8Hours = 7

	func inSeconds() -> TimeInterval {
		switch self {
		case .manually:
			return 0
		case .every30Minutes:
			return 30 * 60
		case .everyHour:
			return 60 * 60
		case .every2Hours:
			return 2 * 60 * 60
		case .every4Hours:
			return 4 * 60 * 60
		case .every8Hours:
			return 8 * 60 * 60
		}
	}

	var id: String { description() }

	func description() -> String {
		switch self {
		case .manually:
			return NNWLocalizedString("Manually", comment: "Manually")
		case .every30Minutes:
			return NNWLocalizedString("Every 30 Minutes", comment: "Every 30 Minutes")
		case .everyHour:
			return NNWLocalizedString("Every Hour", comment: "Every Hour")
		case .every2Hours:
			return NNWLocalizedString("Every 2 Hours", comment: "Every 2 Hours")
		case .every4Hours:
			return NNWLocalizedString("Every 4 Hours", comment: "Every 4 Hours")
		case .every8Hours:
			return NNWLocalizedString("Every 8 Hours", comment: "Every 8 Hours")
		}
	}

}
