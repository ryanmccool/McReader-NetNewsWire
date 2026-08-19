import Foundation

public struct NetNewsWireMarkdownCapture: Equatable, Sendable {
	public var selectedText: String?
	public var title: String
	public var creator: String?
	public var preferredURL: URL
	public var renderedArticleHTML: String?
	public var renderedArticleBaseURL: URL?
	/// Transient rich fragments for a saved-highlight Markdown export.
	public var highlightRichText: [NetNewsWireHighlightRichText]

	public init(
		selectedText: String?,
		title: String,
		creator: String?,
		preferredURL: URL,
		renderedArticleHTML: String? = nil,
		renderedArticleBaseURL: URL? = nil,
		highlightRichText: [NetNewsWireHighlightRichText] = []
	) {
		self.selectedText = selectedText
		self.title = title
		self.creator = creator
		self.preferredURL = preferredURL
		self.renderedArticleHTML = renderedArticleHTML
		self.renderedArticleBaseURL = renderedArticleBaseURL
		self.highlightRichText = highlightRichText
	}
}

@MainActor
public struct NetNewsWireMarkdownActions {
	public var shareMarkdown: (NetNewsWireMarkdownCapture) -> Void
	public var reportMarkdownFailure: () -> Void
	let isEnabled: Bool

	public init(
		shareMarkdown: @escaping (NetNewsWireMarkdownCapture) -> Void,
		reportMarkdownFailure: @escaping () -> Void = {}
	) {
		self.init(
			shareMarkdown: shareMarkdown,
			reportMarkdownFailure: reportMarkdownFailure,
			isEnabled: true
		)
	}

	private init(
		shareMarkdown: @escaping (NetNewsWireMarkdownCapture) -> Void,
		reportMarkdownFailure: @escaping () -> Void,
		isEnabled: Bool
	) {
		self.shareMarkdown = shareMarkdown
		self.reportMarkdownFailure = reportMarkdownFailure
		self.isEnabled = isEnabled
	}

	public static let disabled = NetNewsWireMarkdownActions(
		shareMarkdown: { _ in },
		reportMarkdownFailure: {},
		isEnabled: false
	)
}

struct NetNewsWireMarkdownMenuText {
	struct ActionTitles {
		let shareMarkdown: String
		let shareMarkdownArticle: String
	}

	static func accessibilityLabel(
		actionsEnabled: Bool,
		existingLabel: String?,
		localize: (String, String) -> String
	) -> String? {
		guard actionsEnabled else { return existingLabel }
		return localize("Markdown sharing", "Markdown sharing accessibility label")
	}

	static func actionTitles(localize: (String, String) -> String) -> ActionTitles {
		ActionTitles(
			shareMarkdown: localize("Share as Markdown...", "Command"),
			shareMarkdownArticle: localize("Share Full Article as Markdown...", "Command")
		)
	}
}

enum NetNewsWireMarkdownSharing {
	static func capture(
		base: NetNewsWireMarkdownCapture,
		renderedHighlights: [NetNewsWireHighlightRecord],
		resolvedPositions: [UUID: Int]
	) -> NetNewsWireMarkdownCapture {
		var capture = base
		capture.selectedText = ArticleHighlightMarkdown.quotation(
			records: renderedHighlights,
			resolvedOffsets: resolvedPositions
		)
		return capture
	}
}

@MainActor
enum NetNewsWireHighlightMarkdown {
	static func capture(
		articleKey: String,
		currentTitle: String,
		currentCreator: String?,
		currentPreferredURL: URL?,
		load: (String) async throws -> [NetNewsWireHighlightRecord],
		resolvedPositions: () async -> [UUID: Int],
		resolvedRichTextProvider: (() async -> [UUID: NetNewsWireHighlightRichText])? = nil,
		resolvedMarkdownSnapshotProvider: (() async -> ArticleHighlightMarkdownSnapshot?)? = nil
	) async -> NetNewsWireMarkdownCapture? {
		guard let records = try? await load(articleKey) else {
			return nil
		}
		let resolvedOffsets: [UUID: Int]
		let resolvedRichText: [UUID: NetNewsWireHighlightRichText]
		if let resolvedMarkdownSnapshotProvider {
			let snapshot = await resolvedMarkdownSnapshotProvider()
			resolvedOffsets = snapshot?.resolvedOffsets ?? [:]
			resolvedRichText = snapshot?.resolvedRichText ?? [:]
		} else {
			resolvedOffsets = await resolvedPositions()
			resolvedRichText = await resolvedRichTextProvider?() ?? [:]
		}
		guard let quotation = ArticleHighlightMarkdown.quotation(
			records: records,
			resolvedOffsets: resolvedOffsets
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
		return NetNewsWireMarkdownCapture(
			selectedText: quotation,
			title: title,
			creator: creator,
			preferredURL: preferredURL,
			highlightRichText: resolvedRichText.isEmpty
				? []
				: ArticleHighlightMarkdown.richText(
					records: records,
					resolvedOffsets: resolvedOffsets,
					resolvedRichText: resolvedRichText
				)
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
struct NetNewsWireHighlightMarkdownAction {
	private let articleKey: String
	private let webViewIdentifier: ObjectIdentifier

	init(articleKey: String, webViewController: AnyObject) {
		self.articleKey = articleKey
		self.webViewIdentifier = ObjectIdentifier(webViewController)
	}

	func perform(
		currentArticleKey: String?,
		currentWebViewController: AnyObject?,
		share: () async -> Void
	) async {
		guard currentArticleKey == articleKey,
			let currentWebViewController,
			ObjectIdentifier(currentWebViewController) == webViewIdentifier else {
			return
		}
		await share()
	}
}
