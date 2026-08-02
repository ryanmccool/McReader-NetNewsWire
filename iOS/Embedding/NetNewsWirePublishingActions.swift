import Foundation

public struct NetNewsWirePublishingCapture: Equatable, Sendable {
	public var selectedText: String?
	public var title: String
	public var creator: String?
	public var preferredURL: URL

	public init(selectedText: String?, title: String, creator: String?, preferredURL: URL) {
		self.selectedText = selectedText
		self.title = title
		self.creator = creator
		self.preferredURL = preferredURL
	}
}

public enum NetNewsWirePublishingPostKind: Equatable, Sendable {
	case quotation
	case blogmark
	case note
}

public enum NetNewsWirePublishingIntent: Equatable, Sendable {
	case capture
	case postAs(NetNewsWirePublishingPostKind)
}

@MainActor
public struct NetNewsWirePublishingActions {
	public var send: (NetNewsWirePublishingCapture, NetNewsWirePublishingIntent) -> Void
	public var shareMarkdown: (NetNewsWirePublishingCapture) -> Void
	let isEnabled: Bool
	let isMarkdownSharingEnabled: Bool

	public init(send: @escaping (NetNewsWirePublishingCapture, NetNewsWirePublishingIntent) -> Void) {
		self.send = send
		self.shareMarkdown = { _ in }
		self.isEnabled = true
		self.isMarkdownSharingEnabled = false
	}

	public init(
		send: @escaping (NetNewsWirePublishingCapture, NetNewsWirePublishingIntent) -> Void,
		shareMarkdown: @escaping (NetNewsWirePublishingCapture) -> Void
	) {
		self.send = send
		self.shareMarkdown = shareMarkdown
		self.isEnabled = true
		self.isMarkdownSharingEnabled = true
	}

	private init(
		send: @escaping (NetNewsWirePublishingCapture, NetNewsWirePublishingIntent) -> Void,
		shareMarkdown: @escaping (NetNewsWirePublishingCapture) -> Void,
		isEnabled: Bool,
		isMarkdownSharingEnabled: Bool
	) {
		self.send = send
		self.shareMarkdown = shareMarkdown
		self.isEnabled = isEnabled
		self.isMarkdownSharingEnabled = isMarkdownSharingEnabled
	}

	public static let disabled = NetNewsWirePublishingActions(
		send: { _, _ in },
		shareMarkdown: { _ in },
		isEnabled: false,
		isMarkdownSharingEnabled: false
	)
}

struct NetNewsWirePublishingMenuText {
	struct ActionTitles {
		let captureLink: String
		let postQuote: String
		let postLink: String
		let postNote: String
		let captureSelection: String
		let postHighlights: String
		let shareMarkdown: String
	}

	static func accessibilityLabel(
		actionsEnabled: Bool,
		existingLabel: String?,
		localize: (String, String) -> String
	) -> String? {
		guard actionsEnabled else { return existingLabel }
		return localize("Publishing actions", "Publishing actions accessibility label")
	}

	static func actionTitles(localize: (String, String) -> String) -> ActionTitles {
		ActionTitles(
			captureLink: localize("Capture Link", "Command"),
			postQuote: localize("Post Quote...", "Command"),
			postLink: localize("Post Link...", "Command"),
			postNote: localize("Post Note...", "Command"),
			captureSelection: localize("Capture Selection", "Command"),
			postHighlights: localize("Post Highlights...", "Command"),
			shareMarkdown: localize("Share as Markdown...", "Command")
		)
	}
}

enum NetNewsWireMarkdownSharing {
	static func capture(
		base: NetNewsWirePublishingCapture,
		renderedHighlights: [NetNewsWireHighlightRecord],
		resolvedPositions: [UUID: Int]
	) -> NetNewsWirePublishingCapture {
		var capture = base
		capture.selectedText = ArticleHighlightPosting.quotation(
			records: renderedHighlights,
			resolvedOffsets: resolvedPositions
		)
		return capture
	}
}

@MainActor
enum NetNewsWireHighlightPublishing {
	static func capture(
		articleKey: String,
		currentTitle: String,
		currentCreator: String?,
		currentPreferredURL: URL?,
		load: (String) async throws -> [NetNewsWireHighlightRecord],
		resolvedPositions: () async -> [UUID: Int]
	) async -> NetNewsWirePublishingCapture? {
		guard let records = try? await load(articleKey),
			let quotation = ArticleHighlightPosting.quotation(
				records: records,
				resolvedOffsets: await resolvedPositions()
			) else {
			return nil
		}

		let persistedMetadata = records.first { validPreferredURL($0.preferredURL) != nil }
		guard let preferredURL = validPreferredURL(currentPreferredURL)
			?? persistedMetadata.flatMap({ validPreferredURL($0.preferredURL) }) else {
			return nil
		}
		let title = nonblank(currentTitle) ?? persistedMetadata.flatMap { nonblank($0.articleTitle) } ?? ""
		let creator = nonblank(currentCreator) ?? persistedMetadata.flatMap { nonblank($0.creator) }
		return NetNewsWirePublishingCapture(
			selectedText: quotation,
			title: title,
			creator: creator,
			preferredURL: preferredURL
		)
	}

	private static func nonblank(_ value: String?) -> String? {
		guard let value else {
			return nil
		}
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : value
	}

	private static func validPreferredURL(_ url: URL?) -> URL? {
		guard let url,
			let scheme = url.scheme?.lowercased(),
			(scheme == "http" || scheme == "https"),
			let host = url.host(), !host.isEmpty else {
			return nil
		}
		return url
	}
}

@MainActor
struct NetNewsWireHighlightPostAction {
	private let articleKey: String
	private let webViewIdentifier: ObjectIdentifier

	init(articleKey: String, webViewController: AnyObject) {
		self.articleKey = articleKey
		self.webViewIdentifier = ObjectIdentifier(webViewController)
	}

	func perform(
		currentArticleKey: String?,
		currentWebViewController: AnyObject?,
		post: () async -> Void
	) async {
		guard currentArticleKey == articleKey,
			let currentWebViewController,
			ObjectIdentifier(currentWebViewController) == webViewIdentifier else {
			return
		}
		await post()
	}
}
