//
//  VibrantButton.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 10/22/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit

final class VibrantButton: UIButton {

	@IBInspectable var backgroundHighlightColor: UIColor = NetNewsWireFeatureTheme.selectedBackground

	override init(frame: CGRect) {
		super.init(frame: frame)
		commonInit()
	}
	required init?(coder: NSCoder) {
		super.init(coder: coder)
		commonInit()
	}

	private func commonInit() {
		applyFeatureAppearance()
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(featureAppearanceDidChange),
			name: .netNewsWireFeatureAppearanceDidChange,
			object: nil
		)
	}

	@objc private func featureAppearanceDidChange() {
		applyFeatureAppearance()
	}

	private func applyFeatureAppearance() {
		backgroundHighlightColor = NetNewsWireFeatureTheme.selectedBackground
		setTitleColor(NetNewsWireFeatureTheme.selectedText, for: .highlighted)
		let disabledColor = NetNewsWireFeatureTheme.secondaryTint.withAlphaComponent(0.5)
		setTitleColor(disabledColor, for: .disabled)
		if isHighlighted {
			backgroundColor = backgroundHighlightColor
		}
	}

	override var isHighlighted: Bool {
		didSet {
			backgroundColor = isHighlighted ? backgroundHighlightColor : nil
		}
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        isHighlighted = true
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        isHighlighted = false
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        isHighlighted = false
        super.touchesCancelled(touches, with: event)
    }

}
