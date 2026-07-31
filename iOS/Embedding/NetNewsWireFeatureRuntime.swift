import Account
import RSCore

@MainActor
public final class NetNewsWireFeatureRuntime {
	private static var configuredCapabilities: NetNewsWireFeatureCapabilities?
	public let configuration: NetNewsWireFeatureConfiguration

	public init(
		configuration: NetNewsWireFeatureConfiguration,
		cloudKitContainerConfigurator: @MainActor (String) throws -> Void = CloudKitAccountContainerConfiguration.configure(identifier:)
	) throws {
		if let configuredCapabilities = Self.configuredCapabilities,
			configuredCapabilities != configuration.capabilities {
			throw NetNewsWireFeatureConfigurationError.alreadyConfigured
		}
		do {
			try NetNewsWireEnvironment.preflight(configuration.environmentValues)
		} catch NetNewsWireEnvironmentError.conflictingConfiguration {
			throw NetNewsWireFeatureConfigurationError.alreadyConfigured
		}
		try cloudKitContainerConfigurator(configuration.cloudKitContainerIdentifier)
		do {
			try NetNewsWireEnvironment.configure(configuration.environmentValues)
		} catch NetNewsWireEnvironmentError.conflictingConfiguration {
			throw NetNewsWireFeatureConfigurationError.alreadyConfigured
		}
		Self.configuredCapabilities = configuration.capabilities
		self.configuration = configuration
	}

	public func makeHost(
		publishingActions: NetNewsWirePublishingActions = .disabled,
		highlightActions: NetNewsWireHighlightActions = .disabled
	) throws -> NetNewsWireFeatureHost {
		try NetNewsWireFeatureHost(
			capabilities: configuration.capabilities,
			globalMutationSeams: .live,
			publishingActions: publishingActions,
			highlightActions: highlightActions
		)
	}

	func makeHost(
		globalMutationSeams: NetNewsWireHostGlobalMutationSeams,
		publishingActions: NetNewsWirePublishingActions = .disabled,
		highlightActions: NetNewsWireHighlightActions = .disabled
	) throws -> NetNewsWireFeatureHost {
		try NetNewsWireFeatureHost(
			capabilities: configuration.capabilities,
			globalMutationSeams: globalMutationSeams,
			publishingActions: publishingActions,
			highlightActions: highlightActions
		)
	}

	public func receiveRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
		await AccountManager.shared.receiveRemoteNotification(userInfo: userInfo)
	}

	public func applicationWillEnterForeground() {
		applicationLifecycle?.applicationWillEnterForeground()
	}

	public func applicationDidEnterBackground() {
		applicationLifecycle?.applicationDidEnterBackground()
	}

	public func didReceiveMemoryWarning() {
		applicationLifecycle?.didReceiveMemoryWarning()
	}

	private var applicationLifecycle: NetNewsWireFeatureApplicationLifecycle? {
		guard let appDelegate else { return nil }
		return NetNewsWireFeatureApplicationLifecycle(
			resumeIfNecessary: { appDelegate.resumeIfNecessary() },
			prepareAccountsForForeground: { appDelegate.prepareAccountsForForeground() },
			prepareAccountsForBackground: { appDelegate.prepareAccountsForBackground() },
			didReceiveMemoryWarning: { appDelegate.applicationDidReceiveMemoryWarning(UIApplication.shared) }
		)
	}
}
