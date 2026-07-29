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

public enum NetNewsWirePublishingIntent: Equatable, Sendable {
	case capture
	case post
}

@MainActor
public struct NetNewsWirePublishingActions {
	public var send: (NetNewsWirePublishingCapture, NetNewsWirePublishingIntent) -> Void
	let isEnabled: Bool

	public init(send: @escaping (NetNewsWirePublishingCapture, NetNewsWirePublishingIntent) -> Void) {
		self.send = send
		self.isEnabled = true
	}

	private init(
		send: @escaping (NetNewsWirePublishingCapture, NetNewsWirePublishingIntent) -> Void,
		isEnabled: Bool
	) {
		self.send = send
		self.isEnabled = isEnabled
	}

	public static let disabled = NetNewsWirePublishingActions(send: { _, _ in }, isEnabled: false)
}

struct NetNewsWirePublishingMenuText {
	struct ActionTitles {
		let captureLink: String
		let postLink: String
		let captureSelection: String
		let postSelection: String
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
			postLink: localize("Post Link...", "Command"),
			captureSelection: localize("Capture Selection", "Command"),
			postSelection: localize("Post Selection...", "Command")
		)
	}
}
