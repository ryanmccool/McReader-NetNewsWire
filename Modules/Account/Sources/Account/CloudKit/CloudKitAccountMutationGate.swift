//
//  CloudKitAccountMutationGate.swift
//  Account
//

import Foundation

enum CloudKitAccountMutationKind: Sendable, Equatable {
	case importOPML
	case feed
	case folder
	case articleStatus
	case reset
	case refresh
	case remoteNotification
}

extension Notification.Name {
	public static let CloudKitAccountMutationStateDidChange = Notification.Name("CloudKitAccountMutationStateDidChange")
}

@MainActor final class CloudKitAccountMutationGate {
	private(set) var activeKind: CloudKitAccountMutationKind?
	private var isArticleStatusMutationActive = false
	private var articleStatusMutationWaiters = [CheckedContinuation<Void, Never>]()

	func withMutation<T>(
		kind: CloudKitAccountMutationKind,
		operation: () async throws -> T
	) async throws -> T {
		guard activeKind == nil, canStartMutation(kind) else {
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

	func withLocalArticleStatusMutation<T>(
		operation: @MainActor () async throws -> T
	) async throws -> T {
		switch activeKind {
		case nil:
			return try await withMutation(kind: .articleStatus) {
				try await withArticleStatusMutation(operation: operation)
			}
		case .refresh, .remoteNotification, .articleStatus:
			return try await withArticleStatusMutation(operation: operation)
		default:
			throw AccountError.operationInProgress
		}
	}

	func withArticleStatusMutation<T>(
		operation: @MainActor () async throws -> T
	) async rethrows -> T {
		if isArticleStatusMutationActive {
			await withCheckedContinuation { continuation in
				articleStatusMutationWaiters.append(continuation)
			}
		} else {
			isArticleStatusMutationActive = true
		}
		defer {
			if !articleStatusMutationWaiters.isEmpty {
				articleStatusMutationWaiters.removeFirst().resume()
			} else {
				isArticleStatusMutationActive = false
			}
		}
		return try await operation()
	}

	private func canStartMutation(_ kind: CloudKitAccountMutationKind) -> Bool {
		guard isArticleStatusMutationActive else {
			return true
		}
		switch kind {
		case .refresh, .remoteNotification, .articleStatus:
			return true
		case .importOPML, .feed, .folder, .reset:
			return false
		}
	}
}
