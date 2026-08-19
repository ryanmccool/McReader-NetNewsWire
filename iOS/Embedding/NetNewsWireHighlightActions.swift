import Foundation

public struct NetNewsWireHighlightRecord: Identifiable, Equatable, Sendable {
	public let id: UUID
	public let articleKey: String
	public let selectedText: String
	public let prefixContext: String
	public let suffixContext: String
	public let startOffset: Int
	public let endOffset: Int
	public let domRangeData: Data?
	public let renditionKindRaw: String
	public let renderedTextFingerprint: String
	public let articleTitle: String
	public let creator: String?
	public let preferredURL: URL?
	public let createdAt: Date
	public let updatedAt: Date

	public init(
		id: UUID, articleKey: String, selectedText: String,
		prefixContext: String, suffixContext: String,
		startOffset: Int, endOffset: Int, domRangeData: Data?,
		renditionKindRaw: String, renderedTextFingerprint: String,
		articleTitle: String, creator: String?, preferredURL: URL?,
		createdAt: Date, updatedAt: Date
	) {
		self.id = id
		self.articleKey = articleKey
		self.selectedText = selectedText
		self.prefixContext = prefixContext
		self.suffixContext = suffixContext
		self.startOffset = startOffset
		self.endOffset = endOffset
		self.domRangeData = domRangeData
		self.renditionKindRaw = renditionKindRaw
		self.renderedTextFingerprint = renderedTextFingerprint
		self.articleTitle = articleTitle
		self.creator = creator
		self.preferredURL = preferredURL
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}
}

/// Rich markup resolved from the currently rendered article for one Markdown export.
/// This is deliberately separate from `NetNewsWireHighlightRecord`: it is never
/// persisted through the highlight store.
public struct NetNewsWireHighlightRichText: Equatable, Sendable {
	public let id: UUID
	public let selectedText: String
	public let html: String?
	public let baseURL: URL?

	public init(id: UUID, selectedText: String, html: String?, baseURL: URL?) {
		self.id = id
		self.selectedText = selectedText
		self.html = html
		self.baseURL = baseURL
	}
}

public enum NetNewsWireHighlightActionError: Error, Equatable, Sendable {
	case unavailable
}

@MainActor
public final class NetNewsWireHighlightObservation {
	private var cancellation: (@MainActor () -> Void)?

	public init(cancel: @escaping @MainActor () -> Void) {
		self.cancellation = cancel
	}

	public func cancel() {
		cancellation?()
		cancellation = nil
	}
}

@MainActor
public struct NetNewsWireHighlightActions {
	public let load: (String) async throws -> [NetNewsWireHighlightRecord]
	public let insert: (NetNewsWireHighlightRecord) async throws -> Void
	public let delete: (UUID) async throws -> Void
	public let observe: (
		String,
		@escaping @MainActor ([NetNewsWireHighlightRecord]) -> Void,
		@escaping @MainActor () -> Void
	) -> NetNewsWireHighlightObservation
	let isEnabled: Bool

	public init(
		load: @escaping (String) async throws -> [NetNewsWireHighlightRecord],
		insert: @escaping (NetNewsWireHighlightRecord) async throws -> Void,
		delete: @escaping (UUID) async throws -> Void,
		observe: @escaping (
			String,
			@escaping @MainActor ([NetNewsWireHighlightRecord]) -> Void,
			@escaping @MainActor () -> Void
		) -> NetNewsWireHighlightObservation
	) {
		self.load = load
		self.insert = insert
		self.delete = delete
		self.observe = observe
		self.isEnabled = true
	}

	private init(
		load: @escaping (String) async throws -> [NetNewsWireHighlightRecord],
		insert: @escaping (NetNewsWireHighlightRecord) async throws -> Void,
		delete: @escaping (UUID) async throws -> Void,
		observe: @escaping (
			String,
			@escaping @MainActor ([NetNewsWireHighlightRecord]) -> Void,
			@escaping @MainActor () -> Void
		) -> NetNewsWireHighlightObservation,
		isEnabled: Bool
	) {
		self.load = load
		self.insert = insert
		self.delete = delete
		self.observe = observe
		self.isEnabled = isEnabled
	}

	public static let disabled = NetNewsWireHighlightActions(
		load: { _ in throw NetNewsWireHighlightActionError.unavailable },
		insert: { _ in throw NetNewsWireHighlightActionError.unavailable },
		delete: { _ in throw NetNewsWireHighlightActionError.unavailable },
		observe: { _, _, didFail in
			didFail()
			return NetNewsWireHighlightObservation(cancel: {})
		},
		isEnabled: false
	)
}
