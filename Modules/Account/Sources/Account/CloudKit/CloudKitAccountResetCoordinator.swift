//
//  CloudKitAccountResetCoordinator.swift
//  Account
//

import CloudKit
import Foundation

public enum CloudKitAccountResetPhase: String, CaseIterable, Sendable {
	case idle
	case zonesDeleted
	case localAccountDeleted
	case accountRecreated
	case cloudInitialized
	case verified
}

@MainActor final class CloudKitAccountResetCoordinator {
	static let phaseDefaultsKey = "CloudKitAccountResetPhase"

	private let userDefaults: UserDefaults
	private let deleteZone: (CKRecordZone.ID) async throws -> Void
	private let deleteLocalAccount: () async throws -> Void
	private let recreateAccount: () async throws -> Void
	private let initializeCloud: () async throws -> Void
	private let verifyEmpty: () async throws -> Void

	var phase: CloudKitAccountResetPhase {
		get {
			Self.persistedPhase(in: userDefaults)
		}
		set {
			if newValue == .idle {
				userDefaults.removeObject(forKey: Self.phaseDefaultsKey)
			} else {
				userDefaults.set(newValue.rawValue, forKey: Self.phaseDefaultsKey)
			}
		}
	}

	static func persistedPhase(in userDefaults: UserDefaults) -> CloudKitAccountResetPhase {
		guard let rawValue = userDefaults.string(forKey: phaseDefaultsKey) else {
			return .idle
		}
		return CloudKitAccountResetPhase(rawValue: rawValue) ?? .idle
	}

	init(
		userDefaults: UserDefaults,
		deleteZone: @escaping (CKRecordZone.ID) async throws -> Void,
		deleteLocalAccount: @escaping () async throws -> Void,
		recreateAccount: @escaping () async throws -> Void,
		initializeCloud: @escaping () async throws -> Void,
		verifyEmpty: @escaping () async throws -> Void
	) {
		self.userDefaults = userDefaults
		self.deleteZone = deleteZone
		self.deleteLocalAccount = deleteLocalAccount
		self.recreateAccount = recreateAccount
		self.initializeCloud = initializeCloud
		self.verifyEmpty = verifyEmpty
	}

	func run(afterPhase: (CloudKitAccountResetPhase) throws -> Void = { _ in }) async throws {
		while true {
			switch phase {
			case .idle:
				try await deleteZone(CKRecordZone.ID(zoneName: "Account", ownerName: CKCurrentUserDefaultName))
				try await deleteZone(CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName))
				try persist(.zonesDeleted, afterPhase: afterPhase)
			case .zonesDeleted:
				try await deleteLocalAccount()
				try persist(.localAccountDeleted, afterPhase: afterPhase)
			case .localAccountDeleted:
				try await recreateAccount()
				try persist(.accountRecreated, afterPhase: afterPhase)
			case .accountRecreated:
				try await initializeCloud()
				try persist(.cloudInitialized, afterPhase: afterPhase)
			case .cloudInitialized:
				try await verifyEmpty()
				try persist(.verified, afterPhase: afterPhase)
			case .verified:
				phase = .idle
				return
			}
		}
	}

	private func persist(
		_ completedPhase: CloudKitAccountResetPhase,
		afterPhase: (CloudKitAccountResetPhase) throws -> Void
	) throws {
		phase = completedPhase
		try afterPhase(completedPhase)
	}
}
