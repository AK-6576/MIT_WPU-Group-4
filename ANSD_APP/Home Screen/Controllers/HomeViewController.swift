//
//  HomeViewController.swift
//  ANSD_APP
//
//  Created by MIT-WPU Group 4 on 15/02/26.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import TipKit
import UIKit
import UserNotifications
import Foundation
import FirebaseAuth

class HomeViewController: UIViewController {

    // MARK: - Outlets & Properties
    @IBOutlet weak var tableView: UITableView!

    var quickActions: [RoutineConversation] = []
    var recentHistory: [Conversation] = []

    private let profileButton = UIButton(type: .custom)

    // MARK: - TipKit
    // Tip instances (one per UI feature on the Home Screen)
    private let profileTip         = ProfileButtonTip()
    private let quickCaptionTip    = QuickCaptioningTip()
    private let quickActionsTip    = QuickActionsTip()
    private let newConvoTip        = NewConversationTip()
    private let joinConvoTip       = JoinConversationTip()
    private let viewConvosTip      = ViewConversationsTip()

    /// Flag: tips have been presented for this installation
    private static let tipsShownKey = "home_tips_shown_v1"

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupProfileButton()
        loadSavedProfileImage()
        configureTipKit()      // ← TipKit: configure once per install

        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.largeTitleDisplayMode = .never

        if let headerView = tableView.tableHeaderView as? GreetingViewCell {
            headerView.helloLabel.isHidden = false
        }

        navigationItem.title = ""
        navigationItem.hidesBackButton = true

        // RESTORED: Observers
        NotificationCenter.default.addObserver(self, selector: #selector(handleProfileImageUpdate(_:)), name: NSNotification.Name("ProfileImageUpdated"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleProfileNameUpdate(_:)), name: NSNotification.Name("ProfileNameUpdated"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDataUpdate), name: NSNotification.Name("ActionsUpdated"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDataUpdate), name: NSNotification.Name("ConversationHistoryUpdated"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(triggerWalkthrough), name: NSNotification.Name("ReplayHomeTips"), object: nil)
    }

    private var isTourCancelled = false

    @objc private func triggerWalkthrough() {
        presentHomeTipsIfNeeded(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Wait for notification authorization before potentially showing tips.
        // This ensures the tips don't appear in the background while the OS permission alert is up.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.presentHomeTipsIfNeeded()
            }
        }
    }

    @objc func handleDataUpdate() {
        print("HomeViewController: Received ConversationHistoryUpdated notification.")
        DispatchQueue.main.async { [weak self] in
            self?.loadData()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadData()
        loadSavedProfileImage()

        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.largeTitleDisplayMode = .never

        let name = UserDefaults.standard.string(forKey: "user_first_name") ?? "User"
        if let headerView = tableView.tableHeaderView as? GreetingViewCell {
            headerView.configure(name: name)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - RESTORED: Profile Handlers

    @objc func handleProfileNameUpdate(_ notification: Notification) {
        if let userInfo = notification.userInfo, let newName = userInfo["name"] as? String {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let headerView = self.tableView.tableHeaderView as? GreetingViewCell {
                    headerView.configure(name: newName)
                }
                UserDefaults.standard.set(newName, forKey: "user_first_name")
            }
        }
    }

    @objc func handleProfileImageUpdate(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            if let newImage = notification.object as? UIImage {
                self?.profileButton.setImage(newImage, for: .normal)
            }
        }
    }

    // MARK: - Queue Logic & Data Loading

    func loadData() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("HomeViewController: loadData() called on Main Thread. Fetching...")

            // 1. Quick Actions Queue: Fetched via Repository (Top 3 Upcoming)
            self.quickActions = QuickActionsRepository.shared.getUpcomingActions(limit: 3)

            // 2. Recent History Queue: Limit visible to TOP 2
            let allConversations = DataManager.shared.fetchConversations()
            self.recentHistory = Array(allConversations.prefix(2))

            self.tableView.reloadData()
        }
    }

    // Queue Deletion Logic
    private func performQueueDeletion(for section: Int, at indexPath: IndexPath) {
        if section == 0 {
            let item = quickActions[indexPath.row]
            QuickActionsRepository.shared.deleteAction(item)
        } else {
            let historyItem = recentHistory[indexPath.row]
            DataManager.shared.deleteConversation(historyItem)
        }

        loadData()

        DispatchQueue.main.async {
            self.tableView.reloadSections(IndexSet(integer: section), with: .automatic)
        }
    }

    // MARK: - Navigation Handlers

    @IBAction func didTapNewConversation(_ sender: UITapGestureRecognizer) { performSegue(withIdentifier: "showNewConversation", sender: self) }
    @IBAction func didTapJoinConversation(_ sender: UITapGestureRecognizer) { performSegue(withIdentifier: "showJoinConversation", sender: self) }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showProfile" {
            if let destVC = segue.destination as? ProfileTableViewController {
                destVC.incomingName = UserDefaults.standard.string(forKey: "user_first_name") ?? "User"
            }
        } else if segue.identifier == "viewConvoCell" {
            guard let destVC = segue.destination as? ChatHistoryViewController,
                  let selectedConvo = sender as? Conversation else { return }
            destVC.histconversationData = selectedConvo
        } else if segue.identifier == "showJoinConversation" {
            // Participant joining from a Quick Action cell
            if let selectedItem = sender as? RoutineConversation,
               let destVC = segue.destination as? SessionSelectionViewController {
                destVC.prefilledRoomCode = selectedItem.roomCode
            }
        } else {
            // Dashboard Quick Actions -> Chat (Direct Start for Host)
            let dashboardSegueIDs = ["office", "family", "friends"]
            if let segueID = segue.identifier, dashboardSegueIDs.contains(segueID) {
                if let selectedItem = sender as? RoutineConversation {
                    if let chatVC = segue.destination as? ActionJoinViewController {
                        chatVC.sessionTitle = "\(selectedItem.conversationTopic) Session" // Use topic as title
                        chatVC.category = selectedItem.categoryTitle
                        chatVC.roomCode = selectedItem.roomCode
                        chatVC.participantNames = selectedItem.participantNames ?? []
                        chatVC.hostUID = selectedItem.hostUID
                    }
                }
            }
        }
    }

    // MARK: - UI Support Methods

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        if #available(iOS 15.0, *) { tableView.sectionHeaderTopPadding = 0 }

        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 80
    }

    private func setupProfileButton() {
        let size: CGFloat = 36
        let containerView = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        profileButton.frame = containerView.bounds
        profileButton.setImage(UIImage(systemName: "person.crop.circle.fill"), for: .normal)
        profileButton.layer.cornerRadius = size / 2
        profileButton.clipsToBounds = true
        profileButton.addTarget(self, action: #selector(profileTapped), for: .touchUpInside)
        containerView.addSubview(profileButton)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: containerView)
    }

    @objc private func profileTapped() { performSegue(withIdentifier: "showProfile", sender: self) }

    private func loadSavedProfileImage() {
        if let data = UserDefaults.standard.data(forKey: "profileImage"), let image = UIImage(data: data) {
            profileButton.setImage(image, for: .normal)
        }
    }

    // MARK: - TipKit Configuration & Presentation

    /// Call once at app launch to configure the TipKit data store.
    private func configureTipKit() {
        do {
            // Use immediate display frequency so the back-to-back tour works.
            try Tips.configure([.displayFrequency(.immediate)])
        } catch {
            print("HomeTips: TipKit configuration failed — \(error)")
        }
    }

    /// Presents the ordered tip sequence only on the user's first session after account creation, or when replayed from Settings.
    private func presentHomeTipsIfNeeded(force: Bool = false) {
        if !force {
            // 1. If already shown and completed, never show again
            if UserDefaults.standard.bool(forKey: Self.tipsShownKey) {
                return
            }

            // 2. Only show if explicitly flagged as brand-new signup
            let isBrandNewSignup = UserDefaults.standard.bool(forKey: "is_brand_new_signup")
            guard isBrandNewSignup else {
                UserDefaults.standard.set(true, forKey: Self.tipsShownKey)
                return
            }
        }

        // Mark as completed immediately so it never runs automatically again
        UserDefaults.standard.set(true, forKey: Self.tipsShownKey)
        UserDefaults.standard.set(false, forKey: "is_brand_new_signup")
        isTourCancelled = false

        // Present tips as a sequenced walk-through
        Task { @MainActor in
            guard !isTourCancelled else { return }

            // Step 1: Profile
            if let barItem = navigationItem.rightBarButtonItem, let anchorView = barItem.customView {
                let continued = await presentTipStep(profileTip, source: anchorView, tint: .systemIndigo)
                if !continued || isTourCancelled { return }
            }

            try? await Task.sleep(for: .seconds(0.5))
            guard !isTourCancelled else { return }

            // Step 2: Quick Captioning
            if let headerView = tableView.tableHeaderView as? GreetingViewCell,
               let quickView = headerView.quickConvoView {
                let continued = await presentTipStep(quickCaptionTip, source: quickView, tint: .systemBlue, duration: 4.0)
                if !continued || isTourCancelled { return }
            }

            try? await Task.sleep(for: .seconds(0.5))
            guard !isTourCancelled else { return }

            // Step 3: New Conversation
            if let headerView = tableView.tableHeaderView as? GreetingViewCell,
               let newView = headerView.newConvoView {
                let continued = await presentTipStep(newConvoTip, source: newView, tint: .systemBlue)
                if !continued || isTourCancelled { return }
            }

            try? await Task.sleep(for: .seconds(0.5))
            guard !isTourCancelled else { return }

            // Step 4: Join Conversation
            if let headerView = tableView.tableHeaderView as? GreetingViewCell,
               let joinView = headerView.joinConvoView {
                let continued = await presentTipStep(joinConvoTip, source: joinView, tint: .systemIndigo)
                if !continued || isTourCancelled { return }
            }

            try? await Task.sleep(for: .seconds(0.5))
            guard !isTourCancelled else { return }

            // Step 5: Quick Actions
            let continuedQA = await presentTipStep(quickActionsTip, source: tableView, tint: .systemOrange, isHeader: true, section: 0)
            if !continuedQA || isTourCancelled { return }

            try? await Task.sleep(for: .seconds(0.5))
            guard !isTourCancelled else { return }

            // Step 6: History
            _ = await presentTipStep(viewConvosTip, source: tableView, tint: .systemTeal, isHeader: true, section: 1)
        }
    }

    /// Helper to present a tip and wait for either a timeout or manual dismissal.
    /// Returns true if the tour should continue, false if the user dismissed it.
    private func presentTipStep(_ tip: any Tip, source: Any, tint: UIColor, duration: Double = 3.5, isHeader: Bool = false, section: Int = 0) async -> Bool {
        guard !isTourCancelled else { return false }

        let popover: TipUIPopoverViewController

        if let view = source as? UIView {
            popover = TipUIPopoverViewController(tip, sourceItem: view)
            if isHeader {
                popover.popoverPresentationController?.sourceRect = tableView.rectForHeader(inSection: section)
            }
        } else if let item = source as? UIBarButtonItem {
            popover = TipUIPopoverViewController(tip, sourceItem: item)
        } else {
            return false
        }

        popover.view.tintColor = tint

        var userDismissedEarly = false

        // Present and wait
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            present(popover, animated: true) {
                continuation.resume()
            }
        }

        // Poll for dismissal or wait for duration
        let pollCount = Int(duration * 10)
        for _ in 0..<pollCount {
            try? await Task.sleep(for: .milliseconds(100))
            // If user tapped 'X' or outside, the popover will be dismissed
            if popover.isBeingDismissed || popover.presentingViewController == nil {
                userDismissedEarly = true
                break
            }
        }

        if userDismissedEarly {
            // User explicitly dismissed this tip -> Halt the entire tour immediately
            isTourCancelled = true
            tip.invalidate(reason: .tipClosed)
            return false
        }

        // Dismiss automatically if still showing after duration
        if !popover.isBeingDismissed && popover.presentingViewController != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                popover.dismiss(animated: true) {
                    continuation.resume()
                }
            }
        }

        return !isTourCancelled
    }

    // MARK: - (Debug / QA) Reset Tips — call from Settings screen to replay the tip tour
    static func resetTips() {
        UserDefaults.standard.set(false, forKey: tipsShownKey)
        UserDefaults.standard.set(true, forKey: "is_brand_new_signup")
        try? Tips.resetDatastore()
    }

}

// MARK: - TableView Delegate & DataSource (RESTORED HEADERS)
extension HomeViewController: UITableViewDelegate, UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int { return 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return quickActions.count >= 3 ? 3 : quickActions.count + 1
        } else {
            return recentHistory.isEmpty ? 1 : recentHistory.count
        }
    }

    // RESTORED: Heading Labels Logic
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let cellID = (section == 0) ? "QAHeaderCell" : "VCHeaderCell"
        guard let header = tableView.dequeueReusableCell(withIdentifier: cellID) as? HeaderCells else { return nil }

        // Failsafe for disconnected Storyboard Outlets
        if header.titleLabel != nil {
            header.titleLabel.text = (section == 0) ? "Quick Actions" : "View Conversations"
            header.subtitleLabel?.text = (section == 0) ? "Upcoming" : ""
        } else {
            // Programmatic fallback
            header.contentView.subviews.forEach { $0.removeFromSuperview() } // Clear broken IB elements

            let titleLbl = UILabel()
            titleLbl.text = (section == 0) ? "Quick Actions" : "View Conversations"
            titleLbl.font = UIFont.systemFont(ofSize: 22, weight: .bold)
            titleLbl.translatesAutoresizingMaskIntoConstraints = false
            header.contentView.addSubview(titleLbl)

            NSLayoutConstraint.activate([
                titleLbl.leadingAnchor.constraint(equalTo: header.contentView.leadingAnchor, constant: 16),
                titleLbl.centerYAnchor.constraint(equalTo: header.contentView.centerYAnchor)
            ])

            if section == 0 {
                let subLbl = UILabel()
                subLbl.text = "Upcoming"
                subLbl.font = UIFont.systemFont(ofSize: 15, weight: .regular)
                subLbl.textColor = .label
                subLbl.translatesAutoresizingMaskIntoConstraints = false
                header.contentView.addSubview(subLbl)

                NSLayoutConstraint.activate([
                    subLbl.leadingAnchor.constraint(equalTo: titleLbl.trailingAnchor, constant: 8),
                    subLbl.bottomAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: -2)
                ])
            }
        }

        return header.contentView
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 50
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "routineCell", for: indexPath) as? QuickActionTableViewCell else { return UITableViewCell() }

            let isAddRowVisible = quickActions.count < 3
            let isLast = (indexPath.row == (isAddRowVisible ? quickActions.count : 2))
            let isAddRow = isAddRowVisible && (indexPath.row == quickActions.count)
            let isFirst = (indexPath.row == 0)

            if isAddRow {
                cell.configure(with: nil, isFirst: isFirst, isLast: true, isAddRow: true)
            } else {
                let item = quickActions[indexPath.row]
                cell.configure(with: item, isFirst: isFirst, isLast: isLast, isAddRow: false)
            }
            return cell
        } else {
            if recentHistory.isEmpty {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.textLabel?.text = "No recent conversations."
                cell.textLabel?.textAlignment = .center
                cell.textLabel?.textColor = .systemGray
                return cell
            } else {
                guard let cell = tableView.dequeueReusableCell(withIdentifier: "ConversationCardCell", for: indexPath) as? ConversationCardCell else { return UITableViewCell() }
                cell.configure(with: recentHistory[indexPath.row])
                return cell
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let isAddRowVisible = quickActions.count < 3
            if isAddRowVisible && indexPath.row == quickActions.count {
                if let addVC = self.storyboard?.instantiateViewController(withIdentifier: "AddCategoryVC") as? AddActionTableViewController {
                    let nav = UINavigationController(rootViewController: addVC)
                    self.present(nav, animated: true, completion: nil)
                }
            } else {
                let item = quickActions[indexPath.row]

                // ROLE-BASED NAVIGATION
                let currentUID = Auth.auth().currentUser?.uid
                if let host = item.hostUID, host != currentUID {
                    // I am a participant -> Push ActionJoinViewController directly from Action storyboard
                    // This ensures participants join the same room as the host without legacy generic join logic.
                    QuickActionAccess.verifyAccess(for: item, over: self) { [weak self] in
                        let storyboard = UIStoryboard(name: "Action", bundle: nil)
                        if let chatVC = storyboard.instantiateViewController(withIdentifier: "ActionNewViewController") as? ActionJoinViewController {
                            chatVC.sessionTitle = "\(item.conversationTopic) Session"
                            chatVC.category = item.categoryTitle
                            chatVC.roomCode = item.roomCode
                            chatVC.participantNames = item.participantNames ?? []
                            chatVC.hostUID = item.hostUID
                            self?.navigationController?.pushViewController(chatVC, animated: true)
                        }
                    }
                } else {
                    // I am the host (or hostUID missing) -> Go to direct start/join transcription
                    var segueID = ""
                    switch item.categoryTitle {
                    case "Office": segueID = "office"
                    case "Family": segueID = "family"
                    case "Friends": segueID = "friends"
                    default: return
                    }
                    performSegue(withIdentifier: segueID, sender: item)
                }
            }
        } else if indexPath.section == 1 && !recentHistory.isEmpty {
            performSegue(withIdentifier: "viewConvoCell", sender: recentHistory[indexPath.row])
        }
    }

    // MARK: - Queue Deletion & Edit (Swipe for Quick Actions)
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0, indexPath.row < quickActions.count else { return nil }
        let item = quickActions[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] (_, _, completion) in
            self?.performQueueDeletion(for: 0, at: indexPath)
            completion(true)
        }
        deleteAction.backgroundColor = .systemRed
        deleteAction.image = UIImage(systemName: "trash")

        let renameAction = UIContextualAction(style: .normal, title: "Edit") { [weak self] (_, _, completion) in
            self?.showRenameAlert(for: item, row: indexPath.row)
            completion(true)
        }
        renameAction.backgroundColor = .systemOrange
        renameAction.image = UIImage(systemName: "pencil")

        let config = UISwipeActionsConfiguration(actions: [deleteAction, renameAction])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    private func showRenameAlert(for item: RoutineConversation, row: Int) {
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = item.conversationTopic }
        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self = self, let newName = alert.textFields?.first?.text, !newName.isEmpty else { return }

            var updatedItem = item
            updatedItem.conversationTopic = newName
            QuickActionsRepository.shared.updateAction(updatedItem)

            self.quickActions[row] = updatedItem
            self.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .automatic)
        }
        alert.addAction(saveAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Queue Deletion (Context Menu for History)
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section == 1 && !recentHistory.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.showDeleteConfirmation(for: indexPath)
            }
            return UIMenu(title: "", children: [delete])
        }
    }

    func showDeleteConfirmation(for indexPath: IndexPath) {
        let alert = UIAlertController(title: "Delete Conversation?", message: "This action cannot be undone.", preferredStyle: .alert)
        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { _ in
            self.performQueueDeletion(for: 1, at: indexPath)
        }
        alert.addAction(deleteAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
