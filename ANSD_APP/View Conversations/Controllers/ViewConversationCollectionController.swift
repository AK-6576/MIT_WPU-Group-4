//
//  ViewConversationCollectionController.swift
//  ANSD_APP
//
//  Created by Omkar Varpe on 15/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import Foundation
import SwiftData

class SimpleMonthHeaderView: UICollectionReusableView {
    let label = UILabel()
    let chevronImageView = UIImageView()
    let stackView = UIStackView()
    var onHeaderTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.alignment = .center

        chevronImageView.contentMode = .scaleAspectFit
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chevronImageView.widthAnchor.constraint(equalToConstant: 16),
            chevronImageView.heightAnchor.constraint(equalToConstant: 16)
        ])

        // Add spacer to dynamically push the chevron to the exact trailing edge
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stackView.addArrangedSubview(label)
        stackView.addArrangedSubview(spacer)
        stackView.addArrangedSubview(chevronImageView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), // Locks the stack to the full width
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        label.font = UIFont.boldSystemFont(ofSize: 22)
        label.textColor = .label
        chevronImageView.tintColor = .secondaryLabel

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    @objc func handleTap() {
        onHeaderTapped?()
    }

    func configureChevron(isCollapsed: Bool?) {
        if let collapsed = isCollapsed {
            chevronImageView.isHidden = false
            let config = UIImage.SymbolConfiguration(weight: .bold)
            chevronImageView.image = UIImage(systemName: collapsed ? "chevron.right" : "chevron.down", withConfiguration: config)
        } else {
            chevronImageView.isHidden = true
        }
    }
}

class ViewConversationCollection: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UISearchBarDelegate {

    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet var searchBar: UISearchBar!
    @IBOutlet weak var searchBarBottomConstraint: NSLayoutConstraint!

    var allConversationSections: [ConversationSection] = []
    var conversationSections: [ConversationSection] = []
    var originalBottomConstant: CGFloat = 0
    var isPinnedCollapsed: Bool = false

    // Tracks the current filter
    var activeSelectedDate: Date?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavBar()
        setupCollectionView()
        setupSearchBarUI()
        loadConversationData()
        originalBottomConstant = searchBarBottomConstraint.constant

        NotificationCenter.default.addObserver(self, selector: #selector(handleDataUpdate), name: NSNotification.Name("ConversationHistoryUpdated"), object: nil)
    }

    @objc func handleDataUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.loadConversationData()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // ONLY fetch everything if we are NOT currently filtering by a calendar date
        if activeSelectedDate == nil {
            loadConversationData()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        let selectedConversation = conversationSections[indexPath.section].conversations[indexPath.row]

        guard let chatVC = self.storyboard?.instantiateViewController(withIdentifier: "ChatHistory2ViewController") as? ChatHistoryViewController else { return }
        chatVC.histconversationData = selectedConversation

        guard let navController = self.navigationController else { return }
        navController.pushViewController(chatVC, animated: true)
        searchBar.resignFirstResponder()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let isPinned = self.conversationSections[indexPath.section].conversations[indexPath.row].isPinned
            let pinTitle = isPinned ? "Unpin" : "Pin"
            let pinImage = isPinned ? UIImage(systemName: "pin.slash") : UIImage(systemName: "pin")

            let pinAction = UIAction(title: pinTitle, image: pinImage) { _ in
                let updatedConvo = self.conversationSections[indexPath.section].conversations[indexPath.row]
                updatedConvo.isPinned.toggle()
                DataManager.shared.saveData()
                self.loadConversationData() // HIG: Full reload to cleanly move the item between sections instead of just reloading the cell.
            }

            let renameAction = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in
                self.showRenameAlert(for: indexPath)
            }

            let deleteAction = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.showDeleteConfirmation(for: indexPath)
            }

            return UIMenu(title: "", children: [pinAction, renameAction, deleteAction])
        }
    }

    func showRenameAlert(for indexPath: IndexPath) {
        let currentTitle = conversationSections[indexPath.section].conversations[indexPath.row].title
        let alert = UIAlertController(title: "Rename Conversation", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = currentTitle
            textField.autocapitalizationType = .sentences
        }
        let saveAction = UIAlertAction(title: "Save", style: .default) { _ in
            if let newName = alert.textFields?.first?.text, !newName.isEmpty {
                let updatedConvo = self.conversationSections[indexPath.section].conversations[indexPath.row]
                updatedConvo.title = newName
                DataManager.shared.saveData()
                self.collectionView.reloadItems(at: [indexPath])
            }
        }
        alert.addAction(saveAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    func showDeleteConfirmation(for indexPath: IndexPath) {
        let alert = UIAlertController(title: "Delete Conversation?", message: "This action cannot be undone.", preferredStyle: .alert)
        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { _ in
            self.performSingleDeletion(at: indexPath)
        }
        alert.addAction(deleteAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    func performSingleDeletion(at indexPath: IndexPath) {
        let convoToDelete = conversationSections[indexPath.section].conversations[indexPath.row]
        DataManager.shared.deleteConversation(convoToDelete)

        collectionView.performBatchUpdates({
            self.conversationSections[indexPath.section].conversations.remove(at: indexPath.row)
            self.collectionView.deleteItems(at: [indexPath])
            if self.conversationSections[indexPath.section].conversations.isEmpty {
                self.conversationSections.remove(at: indexPath.section)
                self.collectionView.deleteSections(IndexSet(integer: indexPath.section))
            }
        }, completion: nil)
    }

    func setupSearchBarUI() {
        searchBar.backgroundImage = UIImage()
        searchBar.barTintColor = .clear
        searchBar.backgroundColor = .clear
        searchBar.isTranslucent = true
        searchBar.isUserInteractionEnabled = true

        if let textField = searchBar.value(forKey: "searchField") as? UITextField {
            textField.backgroundColor = .clear
            textField.textColor = .black
            textField.layer.cornerRadius = 24
            textField.layer.masksToBounds = true

            // Shadows removed per design spec

            textField.attributedPlaceholder = NSAttributedString(
                string: "Search",
                attributes: [NSAttributedString.Key.foregroundColor: UIColor.gray]
            )
        }
    }

    func setupNavBar() {
        collectionView.backgroundColor = .systemGroupedBackground
        view.backgroundColor = .systemGroupedBackground
    }

    @objc func keyboardWillShow(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber else { return }

        let animationCurve = UIView.AnimationOptions(rawValue: curveValue.uintValue << 16)
        let targetHeight = keyboardFrame.height
        let distanceToLift = targetHeight - view.safeAreaInsets.bottom

        UIView.animate(withDuration: duration, delay: 0, options: [animationCurve], animations: {
            self.searchBarBottomConstraint.constant = -distanceToLift + self.originalBottomConstant
            let bottomInset = distanceToLift + self.searchBar.frame.height + 10
            self.collectionView.contentInset.bottom = bottomInset
            self.collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
            self.view.layoutIfNeeded()
        }, completion: nil)
    }

    @objc func keyboardWillHide(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber else { return }

        let animationCurve = UIView.AnimationOptions(rawValue: curveValue.uintValue << 16)
        let originalBottomPadding: CGFloat = 100.0

        UIView.animate(withDuration: duration, delay: 0, options: [animationCurve], animations: {
            self.searchBarBottomConstraint.constant = self.originalBottomConstant
            self.collectionView.contentInset.bottom = originalBottomPadding
            self.collectionView.verticalScrollIndicatorInsets.bottom = originalBottomPadding
            self.view.layoutIfNeeded()
        }, completion: nil)
    }

    func setupCollectionView() {
        collectionView.delegate = self
        collectionView.dataSource = self
        searchBar.delegate = self

        let nib = UINib(nibName: "ConversationCollectionViewCell", bundle: nil)
        collectionView.register(nib, forCellWithReuseIdentifier: "conversationCell")
        collectionView.register(SimpleMonthHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "headerId")

        // HIG: Apply Compositional Layout
        collectionView.collectionViewLayout = createCompositionalLayout()

        collectionView.contentInset.bottom = 100
    }

    func createCompositionalLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] (_: Int, _: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? in
            guard let self = self else { return nil }

            // HIG: 100% Vertical List for all sections (both History and Pinned) to precisely match Apple Notes Flow
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(120))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(120))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 12
            // HIG: "approx half to half to the top spacing"
            // Bottom margin connecting sections is 20, so top margin (gap between header and first card) is 10 (half constraint)
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 20, trailing: 16)

            let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(50))
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            section.boundarySupplementaryItems = [header]

            return section
        }
        return layout
    }

    func loadConversationData() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let allConvos = DataManager.shared.fetchConversations()
            var pinnedConvos: [Conversation] = [] // HIG: Distinct grouping for pinned items

            var todayConvos: [Conversation] = []
            var yesterdayConvos: [Conversation] = []

            // HIG: Exclusively group all history between 3-30 days into a single bucket
            var recentConvos: [Conversation] = []
            var maxRecentDaysAgo: Int = 0

            var monthDict: [String: [Conversation]] = [:]
            var yearDict: [String: [Conversation]] = [:]

            // Arrays to rigidly maintain the chronological order as items flow in
            var monthTitles: [String] = []
            var yearTitles: [String] = []

            let calendar = Calendar.current
            let now = Date()

            let monthFormatter = DateFormatter()
            monthFormatter.dateFormat = "MMMM" // e.g. "October"

            let yearFormatter = DateFormatter()
            yearFormatter.dateFormat = "yyyy" // e.g. "2023"

            for convo in allConvos {
                if convo.isPinned {
                    pinnedConvos.append(convo)
                    continue // Isolate from standard timeline flow
                }

                if let date = convo.calendarDate {
                    if calendar.isDateInToday(date) {
                        todayConvos.append(convo)
                    } else if calendar.isDateInYesterday(date) {
                        yesterdayConvos.append(convo)
                    } else {
                        // Accurately count elapsed days using purely start-of-day offsets
                        let startOfNow = calendar.startOfDay(for: now)
                        let startOfDate = calendar.startOfDay(for: date)
                        let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

                        // HIG: Deep Apple Notes style relative-time classifications (Mutually exclusive 7 vs 30 days)
                        if daysAgo <= 30 {
                            recentConvos.append(convo)
                            maxRecentDaysAgo = max(maxRecentDaysAgo, daysAgo)
                        } else if daysAgo <= 365 {
                            let mTitle = monthFormatter.string(from: date)
                            if monthDict[mTitle] == nil {
                                monthDict[mTitle] = []
                                monthTitles.append(mTitle)
                            }
                            monthDict[mTitle]?.append(convo)
                        } else {
                            let yTitle = yearFormatter.string(from: date)
                            if yearDict[yTitle] == nil {
                                yearDict[yTitle] = []
                                yearTitles.append(yTitle)
                            }
                            yearDict[yTitle]?.append(convo)
                        }
                    }
                } else {
                    // Safety Fallback for corrupted date entries
                    let yTitle = "Previous History"
                    if yearDict[yTitle] == nil {
                        yearDict[yTitle] = []
                        yearTitles.append(yTitle)
                    }
                    yearDict[yTitle]?.append(convo)
                }
            }

            var loadedSections: [ConversationSection] = []

            // Append sequentially to establish hierarchy
            if !pinnedConvos.isEmpty { loadedSections.append(ConversationSection(title: "Pinned", conversations: pinnedConvos)) }

            if !todayConvos.isEmpty { loadedSections.append(ConversationSection(title: "Today", conversations: todayConvos)) }
            if !yesterdayConvos.isEmpty { loadedSections.append(ConversationSection(title: "Yesterday", conversations: yesterdayConvos)) }

            // Generate either the 7-day or 30-day header based on the oldest conversation in this bucket
            if !recentConvos.isEmpty {
                let dynamicTitle = maxRecentDaysAgo <= 7 ? "Previous 7 Days" : "Previous 30 Days"
                loadedSections.append(ConversationSection(title: dynamicTitle, conversations: recentConvos))
            }

            for title in monthTitles {
                if let convos = monthDict[title], !convos.isEmpty {
                    loadedSections.append(ConversationSection(title: title, conversations: convos))
                }
            }

            for title in yearTitles {
                if let convos = yearDict[title], !convos.isEmpty {
                    loadedSections.append(ConversationSection(title: title, conversations: convos))
                }
            }

            if loadedSections.isEmpty {
                loadedSections = [ConversationSection(title: "No Conversations Found.", conversations: [])]
            }

            self.allConversationSections = loadedSections
            self.conversationSections = loadedSections
            self.collectionView.reloadData()
        }
    }

    // UPDATED: Properly resets the title and rebuilds the calendar button
    @objc func clearFilter() {
        // 1. Reset the active date
        self.activeSelectedDate = nil

        // 2. Reset the navigation bar UI safely using self.title
        self.title = "View Conversations"

        // 3. Rebuild the Calendar button and connect it back to your Storyboard action
        let calendarIcon = UIImage(systemName: "calendar")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: calendarIcon,
            style: .plain,
            target: self,
            action: #selector(calenderbuttontapped(_:))
        )

        // 4. Reload all data
        self.loadConversationData()

    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return conversationSections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if conversationSections[section].title == "Pinned" && isPinnedCollapsed {
            return 0
        }
        return conversationSections[section].conversations.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "conversationCell", for: indexPath) as? ConversationCollectionViewCell else {
            return UICollectionViewCell()
        }
        let item = conversationSections[indexPath.section].conversations[indexPath.row]
        cell.configure(with: item)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        if kind == UICollectionView.elementKindSectionHeader {
            guard let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "headerId", for: indexPath) as? SimpleMonthHeaderView else { return UICollectionReusableView() }

            let title = conversationSections[indexPath.section].title
            header.label.text = title

            if title == "Pinned" {
                header.configureChevron(isCollapsed: isPinnedCollapsed)
                header.isUserInteractionEnabled = true
                header.onHeaderTapped = { [weak self] in
                    guard let self = self else { return }
                    self.isPinnedCollapsed.toggle()
                    self.collectionView.reloadSections(IndexSet(integer: indexPath.section))
                }
            } else {
                header.configureChevron(isCollapsed: nil)
                header.isUserInteractionEnabled = false
            }
            return header
        }
        return UICollectionReusableView()
    }

    // HIG: UICollectionViewDelegateFlowLayout math deleted in favor of Compositional Layout dynamic sizing

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        if searchText.isEmpty {
            self.conversationSections = self.allConversationSections
        } else {
            let lowercasedSearchText = searchText.lowercased()
            self.conversationSections = self.allConversationSections.compactMap { section in
                let filtered = section.conversations.filter { convo in
                    convo.title.lowercased().contains(lowercasedSearchText) ||
                    convo.details.lowercased().contains(lowercasedSearchText)
                }
                return filtered.isEmpty ? nil : ConversationSection(title: section.title, conversations: filtered)
            }
        }
        self.collectionView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    struct ConversationSection {
        let title: String
        var conversations: [Conversation]
    }

    @IBAction func calenderbuttontapped(_ sender: Any) {
        guard let calendarVC = self.storyboard?.instantiateViewController(withIdentifier: "calenderViewController") as? CalenderViewController else { return }
        calendarVC.delegate = self

        if let sheet = calendarVC.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        present(calendarVC, animated: true)
    }
}

extension ViewConversationCollection: CalendarDelegate {

    func didSelectDate(_ date: Date) {

        self.activeSelectedDate = date
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let displayDate = formatter.string(from: date)

        // Ask DataManager to fetch only the relevant records
        let filteredConversations = DataManager.shared.fetchConversations(for: date)

        // Update UI state
        if filteredConversations.isEmpty {
            self.conversationSections = [ConversationSection(title: "No chats on \(displayDate)", conversations: [])]
        } else {
            self.conversationSections = [ConversationSection(title: displayDate, conversations: filteredConversations)]
        }

        self.collectionView.reloadData()

        // UPDATED: Update Navigation Bar safely using self.title and boldly stylized Clear button
        self.title = displayDate
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Clear",
            style: .plain,
            target: self,
            action: #selector(clearFilter)
        )

    }
}
