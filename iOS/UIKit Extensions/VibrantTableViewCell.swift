//
//  VibrantTableViewCell.swift
//  NetNewsWire-iOS
//
//  Created by Jim Correia on 9/2/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit

class VibrantTableViewCell: UITableViewCell {

	static let duration: TimeInterval = 0.6

	var labelColor: UIColor {
		if selectionStyle == .none {
			return NetNewsWireFeatureTheme.primaryText
		}
		return isHighlighted || isSelected ? NetNewsWireFeatureTheme.selectedText : NetNewsWireFeatureTheme.primaryText
	}

	var secondaryLabelColor: UIColor {
		if selectionStyle == .none {
			return NetNewsWireFeatureTheme.secondaryText
		}
		return isHighlighted || isSelected ? NetNewsWireFeatureTheme.selectedText : NetNewsWireFeatureTheme.secondaryText
	}

	override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
		super.init(style: style, reuseIdentifier: reuseIdentifier)
		commonInit()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		commonInit()
	}

	private func commonInit() {
		applyThemeProperties()
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(featureAppearanceDidChange),
			name: .netNewsWireFeatureAppearanceDidChange,
			object: nil
		)
	}

	override func setHighlighted(_ highlighted: Bool, animated: Bool) {
		super.setHighlighted(highlighted, animated: animated)
		updateVibrancy(animated: animated)
	}

	override func setSelected(_ selected: Bool, animated: Bool) {
		super.setSelected(selected, animated: animated)
		updateVibrancy(animated: animated)
	}

	/// Subclass overrides should call super
	func applyThemeProperties() {
		let selectedBackgroundView = UIView(frame: .zero)
		selectedBackgroundView.backgroundColor = NetNewsWireFeatureTheme.selectedBackground
		self.selectedBackgroundView = selectedBackgroundView
	}

	@objc private func featureAppearanceDidChange() {
		applyThemeProperties()
		updateVibrancy(animated: false)
	}

	/// Subclass overrides should call super
	func updateVibrancy(animated: Bool) {
		updateLabelVibrancy(textLabel, color: labelColor, animated: animated)
		updateLabelVibrancy(detailTextLabel, color: labelColor, animated: animated)
	}

	func updateLabelVibrancy(_ label: UILabel?, color: UIColor, animated: Bool) {
		guard let label = label else { return }
		if animated {
			UIView.transition(with: label, duration: Self.duration, options: .transitionCrossDissolve, animations: {
				label.textColor = color
			}, completion: nil)
		} else {
			label.textColor = color
		}
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

}

class VibrantBasicTableViewCell: VibrantTableViewCell {

	@IBOutlet private var label: UILabel!
	@IBOutlet private var detail: UILabel!
	@IBOutlet private var icon: UIImageView!

	@IBInspectable var imageNormal: UIImage?
	@IBInspectable var imageSelected: UIImage?

	var iconTint: UIColor {
		return isHighlighted || isSelected ? labelColor : NetNewsWireFeatureTheme.tint
	}

	var iconImage: UIImage? {
		return isHighlighted || isSelected ? imageSelected : imageNormal
	}

	override func updateVibrancy(animated: Bool) {
		super.updateVibrancy(animated: animated)
		updateIconVibrancy(icon, color: iconTint, image: iconImage, animated: animated)
		updateLabelVibrancy(label, color: labelColor, animated: animated)
		updateLabelVibrancy(detail, color: secondaryLabelColor, animated: animated)
	}

	private func updateIconVibrancy(_ icon: UIImageView?, color: UIColor, image: UIImage?, animated: Bool) {
		guard let icon = icon else { return }
		if animated {
			UIView.transition(with: icon, duration: Self.duration, options: .transitionCrossDissolve, animations: {
				icon.tintColor = color
				icon.image = image
			}, completion: nil)
		} else {
			icon.tintColor = color
			icon.image = image
		}
	}

}
