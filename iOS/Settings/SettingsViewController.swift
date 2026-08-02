//
//  SettingsViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 4/24/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import CoreServices
import SafariServices
import SwiftUI
import UniformTypeIdentifiers
import RSCore
import Account
import ActivityLog

final class SettingsViewController: UITableViewController {

	private enum Section: Int {
		case notifications = 0
		case accounts = 1
		case feeds = 2
		case timeline = 3
		case articles = 4
		case appearance = 5
		case troubleshooting = 6
		case help = 7
	}

	private enum TroubleshootingRow: Int {
		case errorLog = 0
		case activityLog = 1
		case accountStats = 2
		case dinosaurs = 3
		case cloudKitZoneStats = 4
		case resetCloudKitFeeds = 5
	}

	private enum FeedsRow: Int {
		case importSubscriptions = 0
		case exportSubscriptions = 1
		case addNetNewsWireNewsFeed = 2
	}

	private enum TimelineRow: Int {
		case sortOrder = 0
		case groupByFeed = 1
		case refreshClearsReadArticles = 2
		case confirmMarkAllAsRead = 3
		case timelineLayout = 4
	}

	private enum ArticlesRow: Int, CaseIterable {
		case theme = 0
		case openLinksInNetNewsWire = 1
		case enableJavaScript = 2
		case enableFullScreenArticles = 3
	}

	private enum HelpRow: Int {
		case help = 0
		case forum = 1
		case releaseNotes = 2
		case bugTracker = 3
		case about = 4
	}

	private var opmlImportAccount: Account?
	private var opmlImportInProgress = false
	private var cloudKitResetInProgress = false

	@IBOutlet var timelineSortOrderSwitch: UISwitch!
	@IBOutlet var groupByFeedSwitch: UISwitch!
	@IBOutlet var refreshClearsReadArticlesSwitch: UISwitch!
	@IBOutlet var articleThemeDetailLabel: UILabel!
	@IBOutlet var confirmMarkAllAsReadSwitch: UISwitch!
	@IBOutlet var showFullscreenArticlesSwitch: UISwitch!
	@IBOutlet var colorPaletteDetailLabel: UILabel!
	@IBOutlet var openLinksInNetNewsWire: UISwitch!
	@IBOutlet var enableJavaScriptSwitch: UISwitch!

	var scrollToArticlesSection = false
	weak var presentingParentController: UIViewController?
	private var notificationsAreAvailable: Bool {
		appDelegate.capabilities.mayPresentUserNotifications
	}

	private var usesHostAppearance: Bool {
		NetNewsWireFeatureTheme.appearance != nil
	}

	override func viewDidLoad() {
		// This hack mostly works around a bug in static tables with dynamic type.  See: https://spin.atomicobject.com/2018/10/15/dynamic-type-static-uitableview/
		NotificationCenter.default.removeObserver(tableView!, name: UIContentSizeCategory.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(contentSizeCategoryDidChange), name: UIContentSizeCategory.didChangeNotification, object: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange), name: .UserDidAddAccount, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange), name: .UserDidDeleteAccount, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange), name: .AccountRefreshDidBegin, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange), name: .AccountRefreshDidFinish, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange), name: .CloudKitAccountMutationStateDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayNameDidChange), name: .DisplayNameDidChange, object: nil)

		tableView.register(UINib(nibName: "SettingsComboTableViewCell", bundle: .netNewsWire), forCellReuseIdentifier: "SettingsComboTableViewCell")
		tableView.register(UINib(nibName: "SettingsTableViewCell", bundle: .netNewsWire), forCellReuseIdentifier: "SettingsTableViewCell")

		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 44
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		if AppDefaults.shared.timelineSortDirection == .orderedAscending {
			timelineSortOrderSwitch.isOn = true
		} else {
			timelineSortOrderSwitch.isOn = false
		}

		if AppDefaults.shared.timelineGroupByFeed {
			groupByFeedSwitch.isOn = true
		} else {
			groupByFeedSwitch.isOn = false
		}

		if AppDefaults.shared.refreshClearsReadArticles {
			refreshClearsReadArticlesSwitch.isOn = true
		} else {
			refreshClearsReadArticlesSwitch.isOn = false
		}

		articleThemeDetailLabel.text = ArticleThemesManager.shared.currentTheme.name

		if AppDefaults.shared.confirmMarkAllAsRead {
			confirmMarkAllAsReadSwitch.isOn = true
		} else {
			confirmMarkAllAsReadSwitch.isOn = false
		}

		if AppDefaults.shared.articleFullscreenAvailable {
			showFullscreenArticlesSwitch.isOn = true
		} else {
			showFullscreenArticlesSwitch.isOn = false
		}

		if AppDefaults.shared.isArticleContentJavascriptEnabled {
			enableJavaScriptSwitch.isOn = true
		} else {
			enableJavaScriptSwitch.isOn = false
		}

		colorPaletteDetailLabel.text = String(describing: AppDefaults.userInterfaceColorPalette)

		openLinksInNetNewsWire.isOn = !AppDefaults.shared.useSystemBrowser

		let buildLabel = NonIntrinsicLabel(frame: CGRect(x: 32.0, y: 0.0, width: 0.0, height: 0.0))
		buildLabel.font = UIFont.systemFont(ofSize: 11.0)
		buildLabel.textColor = NetNewsWireFeatureTheme.secondaryText
		buildLabel.text = "\(Bundle.main.appName) \(Bundle.main.versionNumber) (Build \(Bundle.main.buildNumber))"
		buildLabel.sizeToFit()
		buildLabel.translatesAutoresizingMaskIntoConstraints = false

		let wrapperView = UIView(frame: CGRect(x: 0, y: 0, width: buildLabel.frame.width, height: buildLabel.frame.height + 10.0))
		wrapperView.translatesAutoresizingMaskIntoConstraints = false
		wrapperView.addSubview(buildLabel)
		tableView.tableFooterView = wrapperView

	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		self.tableView.selectRow(at: nil, animated: true, scrollPosition: .none)

		if scrollToArticlesSection {
			tableView.scrollToRow(at: IndexPath(row: 0, section: Section.articles.rawValue), at: .top, animated: true)
			scrollToArticlesSection = false
		}

	}

	// MARK: UITableView

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {

		switch Section(rawValue: section) {
		case .notifications:
			return notificationsAreAvailable ? super.tableView(tableView, numberOfRowsInSection: section) : 0
		case .accounts:
			return AccountManager.shared.accounts.count + 1
		case .feeds:
			let defaultNumberOfRows = super.tableView(tableView, numberOfRowsInSection: section)
			if AccountManager.shared.activeAccounts.isEmpty || AccountManager.shared.anyAccountHasNetNewsWireNewsSubscription() {
				return defaultNumberOfRows - 1
			}
			return defaultNumberOfRows
		case .articles:
			// McReader owns the only article appearance in contained mode.
			let rowCount = traitCollection.userInterfaceIdiom == .phone
				? ArticlesRow.allCases.count
				: ArticlesRow.allCases.count - 1
			return usesHostAppearance ? rowCount - 1 : rowCount
		case .appearance:
			return usesHostAppearance
				? 0
				: super.tableView(tableView, numberOfRowsInSection: section)
		case .troubleshooting:
			let defaultNumberOfRows = super.tableView(tableView, numberOfRowsInSection: section)
			if !shouldShowCloudKitResetRow {
				return defaultNumberOfRows - (AccountManager.shared.hasiCloudAccount ? 1 : 2)
			}
			if !AccountManager.shared.hasiCloudAccount {
				return defaultNumberOfRows - 1
			}
			return defaultNumberOfRows
		default:
			return super.tableView(tableView, numberOfRowsInSection: section)
		}
	}

	override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
		guard !(usesHostAppearance && Section(rawValue: section) == .appearance) else {
			return nil
		}
		return super.tableView(tableView, titleForHeaderInSection: section)
	}

	override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
		guard !(usesHostAppearance && Section(rawValue: section) == .appearance) else {
			return .leastNormalMagnitude
		}
		return super.tableView(tableView, heightForHeaderInSection: section)
	}

	override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
		guard !(usesHostAppearance && Section(rawValue: section) == .appearance) else {
			return .leastNormalMagnitude
		}
		return super.tableView(tableView, heightForFooterInSection: section)
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {

		let cell: UITableViewCell
		switch Section(rawValue: indexPath.section) {
		case .accounts:

			let sortedAccounts = AccountManager.shared.sortedAccounts
			if indexPath.row == sortedAccounts.count {
				cell = tableView.dequeueReusableCell(withIdentifier: "SettingsTableViewCell", for: indexPath)
				cell.textLabel?.text = NNWLocalizedString("Add Account", comment: "Add Account")
			} else {
				let acctCell = tableView.dequeueReusableCell(withIdentifier: "SettingsComboTableViewCell", for: indexPath) as! SettingsComboTableViewCell
				acctCell.applyThemeProperties()
				let account = sortedAccounts[indexPath.row]
				acctCell.comboImage?.image = Assets.accountImage(account.type)
				acctCell.comboNameLabel?.text = account.nameForDisplay
				cell = acctCell
			}
		case .articles where usesHostAppearance:
			cell = super.tableView(
				tableView,
				cellForRowAt: IndexPath(row: indexPath.row + 1, section: indexPath.section)
			)
		case .troubleshooting where shouldRemapCloudKitResetRow(indexPath):
			cell = super.tableView(tableView, cellForRowAt: IndexPath(
				row: TroubleshootingRow.resetCloudKitFeeds.rawValue,
				section: indexPath.section
			))
			configureCloudKitResetCell(cell)
		case .troubleshooting where indexPath.row == TroubleshootingRow.resetCloudKitFeeds.rawValue:
			cell = super.tableView(tableView, cellForRowAt: indexPath)
			configureCloudKitResetCell(cell)
		default:
			cell = super.tableView(tableView, cellForRowAt: indexPath)

		}

		return cell
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {

		switch Section(rawValue: indexPath.section) {
		case .notifications:
			guard notificationsAreAvailable else {
				return
			}
			UIApplication.shared.open(URL(string: "\(UIApplication.openSettingsURLString)")!)
			tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
		case .accounts:
			let sortedAccounts = AccountManager.shared.sortedAccounts
			if indexPath.row == sortedAccounts.count {
				let controller = UIStoryboard.settings.instantiateController(ofType: AddAccountViewController.self)
				self.navigationController?.pushViewController(controller, animated: true)
			} else {
				let controller = UIStoryboard.inspector.instantiateController(ofType: AccountInspectorViewController.self)
				controller.account = sortedAccounts[indexPath.row]
				self.navigationController?.pushViewController(controller, animated: true)
			}
		case .feeds:
			switch FeedsRow(rawValue: indexPath.row) {
			case .importSubscriptions:
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
				if let sourceView = tableView.cellForRow(at: indexPath) {
					let sourceRect = tableView.rectForRow(at: indexPath)
					importOPML(sourceView: sourceView, sourceRect: sourceRect)
				}
			case .exportSubscriptions:
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
				if let sourceView = tableView.cellForRow(at: indexPath) {
					let sourceRect = tableView.rectForRow(at: indexPath)
					exportOPML(sourceView: sourceView, sourceRect: sourceRect)
				}
			case .addNetNewsWireNewsFeed:
				addFeed()
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			default:
				break
			}
		case .timeline:
			switch TimelineRow(rawValue: indexPath.row) {
			case .timelineLayout:
				let timeline = UIStoryboard.settings.instantiateController(ofType: TimelineCustomizerCollectionViewController.self)
				self.navigationController?.pushViewController(timeline, animated: true)
			default:
				break
			}
		case .articles:
			switch ArticlesRow(rawValue: indexPath.row + (usesHostAppearance ? 1 : 0)) {
			case .theme:
				let articleThemes = UIStoryboard.settings.instantiateController(ofType: ArticleThemesTableViewController.self)
				self.navigationController?.pushViewController(articleThemes, animated: true)
			default:
				break
			}
		case .appearance:
			let colorPalette = UIStoryboard.settings.instantiateController(ofType: ColorPaletteTableViewController.self)
			self.navigationController?.pushViewController(colorPalette, animated: true)
		case .troubleshooting:
			let viewController: UIViewController? = {
				let row = shouldRemapCloudKitResetRow(indexPath) ? TroubleshootingRow.resetCloudKitFeeds : TroubleshootingRow(rawValue: indexPath.row)
				switch row {
				case .errorLog:
					return UIHostingController(rootView: ErrorLogView())
				case .accountStats:
					return UIHostingController(rootView: AccountStatsView())
				case .cloudKitZoneStats:
					return UIHostingController(rootView: CloudKitStatsView())
				case .activityLog:
					return UIHostingController(rootView: ActivityLogView())
				case .dinosaurs:
					return UIHostingController(rootView: DinosaursView(dismissAndPresent: { [weak self] dinosaur in
						guard let self else {
							return
						}
						self.dismiss(animated: true) {
							if let rootSplit = self.presentingParentController as? RootSplitViewController {
								rootSplit.coordinator.discloseFeed(dinosaur.feed, animations: [.scroll, .navigation])
							}
						}
					}))
				case .resetCloudKitFeeds:
					confirmCloudKitReset()
					return nil
				default:
					return nil
				}
			}()
			if let viewController {
				self.navigationController?.pushViewController(viewController, animated: true)
			}
		case .help:
			switch HelpRow(rawValue: indexPath.row) {
			case .help:
				openURL(HelpURL.helpHome.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .forum:
				openURL(HelpURL.discourse.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .releaseNotes:
				openURL(HelpURL.releaseNotes.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .bugTracker:
				openURL(HelpURL.bugTracker.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .about:
				let hosting = UIHostingController(rootView: AboutView())
				self.navigationController?.pushViewController(hosting, animated: true)
			default:
				break
			}
		default:
			tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
		}
	}

	override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
		return false
	}

	override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
		return false
	}

	override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
		return .none
	}

	override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
		return UITableView.automaticDimension
	}

	override func tableView(_ tableView: UITableView, indentationLevelForRowAt indexPath: IndexPath) -> Int {
		return super.tableView(tableView, indentationLevelForRowAt: IndexPath(row: 0, section: Section.accounts.rawValue))
	}

	// MARK: Actions

	@IBAction func done(_ sender: Any) {
		guard Self.settingsDismissalIsAllowed(opmlImportInProgress: opmlImportInProgress) else {
			return
		}
		dismiss(animated: true)
	}

	@IBAction func switchTimelineOrder(_ sender: Any) {
		if timelineSortOrderSwitch.isOn {
			AppDefaults.shared.timelineSortDirection = .orderedAscending
		} else {
			AppDefaults.shared.timelineSortDirection = .orderedDescending
		}
	}

	@IBAction func switchGroupByFeed(_ sender: Any) {
		if groupByFeedSwitch.isOn {
			AppDefaults.shared.timelineGroupByFeed = true
		} else {
			AppDefaults.shared.timelineGroupByFeed = false
		}
	}

	@IBAction func switchClearsReadArticles(_ sender: Any) {
		if refreshClearsReadArticlesSwitch.isOn {
			AppDefaults.shared.refreshClearsReadArticles = true
		} else {
			AppDefaults.shared.refreshClearsReadArticles = false
		}
	}

	@IBAction func switchConfirmMarkAllAsRead(_ sender: Any) {
		if confirmMarkAllAsReadSwitch.isOn {
			AppDefaults.shared.confirmMarkAllAsRead = true
		} else {
			AppDefaults.shared.confirmMarkAllAsRead = false
		}
	}

	@IBAction func switchFullscreenArticles(_ sender: Any) {
		if showFullscreenArticlesSwitch.isOn {
			AppDefaults.shared.articleFullscreenAvailable = true
		} else {
			AppDefaults.shared.articleFullscreenAvailable = false
		}
	}

	@IBAction func switchBrowserPreference(_ sender: Any) {
		if openLinksInNetNewsWire.isOn {
			AppDefaults.shared.useSystemBrowser = false
		} else {
			AppDefaults.shared.useSystemBrowser = true
		}
	}

	@IBAction func switchJavaScriptPreference(_ sender: Any) {
		AppDefaults.shared.isArticleContentJavascriptEnabled = enableJavaScriptSwitch.isOn
 	}

	// MARK: - Notifications

	@objc func contentSizeCategoryDidChange() {
		tableView.reloadData()
	}

	@objc func accountsDidChange() {
		tableView.reloadData()
	}

	@objc func displayNameDidChange() {
		tableView.reloadData()
	}

	@objc func browserPreferenceDidChange() {
		tableView.reloadData()
	}

}

// MARK: - OPML Document Picker

extension SettingsViewController: UIDocumentPickerDelegate {

	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard let account = opmlImportAccount, let url = urls.first else {
			return
		}
		opmlImportAccount = nil
		controller.dismiss(animated: true) { [weak self] in
			self?.importOPML(url, into: account)
		}
	}

	func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
		opmlImportAccount = nil
	}

	static func opmlImportFailureMessage(_ error: Error) -> String {
		if let partialFailure = error as? OPMLImportPartialFailure {
			let failureMessage = cloudKitAccountUserVisibleError(partialFailure.underlyingError).localizedDescription
			return "\(importResultMessage(partialFailure.result))\n\n\(failureMessage)"
		}
		return cloudKitAccountUserVisibleError(error).localizedDescription
	}

	static func importResultMessage(_ result: OPMLImportResult) -> String {
		let format = NNWLocalizedString(
			"Folders added: %lld\nAdded: %lld\nUpdated: %lld\nUnchanged: %lld\nRepositioned: %lld\nRejected: %lld",
			comment: "OPML import result counts"
		)
		var message = String(
			format: format,
			result.foldersAdded,
			result.added,
			result.updated,
			result.unchanged,
			result.repositioned,
			result.rejected
		)
		if result.committedButNotApplied {
			let savedMessage = NNWLocalizedString(
				"The records were saved to iCloud but have not appeared on this device yet. Refresh once to apply them.",
				comment: "OPML import was committed but has not converged locally"
			)
			message += "\n\n\(savedMessage)"
		}
		return message
	}

	static func shouldShowCloudKitResetRow(
		hasAccount: Bool,
		resetPhase: CloudKitAccountResetPhase,
		resetIsAvailable: Bool
	) -> Bool {
		resetIsAvailable && (hasAccount || resetPhase != .idle)
	}

	static func cloudKitResetRowIsEnabled(
		hasAccount: Bool,
		resetPhase: CloudKitAccountResetPhase,
		isBusy: Bool,
		resetIsAvailable: Bool
	) -> Bool {
		shouldShowCloudKitResetRow(
			hasAccount: hasAccount,
			resetPhase: resetPhase,
			resetIsAvailable: resetIsAvailable
		) && !isBusy
	}

	static func cloudKitResetWarningMessage() -> String {
		NNWLocalizedString(
			"This deletes all iCloud feed subscriptions, folders, synchronized articles, and read/starred state from every device. Close McReader build 157 or older on every device before resetting, and do not reopen it because an old build may restore deleted data.",
			comment: "First iCloud feed reset confirmation warning"
		)
	}

	static func opmlImportProgressMessage() -> String {
		NNWLocalizedString(
			"Keep McReader/Feeds open until the import finishes.",
			comment: "OPML import progress message"
		)
	}

	static func cloudKitResetProgressMessage() -> String {
		NNWLocalizedString(
			"This may take a few minutes. Keep McReader/Feeds open.",
			comment: "iCloud feed reset progress message"
		)
	}

	static func settingsDismissalIsAllowed(opmlImportInProgress: Bool) -> Bool {
		!opmlImportInProgress
	}

	static func activeResultPresenter(
		settings: UIViewController,
		root: UIViewController?,
		settingsIsVisible: Bool
	) -> UIViewController? {
		settingsIsVisible ? settings : root
	}

	static func cloudKitResetFinalConfirmationMessage(accountName: String) -> String {
		let format = NNWLocalizedString(
			"Permanently delete all synchronized data for the “%@” account? This cannot be undone.",
			comment: "Final iCloud feed reset confirmation naming the account"
		)
		return String(format: format, accountName)
	}

}

// MARK: - Private

private extension SettingsViewController {

	var shouldShowCloudKitResetRow: Bool {
		AccountManager.shared.cloudKitResetIsAvailable &&
			(AccountManager.shared.hasiCloudAccount || AccountManager.shared.cloudKitResetCanRun || cloudKitResetInProgress)
	}

	func shouldRemapCloudKitResetRow(_ indexPath: IndexPath) -> Bool {
		indexPath.section == Section.troubleshooting.rawValue &&
			!AccountManager.shared.hasiCloudAccount &&
			indexPath.row == TroubleshootingRow.cloudKitZoneStats.rawValue
	}

	func configureCloudKitResetCell(_ cell: UITableViewCell) {
		let enabled = AccountManager.shared.cloudKitResetCanRun && !cloudKitResetInProgress
		cell.isUserInteractionEnabled = enabled
		cell.textLabel?.text = NNWLocalizedString("Reset iCloud Feed Data", comment: "Destructive iCloud feed reset settings row")
		cell.textLabel?.textColor = enabled ? NetNewsWireFeatureTheme.destructive : NetNewsWireFeatureTheme.secondaryText
		if cloudKitResetInProgress {
			let activityIndicator = UIActivityIndicatorView(style: .medium)
			activityIndicator.startAnimating()
			cell.accessoryView = activityIndicator
		} else {
			cell.accessoryView = nil
		}
	}

	func confirmCloudKitReset() {
		guard AccountManager.shared.cloudKitResetCanRun, !cloudKitResetInProgress else {
			tableView.reloadData()
			return
		}

		let alert = UIAlertController(
			title: NNWLocalizedString("Reset iCloud Feed Data?", comment: "First iCloud feed reset confirmation title"),
			message: Self.cloudKitResetWarningMessage(),
			preferredStyle: .alert
		)
		alert.addAction(UIAlertAction(title: NNWLocalizedString("Cancel", comment: "Cancel button"), style: .cancel))
		alert.addAction(UIAlertAction(title: NNWLocalizedString("Continue", comment: "Continue destructive reset button"), style: .destructive) { [weak self] _ in
			self?.confirmCloudKitResetFinally()
		})
		present(alert, animated: true)
	}

	func confirmCloudKitResetFinally() {
		guard AccountManager.shared.cloudKitResetCanRun, !cloudKitResetInProgress else {
			tableView.reloadData()
			return
		}

		let accountName = AccountManager.shared.iCloudAccount?.nameForDisplay ?? NNWLocalizedString("iCloud Feeds", comment: "iCloud feeds account fallback name")
		let alert = UIAlertController(
			title: NNWLocalizedString("Final Confirmation", comment: "Final iCloud feed reset confirmation title"),
			message: Self.cloudKitResetFinalConfirmationMessage(accountName: accountName),
			preferredStyle: .alert
		)
		alert.addAction(UIAlertAction(title: NNWLocalizedString("Cancel", comment: "Cancel button"), style: .cancel))
		alert.addAction(UIAlertAction(title: NNWLocalizedString("Reset iCloud Feed Data", comment: "Final destructive iCloud feed reset button"), style: .destructive) { [weak self] _ in
			self?.resetCloudKitFeeds()
		})
		present(alert, animated: true)
	}

	func resetCloudKitFeeds() {
		guard AccountManager.shared.cloudKitResetCanRun, !cloudKitResetInProgress else {
			tableView.reloadData()
			return
		}

		cloudKitResetInProgress = true
		tableView.reloadData()
		let progressAlert = UIAlertController(
			title: NNWLocalizedString("Resetting iCloud Feed Data…", comment: "iCloud feed reset progress title"),
			message: Self.cloudKitResetProgressMessage() + "\n\n",
			preferredStyle: .alert
		)
		let activityIndicator = UIActivityIndicatorView(style: .medium)
		activityIndicator.translatesAutoresizingMaskIntoConstraints = false
		activityIndicator.startAnimating()
		progressAlert.view.addSubview(activityIndicator)
		NSLayoutConstraint.activate([
			activityIndicator.centerXAnchor.constraint(equalTo: progressAlert.view.centerXAnchor),
			activityIndicator.bottomAnchor.constraint(equalTo: progressAlert.view.bottomAnchor, constant: -20)
		])
		present(progressAlert, animated: true)

		Task { @MainActor [weak self] in
			guard let self else {
				return
			}
			do {
				try await AccountManager.shared.resetCloudKitAccount()
				cloudKitResetInProgress = false
				tableView.reloadData()
				progressAlert.dismiss(animated: true) {
					self.activeResultPresenter()?.presentError(
						title: NNWLocalizedString("Reset Complete", comment: "iCloud feed reset success title"),
						message: NNWLocalizedString("Your iCloud feed data was reset. Use Import Subscriptions to add your feeds again.", comment: "iCloud feed reset success message")
					)
				}
			} catch {
				cloudKitResetInProgress = false
				tableView.reloadData()
				let retryMessage = NNWLocalizedString("You can retry this reset.", comment: "iCloud feed reset retry guidance")
				let message = "\(cloudKitAccountUserVisibleError(error).localizedDescription)\n\n\(retryMessage)"
				progressAlert.dismiss(animated: true) {
					self.activeResultPresenter()?.presentError(
						title: NNWLocalizedString("Reset Failed", comment: "iCloud feed reset failure title"),
						message: message
					)
				}
			}
		}
	}

	func addFeed() {
		self.dismiss(animated: true)

		let addNavViewController = UIStoryboard.add.instantiateViewController(withIdentifier: "AddFeedViewControllerNav") as! UINavigationController
		let addViewController = addNavViewController.topViewController as! AddFeedViewController
		addViewController.initialFeed = AccountManager.netNewsWireNewsURL
		addViewController.initialFeedName = NNWLocalizedString("NetNewsWire News", comment: "NetNewsWire News")
		addNavViewController.modalPresentationStyle = .formSheet
		addNavViewController.preferredContentSize = AddFeedViewController.preferredContentSizeForFormSheetDisplay

		presentingParentController?.present(addNavViewController, animated: true)
	}

	func importOPML(sourceView: UIView, sourceRect: CGRect) {
		opmlImportAccount = nil
		switch AccountManager.shared.activeAccounts.count {
		case 0:
			presentError(title: "Error", message: NNWLocalizedString("You must have at least one active account.", comment: "Missing active account"))
		case 1:
			opmlImportAccount = AccountManager.shared.activeAccounts.first
			importOPMLDocumentPicker()
		default:
			importOPMLAccountPicker(sourceView: sourceView, sourceRect: sourceRect)
		}
	}

	func importOPMLAccountPicker(sourceView: UIView, sourceRect: CGRect) {
		let title = NNWLocalizedString("Choose an account to receive the imported feeds and folders", comment: "Import Account")
		let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)

		if let popoverController = alert.popoverPresentationController {
			popoverController.sourceView = view
			popoverController.sourceRect = sourceRect
		}

		for account in AccountManager.shared.sortedActiveAccounts {
			let action = UIAlertAction(title: account.nameForDisplay, style: .default) { [weak self] _ in
				self?.opmlImportAccount = account
				self?.importOPMLDocumentPicker()
			}
			alert.addAction(action)
		}

		let cancelTitle = NNWLocalizedString("Cancel", comment: "Cancel button")
		alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { [weak self] _ in
			self?.opmlImportAccount = nil
		})

		self.present(alert, animated: true)
	}

	func importOPMLDocumentPicker() {
		var contentTypes: [UTType] = []

		// Create UTType for .opml files by extension, without requiring conformance.
		// This ensures files ending in .opml can be selected no matter how OPML is registered.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4858>
		if let opmlByExtension = UTType(filenameExtension: "opml") {
			contentTypes.append(opmlByExtension)
		}

		// Also try the registered org.opml.opml UTI if it exists
		if let registeredOPML = UTType("org.opml.opml") {
			contentTypes.append(registeredOPML)
		}

		// Include XML as a fallback
		contentTypes.append(.xml)

		let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
		documentPicker.delegate = self
		documentPicker.modalPresentationStyle = .formSheet
		self.present(documentPicker, animated: true)
	}

	func importOPML(_ url: URL, into account: Account) {
		opmlImportInProgress = true
		setOPMLImportPresentationLocked(true)
		let progressAlert = UIAlertController(
			title: NNWLocalizedString("Importing Subscriptions…", comment: "OPML import progress title"),
			message: Self.opmlImportProgressMessage() + "\n\n",
			preferredStyle: .alert
		)
		let activityIndicator = UIActivityIndicatorView(style: .medium)
		activityIndicator.translatesAutoresizingMaskIntoConstraints = false
		activityIndicator.startAnimating()
		progressAlert.view.addSubview(activityIndicator)
		NSLayoutConstraint.activate([
			activityIndicator.centerXAnchor.constraint(equalTo: progressAlert.view.centerXAnchor),
			activityIndicator.bottomAnchor.constraint(equalTo: progressAlert.view.bottomAnchor, constant: -20)
		])

		present(progressAlert, animated: true) {
			account.importOPML(url) { result in
				self.finishOPMLImport(result, progressAlert: progressAlert)
			}
		}
	}

	func finishOPMLImport(_ result: Result<OPMLImportResult, Error>, progressAlert: UIAlertController) {
		let title: String
		let message: String
		switch result {
		case .success(let importResult):
			title = NNWLocalizedString("Import Complete", comment: "OPML import success title")
			message = Self.importResultMessage(importResult)
		case .failure(let error):
			title = NNWLocalizedString("Import Failed", comment: "Import Failed")
			message = Self.opmlImportFailureMessage(error)
		}

		progressAlert.dismiss(animated: true) {
			guard let presenter = self.activeResultPresenter() else {
				self.opmlImportInProgress = false
				self.setOPMLImportPresentationLocked(false)
				return
			}
			presenter.presentError(title: title, message: message) { [weak self] in
				self?.opmlImportInProgress = false
				self?.setOPMLImportPresentationLocked(false)
			}
		}
	}

	func setOPMLImportPresentationLocked(_ locked: Bool) {
		isModalInPresentation = locked
		navigationController?.isModalInPresentation = locked
	}

	func activeResultPresenter() -> UIViewController? {
		Self.activeResultPresenter(
			settings: self,
			root: presentingParentController,
			settingsIsVisible: viewIfLoaded?.window != nil
		)
	}

	func exportOPML(sourceView: UIView, sourceRect: CGRect) {
		if let account = AccountManager.shared.accounts.first, AccountManager.shared.accounts.count == 1 {
			exportOPMLDocumentPicker(account: account)
		} else {
			exportOPMLAccountPicker(sourceView: sourceView, sourceRect: sourceRect)
		}
	}

	func exportOPMLAccountPicker(sourceView: UIView, sourceRect: CGRect) {
		let title = NNWLocalizedString("Choose an account with the subscriptions to export", comment: "Export Account")
		let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)

		if let popoverController = alert.popoverPresentationController {
			popoverController.sourceView = view
			popoverController.sourceRect = sourceRect
		}

		for account in AccountManager.shared.sortedAccounts {
			let action = UIAlertAction(title: account.nameForDisplay, style: .default) { [weak self] _ in
				self?.exportOPMLDocumentPicker(account: account)
			}
			alert.addAction(action)
		}

		let cancelTitle = NNWLocalizedString("Cancel", comment: "Cancel button")
		alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel))

		self.present(alert, animated: true)
	}

	func exportOPMLDocumentPicker(account: Account) {
		let accountName = account.nameForDisplay.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespaces)
		let filename = "Subscriptions-\(accountName).opml"
		let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
		do {
			try account.logActivity(kind: .exportOPML, detail: filename) {
				let opmlString = OPMLExporter.OPMLString(with: account, title: filename)
				try opmlString.write(to: tempFile, atomically: true, encoding: String.Encoding.utf8)
			}
		} catch {
			self.presentError(title: "OPML Export Error", message: error.localizedDescription)
		}

		let docPicker = UIDocumentPickerViewController(forExporting: [tempFile])
		docPicker.modalPresentationStyle = .formSheet
		self.present(docPicker, animated: true)
	}

	func openURL(_ urlString: String) {
		guard let url = URL(string: urlString) else {
			return
		}

		// Open GitHub links in the GitHub app when installed.
		if let host = url.host, host == "github.com" || host.hasSuffix(".github.com") {
			UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { [weak self] openedInApp in
				if !openedInApp {
					self?.presentSafariViewController(for: url)
				}
			}
			return
		}

		presentSafariViewController(for: url)
	}

	private func presentSafariViewController(for url: URL) {
		let vc = SFSafariViewController(url: url)
		vc.modalPresentationStyle = .pageSheet
		present(vc, animated: true)
	}
}
