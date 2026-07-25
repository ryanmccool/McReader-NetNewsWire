import Foundation

public enum NetNewsWireEnvironmentMode: Sendable {
	case embedded
	case standalone
}

public struct NetNewsWireEnvironmentValues: @unchecked Sendable {
	public static let defaultUserAgent = "NetNewsWire (RSS Reader; https://netnewswire.com/)"
	public static let defaultExtendedUserAgent = "NetNewsWire (RSS Reader; https://netnewswire.com/; [platform]; [version] ([build]))"

	public let mode: NetNewsWireEnvironmentMode
	public let dataDirectoryURL: URL
	public let cacheDirectoryURL: URL
	public let userDefaultsSuiteName: String
	public let cloudKitContainerIdentifier: String
	public let resourceBundle: Bundle
	public let userAgent: String
	public let extendedUserAgent: String

	public init(
		mode: NetNewsWireEnvironmentMode,
		dataDirectoryURL: URL,
		cacheDirectoryURL: URL,
		userDefaultsSuiteName: String,
		cloudKitContainerIdentifier: String,
		resourceBundle: Bundle,
		userAgent: String = Self.defaultUserAgent,
		extendedUserAgent: String = Self.defaultExtendedUserAgent
	) {
		self.mode = mode
		self.dataDirectoryURL = dataDirectoryURL
		self.cacheDirectoryURL = cacheDirectoryURL
		self.userDefaultsSuiteName = userDefaultsSuiteName
		self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
		self.resourceBundle = resourceBundle
		self.userAgent = userAgent
		self.extendedUserAgent = extendedUserAgent
	}

	fileprivate func isEquivalent(to other: Self) -> Bool {
		mode == other.mode &&
		dataDirectoryURL.standardizedFileURL == other.dataDirectoryURL.standardizedFileURL &&
		cacheDirectoryURL.standardizedFileURL == other.cacheDirectoryURL.standardizedFileURL &&
		userDefaultsSuiteName == other.userDefaultsSuiteName &&
		cloudKitContainerIdentifier == other.cloudKitContainerIdentifier &&
		resourceBundle.bundleURL.standardizedFileURL == other.resourceBundle.bundleURL.standardizedFileURL &&
		userAgent == other.userAgent &&
		extendedUserAgent == other.extendedUserAgent
	}
}

public enum NetNewsWireEnvironmentError: Error, Equatable {
	case notConfigured
	case conflictingConfiguration
}

public enum NetNewsWireEnvironment {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var storedValues: NetNewsWireEnvironmentValues?

	public static var current: NetNewsWireEnvironmentValues? {
		lock.lock()
		defer { lock.unlock() }
		return storedValues
	}

	public static func preflight(_ values: NetNewsWireEnvironmentValues) throws {
		lock.lock()
		defer { lock.unlock() }

		if let storedValues, !storedValues.isEquivalent(to: values) {
			throw NetNewsWireEnvironmentError.conflictingConfiguration
		}
	}

	public static func configure(_ values: NetNewsWireEnvironmentValues) throws {
		lock.lock()
		defer { lock.unlock() }

		if let storedValues {
			guard storedValues.isEquivalent(to: values) else {
				throw NetNewsWireEnvironmentError.conflictingConfiguration
			}
			return
		}

		storedValues = values
	}
}
