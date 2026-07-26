//
//  CloudKitAccountMutationGate.swift
//  Account
//

import Foundation

enum CloudKitAccountMutationKind: Sendable, Equatable {
	case importOPML
	case feed
	case folder
	case refresh
	case remoteNotification
}

extension Notification.Name {
	public static let CloudKitAccountMutationStateDidChange = Notification.Name("CloudKitAccountMutationStateDidChange")
}

@MainActor final class CloudKitAccountMutationGate {
	private(set) var activeKind: CloudKitAccountMutationKind?

	func withMutation<T>(
		kind: CloudKitAccountMutationKind,
		operation: () async throws -> T
	) async throws -> T {
		guard activeKind == nil else {
			throw AccountError.operationInProgress
		}
		activeKind = kind
		NotificationCenter.default.post(name: .CloudKitAccountMutationStateDidChange, object: self)
		defer {
			activeKind = nil
			NotificationCenter.default.post(name: .CloudKitAccountMutationStateDidChange, object: self)
		}
		return try await operation()
	}
}
