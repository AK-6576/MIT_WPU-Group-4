//
//  ParticipantSelectionViewController.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 01/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import Contacts
import MessageUI

class ParticipantSelectionViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, MFMessageComposeViewControllerDelegate, UISearchResultsUpdating {

    @IBOutlet weak var tableView: UITableView!

    var realContacts: [CNContact] = []
    var unavailableContacts: Set<String> = []
    var selectedIdentifiers: Set<String> = []
    var filteredContacts: [CNContact] = []
    let searchController = UISearchController(searchResultsController: nil)
    var isFiltering: Bool {
        return searchController.isActive && !(searchController.searchBar.text?.isEmpty ?? true)
    }
    var onParticipantsSelected: (([String]) -> Void)?

    // The code you want to send
    var roomCode = "4492"

    override func viewDidLoad() {
        super.viewDidLoad()

        // Randomize Room ID if it's the static default
        if roomCode == "4492" {
            roomCode = String(format: "%04d", Int.random(in: 1000...9999))
        }

        tableView.delegate = self
        tableView.dataSource = self
        tableView.tableFooterView = UIView()

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search Contacts"
        navigationItem.searchController = searchController
        definesPresentationContext = true

        setupNavigationBar()
        fetchRealContacts()
    }

    func updateSearchResults(for searchController: UISearchController) {
        let searchBar = searchController.searchBar
        let searchText = searchBar.text ?? ""
        filteredContacts = realContacts.filter { contact in
            let fullName = "\(contact.givenName) \(contact.familyName)".lowercased()
            return fullName.contains(searchText.lowercased())
        }
        tableView.reloadData()
    }

    // MARK: - Contacts Fetching
    func fetchRealContacts() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { [weak self] granted, error in
            guard let self = self else { return }

            if granted {
                let keys = [
                    CNContactGivenNameKey,
                    CNContactFamilyNameKey,
                    CNContactThumbnailImageDataKey,
                    CNContactImageDataAvailableKey,
                    CNContactPhoneNumbersKey
                ] as [CNKeyDescriptor]

                let request = CNContactFetchRequest(keysToFetch: keys)

                do {
                    var newContacts: [CNContact] = []
                    try store.enumerateContacts(with: request) { (contact, _) in
                        if !contact.phoneNumbers.isEmpty {
                            newContacts.append(contact)
                        }
                    }

                    DispatchQueue.main.async {
                        self.realContacts = newContacts
                        self.tableView.reloadData()
                    }
                } catch {
                    print("Error fetching contacts: \(error)")
                }
            }
        }
    }

    // MARK: - Navigation
    func setupNavigationBar() {
        if onParticipantsSelected != nil {
            self.title = "Invite Participants (\(roomCode))"
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(closeTapped))
        } else {
            self.title = "Connect"
        }
    }

    @objc func closeTapped() {
        self.dismiss(animated: true, completion: nil)
    }

    // MARK: - Done Action (Trigger SMS)
    @IBAction func doneTapped(_ sender: Any) {

        var recipients: [String] = []
        var selectedNames: [String] = []

        for contact in realContacts where selectedIdentifiers.contains(contact.identifier) {
            let fullName = "\(contact.givenName) \(contact.familyName)"
            selectedNames.append(fullName)

            if let firstNumber = contact.phoneNumbers.first?.value.stringValue {
                recipients.append(firstNumber)
            }
        }

        if recipients.isEmpty {
            // If no recipients, just proceed
            finishSelection(names: selectedNames)
            return
        }

        if MFMessageComposeViewController.canSendText() {
            let messageVC = MFMessageComposeViewController()
            messageVC.messageComposeDelegate = self
            messageVC.recipients = recipients
            messageVC.body = "Join my conversation room! The access code is: \(roomCode)"

            self.present(messageVC, animated: true, completion: nil)
        } else {
            // Show alert fallback for simulator/no SIM
            let alert = UIAlertController(title: "SMS Unavailable", message: "Your device cannot send SMS. Please share the Room Code: \(roomCode) manually with your participants.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak self] _ in
                self?.finishSelection(names: selectedNames)
            }))
            self.present(alert, animated: true)
        }
    }

    // MARK: - Message Composer Delegate
    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        // Dismiss the SMS view first
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }

            // Handle the result (Sent, Cancelled, Failed)
            switch result {
            case .sent:
                print("Invites sent!")
                // Once sent, we can close the selection screen and pass data back
                let selectedNames = self.realContacts.filter { self.selectedIdentifiers.contains($0.identifier) }.map {
                    "\($0.givenName) \($0.familyName)"
                }
                self.finishSelection(names: selectedNames)

            case .cancelled:
                print("User cancelled sending SMS.")
                // Do not dismiss the selection screen; let them try again

            case .failed:
                print("SMS failed.")

            @unknown default:
                break
            }
        }
    }

    func finishSelection(names: [String]) {
        if let callback = onParticipantsSelected {
            callback(names)
            self.dismiss(animated: true, completion: nil)
        } else {
            performSegue(withIdentifier: "goToChat", sender: self)
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "goToChat" {
            if let destVC = segue.destination as? GroupNewViewController {
                destVC.currentSessionID = self.roomCode
            }
        }
    }

    // MARK: - TableView Data Source
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isFiltering ? filteredContacts.count : realContacts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "ContactCell", for: indexPath) as? ContactCell else { return UITableViewCell() }
        let contact = isFiltering ? filteredContacts[indexPath.row] : realContacts[indexPath.row]
        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)

        cell.nameLabel.text = fullName

        if contact.imageDataAvailable, let data = contact.thumbnailImageData {
            cell.profileImageView.image = UIImage(data: data)
        } else {
            cell.profileImageView.image = UIImage(systemName: "person.circle.fill")
        }

        if unavailableContacts.contains(fullName) {
            cell.nameLabel.textColor = .systemGray3
            cell.isUserInteractionEnabled = false
            cell.accessoryType = .none
            cell.nameLabel.text = "\(fullName) (Unavailable)"
            cell.profileImageView.alpha = 0.5
        } else {
            cell.isUserInteractionEnabled = true
            cell.profileImageView.alpha = 1.0
            if selectedIdentifiers.contains(contact.identifier) {
                cell.nameLabel.textColor = .systemBlue
                cell.accessoryType = .checkmark
            } else {
                cell.nameLabel.textColor = .label
                cell.accessoryType = .none
            }
        }
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let contact = isFiltering ? filteredContacts[indexPath.row] : realContacts[indexPath.row]
        let id = contact.identifier
        if selectedIdentifiers.contains(id) {
            selectedIdentifiers.remove(id)
        } else {
            selectedIdentifiers.insert(id)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}
