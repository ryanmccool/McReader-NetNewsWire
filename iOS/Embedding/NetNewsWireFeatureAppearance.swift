import UIKit

/// An immutable color value used at the NetNewsWire embedding boundary.
public struct NetNewsWireFeatureColor: Equatable, Sendable {
	public let red: Double
	public let green: Double
	public let blue: Double
	public let alpha: Double

	public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}

	@MainActor var uiColor: UIColor {
		UIColor(red: red, green: green, blue: blue, alpha: alpha)
	}

	var cssValue: String {
		let red = Int((self.red * 255).rounded())
		let green = Int((self.green * 255).rounded())
		let blue = Int((self.blue * 255).rounded())
		return "rgba(\(red), \(green), \(blue), \(alpha))"
	}

	private var relativeLuminance: Double {
		func linearized(_ component: Double) -> Double {
			component <= 0.04045
				? component / 12.92
				: pow((component + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
	}

	func contrastRatio(with other: Self) -> Double {
		let lighter = max(relativeLuminance, other.relativeLuminance)
		let darker = min(relativeLuminance, other.relativeLuminance)
		return (lighter + 0.05) / (darker + 0.05)
	}
}

/// Optional semantic appearance supplied by an app embedding NetNewsWire.
/// Standalone NetNewsWire keeps its existing UIKit and asset colors when this is nil.
public struct NetNewsWireFeatureAppearance: Equatable, Sendable {
	public enum Style: Equatable, Sendable {
		case light
		case dark
	}

	public let style: Style
	public let background: NetNewsWireFeatureColor
	public let secondaryBackground: NetNewsWireFeatureColor
	public let elevatedBackground: NetNewsWireFeatureColor
	public let primaryText: NetNewsWireFeatureColor
	public let secondaryText: NetNewsWireFeatureColor
	public let tertiaryText: NetNewsWireFeatureColor
	public let tint: NetNewsWireFeatureColor
	public let secondaryTint: NetNewsWireFeatureColor
	public let tertiaryTint: NetNewsWireFeatureColor
	public let separator: NetNewsWireFeatureColor
	public let success: NetNewsWireFeatureColor
	public let warning: NetNewsWireFeatureColor
	public let destructive: NetNewsWireFeatureColor

	public init(
		style: Style,
		background: NetNewsWireFeatureColor,
		secondaryBackground: NetNewsWireFeatureColor,
		elevatedBackground: NetNewsWireFeatureColor,
		primaryText: NetNewsWireFeatureColor,
		secondaryText: NetNewsWireFeatureColor,
		tertiaryText: NetNewsWireFeatureColor,
		tint: NetNewsWireFeatureColor,
		secondaryTint: NetNewsWireFeatureColor,
		tertiaryTint: NetNewsWireFeatureColor,
		separator: NetNewsWireFeatureColor,
		success: NetNewsWireFeatureColor,
		warning: NetNewsWireFeatureColor,
		destructive: NetNewsWireFeatureColor
	) {
		self.style = style
		self.background = background
		self.secondaryBackground = secondaryBackground
		self.elevatedBackground = elevatedBackground
		self.primaryText = primaryText
		self.secondaryText = secondaryText
		self.tertiaryText = tertiaryText
		self.tint = tint
		self.secondaryTint = secondaryTint
		self.tertiaryTint = tertiaryTint
		self.separator = separator
		self.success = success
		self.warning = warning
		self.destructive = destructive
	}
}

extension Notification.Name {
	static let netNewsWireFeatureAppearanceDidChange = Notification.Name("NetNewsWireFeatureAppearanceDidChange")
}

/// NetNewsWire-owned resolver. The contained feature is process-scoped, matching its existing
/// account/defaults/article-theme singletons; every McReader scene supplies the same app theme.
@MainActor enum NetNewsWireFeatureTheme {
	private(set) static var appearance: NetNewsWireFeatureAppearance?

	static func update(_ newAppearance: NetNewsWireFeatureAppearance?) {
		guard newAppearance != appearance else { return }
		appearance = newAppearance
		NotificationCenter.default.post(name: .netNewsWireFeatureAppearanceDidChange, object: nil)
	}

	static var interfaceStyle: UIUserInterfaceStyle {
		switch appearance?.style {
		case .light: .light
		case .dark: .dark
		case nil: .unspecified
		}
	}

	static var background: UIColor { appearance?.background.uiColor ?? .systemBackground }
	static var secondaryBackground: UIColor { appearance?.secondaryBackground.uiColor ?? .secondarySystemBackground }
	static var groupedBackground: UIColor { appearance?.background.uiColor ?? .systemGroupedBackground }
	static var elevatedBackground: UIColor { appearance?.elevatedBackground.uiColor ?? .tertiarySystemBackground }
	static var primaryText: UIColor { appearance?.primaryText.uiColor ?? .label }
	static var secondaryText: UIColor { appearance?.secondaryText.uiColor ?? .secondaryLabel }
	static var tertiaryText: UIColor { appearance?.tertiaryText.uiColor ?? .tertiaryLabel }
	static var tint: UIColor { appearance?.tint.uiColor ?? Assets.Colors.primaryAccent }
	static var secondaryTint: UIColor { appearance?.secondaryTint.uiColor ?? Assets.Colors.secondaryAccent }
	static var tertiaryTint: UIColor { appearance?.tertiaryTint.uiColor ?? Assets.Colors.secondaryAccent }
	static var separator: UIColor { appearance?.separator.uiColor ?? .separator }
	static var success: UIColor { appearance?.success.uiColor ?? .systemGreen }
	static var warning: UIColor { appearance?.warning.uiColor ?? .systemOrange }
	static var destructive: UIColor { appearance?.destructive.uiColor ?? .systemRed }
	static var controlBackground: UIColor { appearance?.elevatedBackground.uiColor ?? Assets.Colors.controlBackground }
	static var iconBackground: UIColor { appearance?.elevatedBackground.uiColor ?? Assets.Colors.iconBackground }
	static var fullScreenBackground: UIColor { appearance?.background.uiColor ?? Assets.Colors.fullScreenBackground }
	static var selectedBackground: UIColor { appearance?.tint.uiColor ?? Assets.Colors.secondaryAccent }
	static var selectedText: UIColor {
		guard let appearance else { return Assets.Colors.vibrantText }
		let candidate = appearance.primaryText.contrastRatio(with: appearance.tint) >= appearance.background.contrastRatio(with: appearance.tint)
			? appearance.primaryText
			: appearance.background
		return candidate.uiColor
	}
	static var subtleFill: UIColor {
		guard let appearance else { return .tertiarySystemFill }
		return appearance.tint.uiColor.withAlphaComponent(0.14)
	}

	static var articleCSSOverride: String {
		guard let appearance else { return "" }
		let colorScheme = appearance.style == .dark ? "dark" : "light"
		let selectedText = appearance.primaryText.contrastRatio(with: appearance.tint)
			>= appearance.background.contrastRatio(with: appearance.tint)
			? appearance.primaryText
			: appearance.background
		return """

		/* Contained articles use NetNewsWire's default layout while McReader owns every
		   semantic color. Standalone NetNewsWire keeps its selected article theme. */
		:root {
			color-scheme: \(colorScheme);
			--nnw-feature-background: \(appearance.background.cssValue);
			--nnw-feature-surface: \(appearance.secondaryBackground.cssValue);
			--nnw-feature-elevated: \(appearance.elevatedBackground.cssValue);
			--nnw-feature-primary-text: \(appearance.primaryText.cssValue);
			--nnw-feature-secondary-text: \(appearance.secondaryText.cssValue);
			--nnw-feature-tertiary-text: \(appearance.tertiaryText.cssValue);
			--nnw-feature-tint: \(appearance.tint.cssValue);
			--nnw-feature-secondary-tint: \(appearance.secondaryTint.cssValue);
			--nnw-feature-separator: \(appearance.separator.cssValue);
			--nnw-feature-selected-text: \(selectedText.cssValue);
			--nnw-feature-warning: \(appearance.warning.cssValue);
			--header-table-border-color: var(--nnw-feature-separator);
			--header-color: var(--nnw-feature-secondary-text);
			--body-code-color: var(--nnw-feature-primary-text);
			--code-background-color: var(--nnw-feature-elevated);
			--system-message-color: var(--nnw-feature-tertiary-text);
			--feedlink-color: var(--nnw-feature-tint);
			--article-title-color: var(--nnw-feature-primary-text);
			--article-date-color: var(--nnw-feature-secondary-text);
			--table-cell-border-color: var(--nnw-feature-separator);
			--sup-link-color: var(--nnw-feature-tint);
			--primary-accent-color: var(--nnw-feature-tint);
			--secondary-accent-color: var(--nnw-feature-tint);
			--block-quote-border-color: var(--nnw-feature-tertiary-text);
			--ios-hover-color: var(--nnw-feature-surface);
			--nnw-saved-highlight-background: color-mix(
				in srgb,
				var(--nnw-feature-warning) 36%,
				transparent
			);
		}
		html, body {
			background-color: var(--nnw-feature-background) !important;
			color: var(--nnw-feature-primary-text) !important;
		}
		body a:link, body a:link * { color: var(--nnw-feature-tint) !important; }
		body a:visited, body a:visited * {
			color: var(--nnw-feature-secondary-tint) !important;
		}
		body code, body pre {
			color: var(--nnw-feature-primary-text) !important;
			background-color: var(--nnw-feature-elevated) !important;
		}
		body blockquote {
			color: var(--nnw-feature-secondary-text) !important;
			border-color: var(--nnw-feature-tertiary-text) !important;
			background-color: var(--nnw-feature-surface) !important;
		}
		body table :is(td, th) { border-color: var(--nnw-feature-separator) !important; }
		.newsfoot-footnote-popover {
			background: var(--nnw-feature-surface) !important;
			box-shadow: 0 2px 4px var(--nnw-feature-separator) !important;
			color: var(--nnw-feature-primary-text) !important;
		}
		.newsfoot-footnote-popover-arrow {
			background: var(--nnw-feature-elevated) !important;
			border-color: var(--nnw-feature-separator) !important;
		}
		.newsfoot-footnote-popover-inner {
			background: var(--nnw-feature-elevated) !important;
		}
		body a.footnote,
		.newsfoot-footnote-popover + a.footnote {
			background: var(--nnw-feature-secondary-tint) !important;
			color: var(--nnw-feature-selected-text) !important;
		}
		body a.footnote:hover,
		.newsfoot-footnote-popover + a.footnote:hover {
			background: var(--nnw-feature-tint) !important;
			color: var(--nnw-feature-selected-text) !important;
		}
		"""
	}
}
