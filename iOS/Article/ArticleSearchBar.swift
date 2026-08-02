//
//  ArticleSearchBar.swift
//  NetNewsWire
//
//  Created by Brian Sanders on 5/8/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import UIKit
import RSCore

@objc @MainActor protocol SearchBarDelegate: NSObjectProtocol {
	@objc optional func nextWasPressed(_ searchBar: ArticleSearchBar)
	@objc optional func previousWasPressed(_ searchBar: ArticleSearchBar)
	@objc optional func doneWasPressed(_ searchBar: ArticleSearchBar)
	@objc optional func searchBar(_ searchBar: ArticleSearchBar, textDidChange: String)
}

@IBDesignable final class ArticleSearchBar: UIStackView {
	var searchField: UISearchTextField!
	var nextButton: UIButton!
	var prevButton: UIButton!
	var background: UIView!
	var shouldBeginEditing: Bool = true
	private var doneButton: UIButton!

	weak private var resultsLabel: UILabel!

	var resultsCount: UInt = 0 {
		didSet {
			updateUI()
		}
	}
	var selectedResult: UInt = 1 {
		didSet {
			updateUI()
		}
	}

	weak var delegate: SearchBarDelegate?

	override var keyCommands: [UIKeyCommand]? {
		return [UIKeyCommand(title: "Exit Find", action: #selector(donePressed(_:)), input: UIKeyCommand.inputEscape)]
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		commonInit()
	}

	required init(coder: NSCoder) {
		super.init(coder: coder)
		commonInit()
	}

	override func didMoveToSuperview() {
		super.didMoveToSuperview()
		applyFeatureAppearance()
		isOpaque = true
		NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)), name: UITextField.textDidChangeNotification, object: searchField)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(featureAppearanceDidChange),
			name: .netNewsWireFeatureAppearanceDidChange,
			object: nil
		)
	}

	private func updateUI() {
		if resultsCount > 0 {
			let format = NNWLocalizedString("%d of %d", comment: "Results selection and count")
			resultsLabel.text = String.localizedStringWithFormat(format, selectedResult, resultsCount)
		} else {
			resultsLabel.text = NNWLocalizedString("No results", comment: "No results")
		}

		nextButton.isEnabled = selectedResult < resultsCount
		prevButton.isEnabled = resultsCount > 0 && selectedResult > 1
	}

	@discardableResult override func becomeFirstResponder() -> Bool {
		searchField.becomeFirstResponder()
	}

	@discardableResult override func resignFirstResponder() -> Bool {
		searchField.resignFirstResponder()
	}

	override var isFirstResponder: Bool {
		searchField.isFirstResponder
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}
}

private extension ArticleSearchBar {
	func commonInit() {
		isLayoutMarginsRelativeArrangement = true
		alignment = .center
		spacing = 8
		layoutMargins.left = 8
		layoutMargins.right = 8

		background = UIView(frame: bounds)
		background.backgroundColor = NetNewsWireFeatureTheme.controlBackground
		background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		addSubview(background)

		let doneButton = UIButton()
		doneButton.setTitle(NNWLocalizedString("Done", comment: "Done"), for: .normal)
		doneButton.setTitleColor(NetNewsWireFeatureTheme.primaryText, for: .normal)
		doneButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
		doneButton.isAccessibilityElement = true
		doneButton.addTarget(self, action: #selector(donePressed), for: .touchUpInside)
		doneButton.isEnabled = true
		addArrangedSubview(doneButton)
		self.doneButton = doneButton

		let resultsLabel = UILabel()
		searchField = UISearchTextField()
		searchField.autocapitalizationType = .none
		searchField.autocorrectionType = .no
		searchField.returnKeyType = .search
		searchField.delegate = self

		resultsLabel.font = .systemFont(ofSize: UIFont.smallSystemFontSize)
		resultsLabel.textColor = NetNewsWireFeatureTheme.secondaryText
		resultsLabel.text = ""
		resultsLabel.textAlignment = .right
		resultsLabel.adjustsFontSizeToFitWidth = true
		searchField.rightView = resultsLabel
		searchField.rightViewMode = .always

		self.resultsLabel = resultsLabel
		addArrangedSubview(searchField)

		prevButton = UIButton(type: .system)
		prevButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
		prevButton.accessibilityLabel = "Previous Result"
		prevButton.isAccessibilityElement = true
		prevButton.addTarget(self, action: #selector(previousPressed), for: .touchUpInside)
		addArrangedSubview(prevButton)

		nextButton = UIButton(type: .system)
		nextButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
		nextButton.accessibilityLabel = "Next Result"
		nextButton.isAccessibilityElement = true
		nextButton.addTarget(self, action: #selector(nextPressed), for: .touchUpInside)
		addArrangedSubview(nextButton)
	}

	func applyFeatureAppearance() {
		guard NetNewsWireFeatureTheme.appearance != nil else {
			layer.backgroundColor = (
				UIColor(
					named: "barBackgroundColor",
					in: Bundle.netNewsWire,
					compatibleWith: traitCollection
				) ?? .systemBackground
			).cgColor
			background.backgroundColor = .systemGray5
			searchField.backgroundColor = nil
			searchField.textColor = .label
			resultsLabel.textColor = .secondaryLabel
			doneButton.setTitleColor(.label, for: .normal)
			tintColor = nil
			return
		}

		layer.backgroundColor = NetNewsWireFeatureTheme.secondaryBackground.cgColor
		background.backgroundColor = NetNewsWireFeatureTheme.controlBackground
		searchField.backgroundColor = NetNewsWireFeatureTheme.elevatedBackground
		searchField.textColor = NetNewsWireFeatureTheme.primaryText
		resultsLabel.textColor = NetNewsWireFeatureTheme.secondaryText
		doneButton.setTitleColor(NetNewsWireFeatureTheme.primaryText, for: .normal)
		tintColor = NetNewsWireFeatureTheme.tint
	}
}

private extension ArticleSearchBar {


	@objc func featureAppearanceDidChange() {
		applyFeatureAppearance()
	}
	@objc func textDidChange(_ notification: Notification) {
		delegate?.searchBar?(self, textDidChange: searchField.text ?? "")

		if searchField.text?.isEmpty ?? true {
			searchField.rightViewMode = .never
		} else {
			searchField.rightViewMode = .always
		}
	}

	@objc func nextPressed() {
		delegate?.nextWasPressed?(self)
	}

	@objc func previousPressed() {
		delegate?.previousWasPressed?(self)
	}

	@objc func donePressed(_ _: Any? = nil) {
		delegate?.doneWasPressed?(self)
	}
}

extension ArticleSearchBar: UITextFieldDelegate {
	func textFieldShouldReturn(_ textField: UITextField) -> Bool {
		delegate?.nextWasPressed?(self)
		return false
	}

	func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
		return shouldBeginEditing
	}
}
