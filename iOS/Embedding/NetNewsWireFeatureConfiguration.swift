import Foundation
import RSCore

private final class NetNewsWireFeatureBundleToken {}

public extension Bundle {
	static let netNewsWireFeatureResources = Bundle(for: NetNewsWireFeatureBundleToken.self)
}

public struct NetNewsWireFeatureCapabilities: Equatable, Sendable {
	public let mayPresentUserNotifications: Bool
	public let mayHandleNotificationResponses: Bool
	public let mayChangeApplicationBadge: Bool
	public let mayRegisterBackgroundTasks: Bool
	public let mayInstallQuickActions: Bool
	public let extensionsAreAvailable: Bool
	public let mayRestoreSceneState: Bool
	public let mayUseStandaloneSceneDelegates: Bool
	public let mayDonateActivities: Bool

	public init(
		mayPresentUserNotifications: Bool,
		mayHandleNotificationResponses: Bool,
		mayChangeApplicationBadge: Bool,
		mayRegisterBackgroundTasks: Bool,
		mayInstallQuickActions: Bool,
		extensionsAreAvailable: Bool,
		mayRestoreSceneState: Bool,
		mayUseStandaloneSceneDelegates: Bool,
		mayDonateActivities: Bool
	) {
		self.mayPresentUserNotifications = mayPresentUserNotifications
		self.mayHandleNotificationResponses = mayHandleNotificationResponses
		self.mayChangeApplicationBadge = mayChangeApplicationBadge
		self.mayRegisterBackgroundTasks = mayRegisterBackgroundTasks
		self.mayInstallQuickActions = mayInstallQuickActions
		self.extensionsAreAvailable = extensionsAreAvailable
		self.mayRestoreSceneState = mayRestoreSceneState
		self.mayUseStandaloneSceneDelegates = mayUseStandaloneSceneDelegates
		self.mayDonateActivities = mayDonateActivities
	}

	public static let containedReader = Self(
		mayPresentUserNotifications: false,
		mayHandleNotificationResponses: false,
		mayChangeApplicationBadge: false,
		mayRegisterBackgroundTasks: false,
		mayInstallQuickActions: false,
		extensionsAreAvailable: false,
		mayRestoreSceneState: false,
		mayUseStandaloneSceneDelegates: false,
		mayDonateActivities: false
	)

	public static let standalone = Self(
		mayPresentUserNotifications: true,
		mayHandleNotificationResponses: true,
		mayChangeApplicationBadge: true,
		mayRegisterBackgroundTasks: true,
		mayInstallQuickActions: true,
		extensionsAreAvailable: true,
		mayRestoreSceneState: true,
		mayUseStandaloneSceneDelegates: true,
		mayDonateActivities: true
	)
}

public enum NetNewsWireFeatureConfigurationError: Error, Equatable {
	case invalidDirectoryParent(URL)
	case emptyUserDefaultsSuiteName
	case invalidCloudKitContainerIdentifier
	case invalidFeatureBundle
	case alreadyConfigured
	case missingRootController
}

extension NetNewsWireFeatureConfigurationError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .invalidDirectoryParent:
			return "The Feeds storage directory is unavailable."
		case .emptyUserDefaultsSuiteName:
			return "The Feeds settings store is unavailable."
		case .invalidCloudKitContainerIdentifier:
			return "The iCloud container for Feeds is invalid or unavailable."
		case .invalidFeatureBundle:
			return "The Feeds resources are unavailable."
		case .alreadyConfigured:
			return "Feeds were already configured with different settings."
		case .missingRootController:
			return "The Feeds interface could not be loaded."
		}
	}
}

public struct NetNewsWireFeatureConfiguration: @unchecked Sendable {
	public let dataDirectoryURL: URL
	public let cacheDirectoryURL: URL
	public let userDefaultsSuiteName: String
	public let cloudKitContainerIdentifier: String
	public let resourceBundle: Bundle
	public let capabilities: NetNewsWireFeatureCapabilities

	public init(
		dataDirectoryURL: URL,
		cacheDirectoryURL: URL,
		userDefaultsSuiteName: String,
		cloudKitContainerIdentifier: String,
		resourceBundle: Bundle,
		capabilities: NetNewsWireFeatureCapabilities
	) throws {
		try Self.validateParent(of: dataDirectoryURL)
		try Self.validateParent(of: cacheDirectoryURL)

		guard !userDefaultsSuiteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw NetNewsWireFeatureConfigurationError.emptyUserDefaultsSuiteName
		}
		guard cloudKitContainerIdentifier.hasPrefix("iCloud.") else {
			throw NetNewsWireFeatureConfigurationError.invalidCloudKitContainerIdentifier
		}
		guard resourceBundle.bundleURL.standardizedFileURL == Bundle.netNewsWireFeatureResources.bundleURL.standardizedFileURL else {
			throw NetNewsWireFeatureConfigurationError.invalidFeatureBundle
		}

		self.dataDirectoryURL = dataDirectoryURL
		self.cacheDirectoryURL = cacheDirectoryURL
		self.userDefaultsSuiteName = userDefaultsSuiteName
		self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
		self.resourceBundle = resourceBundle
		self.capabilities = capabilities
	}

	var environmentValues: NetNewsWireEnvironmentValues {
		NetNewsWireEnvironmentValues(
			mode: .embedded,
			dataDirectoryURL: dataDirectoryURL,
			cacheDirectoryURL: cacheDirectoryURL,
			userDefaultsSuiteName: userDefaultsSuiteName,
			cloudKitContainerIdentifier: cloudKitContainerIdentifier,
			resourceBundle: resourceBundle
		)
	}

	private static func validateParent(of url: URL) throws {
		let parentURL = url.deletingLastPathComponent()
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
			isDirectory.boolValue,
			FileManager.default.isWritableFile(atPath: parentURL.path) else {
			throw NetNewsWireFeatureConfigurationError.invalidDirectoryParent(url)
		}
	}
}
