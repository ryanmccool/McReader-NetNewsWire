//
//  ArticleTextSize.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 11/3/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import Foundation
import RSCore

enum ArticleTextSize: Int, CaseIterable, Identifiable {
	case small = 1
	case medium = 2
	case large = 3
	case xlarge = 4
	case xxlarge = 5

	var id: String { description() }

	var cssClass: String {
		switch self {
		case .small:
			return "smallText"
		case .medium:
			return "mediumText"
		case .large:
			return "largeText"
		case .xlarge:
			return "xLargeText"
		case .xxlarge:
			return "xxLargeText"
		}
	}

	func description() -> String {
		switch self {
		case .small:
			return NNWLocalizedString("Small", comment: "Small")
		case .medium:
			return NNWLocalizedString("Medium", comment: "Medium")
		case .large:
			return NNWLocalizedString("Large", comment: "Large")
		case .xlarge:
			return NNWLocalizedString("Extra Large", comment: "X-Large")
		case .xxlarge:
			return NNWLocalizedString("Extra Extra Large", comment: "XX-Large")
		}
	}

}
