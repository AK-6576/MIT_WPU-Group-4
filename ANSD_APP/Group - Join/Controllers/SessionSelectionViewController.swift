//
//  SessionSelectionViewController.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 01/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit

// MARK: - Model for a discovered active room
private struct ActiveRoom {
    let hash: String        // Firebase key (hashed code) — used for dedup
    let displayCode: String // The human-readable 4-digit code
    let title: String       // "Room 3930" or host-renamed title
    let hostName: String    // Display name of the host
}

class SessionSelectionViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    @IBOutlet weak var GroupJoinTableView: UITableView!

    // Live list of active rooms discovered from Firebase
    private var activeRooms: [ActiveRoom] = []
    private var isLoading = true

    // Passed in when coming from a Quick Action deep-link
    var prefilledRoomCode: String?

    private let firebase = FirebaseManager.shared

    private lazy var activityIndicator: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Join a Session"
        setupTableView()
        setupEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Handle deep-link pre-fill (Quick Action)
        if let code = prefilledRoomCode {
            prefilledRoomCode = nil
            let data = (code: code, title: "Room \(code)")
            performSegue(withIdentifier: "goToChat", sender: data)
            return
        }

        // Stop any previously stacked observers before adding new ones
        firebase.stopObservingActiveRooms()

        // Reset state
        isLoading = true
        activityIndicator.startAnimating()
        activeRooms.removeAll()
        GroupJoinTableView.reloadData()
        startObservingRooms()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Only stop observing if we're being fully removed (not just covered by a segue)
        // We stop in viewWillAppear before re-subscribing, so no need to stop here
        // — but we do stop if popping back to avoid leaks when user backs out entirely
        if isMovingFromParent {
            firebase.stopObservingActiveRooms()
        }
        activityIndicator.stopAnimating()
    }

    // MARK: - Setup
    private func setupTableView() {
        GroupJoinTableView.delegate = self
        GroupJoinTableView.dataSource = self
        GroupJoinTableView.backgroundColor = .systemGroupedBackground
        GroupJoinTableView.tableFooterView = UIView()
        GroupJoinTableView.isHidden = false

        // Collapse the top padding so "Enter Room Code" sits at the top when no active rooms
        var frame = CGRect.zero
        frame.size.height = .leastNormalMagnitude
        GroupJoinTableView.tableHeaderView = UIView(frame: frame)

        if #available(iOS 15.0, *) {
            GroupJoinTableView.sectionHeaderTopPadding = 0
        }
    }

    private func setupEmptyState() {
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
        ])
    }

    // MARK: - Firebase
    private func startObservingRooms() {
        firebase.observeActiveRooms(
            onAdded: { [weak self] hash, displayCode, title, hostName in
                guard let self = self else { return }
                print("[SessionSelection] Room arrived — code: \(displayCode), title: \(title), host: \(hostName)")
                if !self.activeRooms.contains(where: { $0.hash == hash }) {
                    self.activeRooms.append(ActiveRoom(hash: hash, displayCode: displayCode, title: title, hostName: hostName))
                    self.isLoading = false
                    self.updateEmptyState()
                    self.GroupJoinTableView.reloadData()
                }
            },
            onRemoved: { [weak self] hash in
                guard let self = self else { return }
                print("[SessionSelection] Room removed — hash: \(hash)")
                self.activeRooms.removeAll { $0.hash == hash }
                self.updateEmptyState()
                self.GroupJoinTableView.reloadData()
            }
        )

        // Give Firebase up to 5s to deliver rooms before stopping the spinner
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            self.isLoading = false
            self.activityIndicator.stopAnimating()
            self.updateEmptyState()
        }
    }

    private func updateEmptyState() {
        if !isLoading { activityIndicator.stopAnimating() }
    }

    // MARK: - TableView — Two sections
    // Section 0: Active sessions (one row per room, hidden when empty)
    // Section 1: Manual entry ("Enter Room Code")

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return activeRooms.isEmpty ? nil : "Active Sessions"
        case 1: return nil
        default: return nil
        }
    }

    // Collapse section 0 header and footer completely when there are no active rooms
    // — this removes the grey space above "Enter Room Code"
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 && activeRooms.isEmpty { return .leastNormalMagnitude }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        if section == 0 && activeRooms.isEmpty { return .leastNormalMagnitude }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return activeRooms.count
        case 1: return 1
        default: return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "ActiveRoomCell")
            let room = activeRooms[indexPath.row]

            var content = cell.defaultContentConfiguration()
            content.image = UIImage(systemName: "circle.fill")
            content.imageProperties.tintColor = .systemGreen
            content.imageProperties.maximumSize = CGSize(width: 10, height: 10)
            // Title: "Room 3930", Subtitle: host name
            content.text = room.title
            content.secondaryText = room.hostName.isEmpty ? "Host" : room.hostName
            content.textProperties.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            content.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13)
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        } else {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "ManualEntryCell")
            var content = cell.defaultContentConfiguration()
            content.image = UIImage(systemName: "key.fill")
            content.imageProperties.tintColor = .secondaryLabel
            content.text = "Enter Room Code"
            content.secondaryText = "Type a 4-digit code manually"
            content.textProperties.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            content.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13)
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 0 {
            // Active room tapped — pre-fill the code, user just hits Join
            let room = activeRooms[indexPath.row]
            showJoinSessionAlert(title: room.title, prefilledCode: room.displayCode)
        } else {
            // Manual entry — empty text field
            showJoinSessionAlert(title: "Join Session", prefilledCode: nil)
        }
    }

    // MARK: - Alert
    private func showJoinSessionAlert(title: String, prefilledCode: String?) {
        let alert = UIAlertController(
            title: "Join Session",
            message: prefilledCode != nil
                ? "Tap Join to enter \(title)."
                : "Enter the 4-digit room code.",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "Room Code"
            textField.textAlignment = .center
            textField.keyboardType = .numberPad
            textField.text = prefilledCode  // pre-fill if we have it
        }

        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)

        let joinAction = UIAlertAction(title: "Join", style: .default) { [weak self] _ in
            guard let self = self else { return }
            if let code = alert.textFields?.first?.text, !code.isEmpty {
                // Use the human-readable title passed in, not "Join via Code"
                let roomTitle = title == "Join Session" ? "Room \(code)" : title
                let data = (code: code, title: roomTitle)
                self.performSegue(withIdentifier: "goToChat", sender: data)
            }
        }

        alert.addAction(cancelAction)
        alert.addAction(joinAction)
        present(alert, animated: true)
    }

    // MARK: - Navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "goToChat",
           let chatVC = segue.destination as? GroupJoinViewController,
           let data = sender as? (code: String, title: String) {
            chatVC.currentSessionID = data.code
            chatVC.sessionTitle = data.title
        }
    }
}
