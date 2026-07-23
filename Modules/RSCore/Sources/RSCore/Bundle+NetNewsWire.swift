import Foundation

public extension Bundle {
	static var netNewsWire: Bundle {
		if let frameworkBundle = Bundle.allFrameworks.first(where: { $0.bundleURL.lastPathComponent == "NetNewsWireFeature.framework" }) {
			return frameworkBundle
		}
		if Bundle.main.url(forResource: "Main", withExtension: "storyboardc") != nil,
		   Bundle.main.url(forResource: "ContentRules", withExtension: "json") != nil {
			return Bundle.main
		}
		return Bundle.main
	}

	static var isNetNewsWireEmbeddedHost: Bool {
		Bundle.main.bundleURL != Bundle.netNewsWire.bundleURL
	}
}
