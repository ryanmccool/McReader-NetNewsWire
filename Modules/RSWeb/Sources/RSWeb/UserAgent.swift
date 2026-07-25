//
//  UserAgent.swift
//  RSWeb
//
//  Created by Brent Simmons on 8/27/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore

nonisolated public struct UserAgent {

	public static func fromInfoPlist() -> String? {

		return NetNewsWireEnvironment.current?.userAgent
			?? Bundle.main.object(forInfoDictionaryKey: "UserAgent") as? String
	}

	public static func headers() -> [AnyHashable: String]? {

		guard let userAgent = fromInfoPlist() else {
			return nil
		}

		return [HTTPRequestHeader.userAgent: userAgent]
	}
}
