import Foundation

enum NetNewsWireBundleResolution {
	static func resourceBundle(environment: NetNewsWireEnvironmentValues?) throws -> Bundle {
		guard let environment else {
			throw NetNewsWireEnvironmentError.notConfigured
		}
		return environment.resourceBundle
	}
}

public extension Bundle {
	static var netNewsWire: Bundle {
		guard let resourceBundle = try? NetNewsWireBundleResolution.resourceBundle(environment: NetNewsWireEnvironment.current) else {
			preconditionFailure("NetNewsWireEnvironment must be configured before resolving resources.")
		}
		return resourceBundle
	}

	static var isNetNewsWireEmbeddedHost: Bool {
		Bundle.main.bundleURL != Bundle.netNewsWire.bundleURL
	}
}

public func NNWLocalizedString(_ key: String, comment: String) -> String {
	Bundle.netNewsWire.localizedString(forKey: key, value: nil, table: nil)
}
