//
//  ChatHistoryViewController.swift
//  ANSD_APP
//
//  Created by Omkar Varpe on 15/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import PDFKit
import FoundationModels // Apple Intelligence added

// MARK: - Protocols

protocol ViewNotesCardCellDelegate: AnyObject {
    func didUpdateText(in cell: ViewNotesCardCell)
}

protocol ViewSummaryCardDelegate: AnyObject {
    func didChangeTitle(text: String)
}

// MARK: - Custom TableView Cell Classes

class ViewSummarySectionHeaderCell: UITableViewCell {
    @IBOutlet weak var headerIcon: UIImageView!
    @IBOutlet weak var headerLabel: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.layer.cornerRadius = 20
    }
}

class ViewParticipantsSummaryHeaderCell: UITableViewCell {
    @IBOutlet weak var participantIcon: UIImageView!
    @IBOutlet weak var participantLabel: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.layer.cornerRadius = 20
    }
}

class ViewNotesSectionHeaderCell: UITableViewCell {
    @IBOutlet weak var notesIcon: UIImageView!
    @IBOutlet weak var notesLabel: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()
        backgroundColor = .clear
    }
}

class ViewSummaryCardCell: UITableViewCell {
    @IBOutlet weak var mainCardView: UIView!
    @IBOutlet weak var titleTextField: UITextField!
    @IBOutlet weak var dateLabel: UILabel!
    @IBOutlet weak var timeLabel: UILabel!
    @IBOutlet weak var locationLabel: UILabel!

    weak var delegate: ViewSummaryCardDelegate?

    override func awakeFromNib() {
        super.awakeFromNib()
        backgroundColor = .clear
        mainCardView.backgroundColor = .systemBackground
        mainCardView.layer.cornerRadius = 16

        mainCardView.layer.masksToBounds = false
    }

    @IBAction func titleChanged(_ sender: UITextField) {
        delegate?.didChangeTitle(text: sender.text ?? "")
    }
}

class ViewParticipantsCardCell: UITableViewCell {
    @IBOutlet weak var mainCardView: UIView!
    @IBOutlet weak var detailsLabel: UILabel!
    @IBOutlet weak var avatarView: UIView!
    @IBOutlet weak var initialsLabel: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Standard Card Styling
        mainCardView.layer.cornerRadius = 16
        mainCardView.backgroundColor = .systemBackground
        mainCardView.layer.masksToBounds = false

        // Avatar Square Styling
        avatarView?.layer.cornerRadius = 8
        avatarView?.clipsToBounds = true
    }

    func configure(with data: Participant) {
        detailsLabel.text = data.summary

        // 1. Logic to generate initials
        let nameToParse = data.name
        let components = nameToParse.components(separatedBy: " ")
        let initials = components.compactMap { $0.first }.map { String($0) }.joined()
        initialsLabel?.text = String(initials.prefix(2)).uppercased()

        // 2. Logic to set colors based on identity
        let currentUserName = (UserDefaults.standard.string(forKey: "user_first_name") ?? "").lowercased()
        let speakerName = nameToParse.lowercased()

        if (!currentUserName.isEmpty && speakerName.contains(currentUserName)) || speakerName == "you" {
            avatarView?.backgroundColor = .systemBlue
            initialsLabel?.textColor = .white
        } else {
            avatarView?.backgroundColor = .systemGray4
            initialsLabel?.textColor = .label
        }
    }
}

class ViewNotesCardCell: UITableViewCell, UITextViewDelegate {
    @IBOutlet weak var mainCardView: UIView!
    @IBOutlet weak var notesTextView: UITextView!

    weak var delegate: ViewNotesCardCellDelegate?
    let placeholderText = "Add notes about this conversation..."

    override func awakeFromNib() {
        super.awakeFromNib()
        backgroundColor = .clear

        notesTextView.delegate = self
        notesTextView.font = UIFont.systemFont(ofSize: 15)
        notesTextView.isScrollEnabled = false
        notesTextView.textContainerInset = .zero
        notesTextView.textContainer.lineFragmentPadding = 0

        mainCardView.backgroundColor = .secondarySystemGroupedBackground
        mainCardView.layer.cornerRadius = 12
        mainCardView.layer.masksToBounds = false
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if textView.text == placeholderText {
            textView.text = nil
            textView.textColor = UIColor.label
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView.text.isEmpty {
            textView.text = placeholderText
            textView.textColor = .lightGray
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        delegate?.didUpdateText(in: self)
    }
}

// MARK: - Chat History View Controller

class ChatHistoryViewController: UIViewController {

    @IBOutlet var segmentedControl: UISegmentedControl!
    @IBOutlet var chatContainerView: UIView!
    @IBOutlet var summaryContainerView: UIView!
    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet var menuButton: UIBarButtonItem!
    @IBOutlet weak var tableView: UITableView!

    let emptyChatLabel = UILabel()
    var histconversationData: Conversation?
    var isHighlightModeActive = false
    var conversationTitle = "Conversation Summary"
    var participantsData: [Participant] = []

    var transcript: [Message] {
        return (histconversationData?.messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - AI & State Properties
    private let model = SystemLanguageModel.default
    private var isProcessing = false
    private(set) var generatedNotesText: String = "Generating summary..."

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        setupNavigation()
        setupChatUI()
        setupSummaryUI()
        setupShareButton()
        updateContainerViews()

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        let hasExistingParticipants = histconversationData?.participants?.isEmpty == false

        if hasExistingParticipants {
            // Deduplicate existing participants by lowercased name (cleans up legacy data)
            var seenNames = Set<String>()
            var deduped = [Participant]()
            for p in histconversationData!.participants! {
                let key = p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !seenNames.contains(key) {
                    seenNames.insert(key)
                    deduped.append(p)
                }
            }
            self.participantsData = deduped
            self.generatedNotesText = histconversationData?.notes ?? ""
        } else if !transcript.isEmpty {
            prepareParticipantsFromMessages()
            generateAISummary()
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - AI Summarization Logic

    private func prepareParticipantsFromMessages() {
        let placeholders: Set<String> = ["system", "listening...", "identifying…", "identifying..."]
        var seenIDs = [String: Int]() // senderId -> index
        var result = [Participant]()

        for msg in transcript {
            let trimmedName = msg.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerName = trimmedName.lowercased()
            if placeholders.contains(lowerName) { continue }

            let key = msg.senderId.isEmpty ? lowerName : msg.senderId

            if let idx = seenIDs[key] {
                // Update to the latest display name for this speaker
                result[idx].name = trimmedName
            } else {
                seenIDs[key] = result.count
                result.append(Participant(name: trimmedName, summary: "Waiting for analysis...", image: "person.circle.fill"))
            }
        }

        self.participantsData = result
        tableView.reloadData()
    }

    private func generateAISummary() {
        isProcessing = true
        let fullTranscript = transcript.map { "\($0.senderName): \($0.text)" }.joined(separator: "\n")

        Task {
            do {
                let instructions = """
                You are an expert transcriber and conversation analyst for a live captioning app designed for people with hearing loss. Analyze transcripts and provide structured summaries.

                GUARDRAILS:
                - Never fabricate, hallucinate, or invent information not present in the transcript.
                - Never produce harmful, offensive, biased, or discriminatory content.
                - If the transcript is empty or meaningless, return an empty string.
                - Always respond in the SAME language as the transcript.
                - Never include commentary, apologies, disclaimers, or boilerplate text.
                - Strictly output only the requested sections with no extra text.
                - Do NOT use dashes (-) for listing things.
                """

                let prompt = """
                Analyze the following transcript. Provide the summary and notes in the SAME language as the transcript.

                Step 1: Write a section strictly labeled "NOTES:" summarizing the key takeaways and action items in short, clean sentences. Provide each point on a new line as a standalone sentence.

                Step 2: For each participant, write a section strictly labeled "SUMMARY_[Name]:" containing a short summary of what they said in the third person in 1-2 concise sentences. Do not duplicate participants!

                TRANSCRIPT:
                \(fullTranscript)
                """

                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt)

                await MainActor.run {
                    self.parseAIResponse(response.content)
                    self.isProcessing = false
                    self.tableView.reloadData()
                    self.notifyDataChanged()
                }

            } catch {
                await MainActor.run {
                    self.generatedNotesText = "Could not generate summary. Error: \(error.localizedDescription)"
                    self.isProcessing = false
                    self.tableView.reloadData()
                }
            }
        }
    }

    private func parseAIResponse(_ text: String) {
        var notesBuffer = ""
        let components = text.components(separatedBy: CharacterSet.newlines)
        var currentSection = ""
        var participantSummaries: [String: String] = [:]

        for line in components {
            if line.contains("NOTES:") {
                currentSection = "NOTES"
                continue
            }
            if let startRange = line.range(of: "SUMMARY_"),
               let endRange = line.range(of: ":", range: startRange.upperBound..<line.endIndex) {
                let name = String(line[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                currentSection = name
                continue
            }

            if currentSection == "NOTES" {
                notesBuffer += line + "\n"
            } else if !currentSection.isEmpty {
                let existing = participantSummaries[currentSection] ?? ""
                participantSummaries[currentSection] = existing + line + " "
            }
        }

        self.generatedNotesText = notesBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.generatedNotesText.isEmpty { self.generatedNotesText = text }
        self.histconversationData?.notes = self.generatedNotesText

        for (name, summary) in participantSummaries {
            if let index = participantsData.firstIndex(where: { name.contains($0.name) || $0.name.contains(name) }) {
                participantsData[index].summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        self.histconversationData?.participants = self.participantsData
    }

    // MARK: - Setup Methods

    private func setupNavigation() {
        if let convoData = histconversationData {
            navigationItem.title = convoData.title
            conversationTitle = convoData.title
        } else {
            navigationItem.title = "Details"
        }
    }

    private func setupChatUI() {
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.layer.cornerRadius = 20
        chatContainerView.layer.cornerRadius = 20

        if let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            flowLayout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
        }

        setupEmptyChatLabel()
        collectionView.reloadData()

        if !transcript.isEmpty {
            DispatchQueue.main.async {
                self.scrollToBottom(animated: false)
            }
        }
    }

    private func setupSummaryUI() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
    }

    private func setupShareButton() {
        if let shareBtn = menuButton {
            shareBtn.target = self
            shareBtn.action = #selector(shareTapped)
        }
    }

    @objc private func shareTapped() {
        shareAsPDF()
    }

    private func notifyDataChanged() {
        if let updatedConvo = self.histconversationData {
            DataManager.shared.saveData()
            NotificationCenter.default.post(
                name: NSNotification.Name("ConversationUpdated"),
                object: nil,
                userInfo: ["updatedConversation": updatedConvo]
            )
        }
    }

    @IBAction func chatNsumSegmentedController(_ sender: UISegmentedControl) {
        view.endEditing(true)
        updateContainerViews()
    }

    private func updateContainerViews() {
        let isChatSelected = (segmentedControl.selectedSegmentIndex == 0)
        chatContainerView.isHidden = !isChatSelected
        summaryContainerView.isHidden = isChatSelected

        if isChatSelected {
            updateEmptyState()
        } else {
            tableView.reloadData()
        }
    }

    private func updateEmptyState() {
        let isEmpty = transcript.isEmpty
        collectionView.isHidden = isEmpty
        emptyChatLabel.isHidden = !isEmpty
    }

    private func scrollToBottom(animated: Bool = true) {
        guard !transcript.isEmpty else { return }
        let lastItem = transcript.count - 1
        collectionView.scrollToItem(at: IndexPath(item: lastItem, section: 0), at: .bottom, animated: animated)
    }

    private func setupEmptyChatLabel() {
        emptyChatLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyChatLabel.text = "No chat transcript available."
        emptyChatLabel.textColor = .systemGray
        emptyChatLabel.textAlignment = .center
        chatContainerView.addSubview(emptyChatLabel)
        NSLayoutConstraint.activate([
            emptyChatLabel.centerXAnchor.constraint(equalTo: chatContainerView.centerXAnchor),
            emptyChatLabel.centerYAnchor.constraint(equalTo: chatContainerView.centerYAnchor)
        ])
    }

    private func showEditAlert(for indexPath: IndexPath) {
        let message = transcript[indexPath.row]
        let alert = UIAlertController(title: "Edit Message", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = message.text }

        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            if let newText = alert.textFields?.first?.text {
                self.histconversationData?.messages?[indexPath.row].text = newText
                self.histconversationData?.messages?[indexPath.row].isEdited = true
                self.collectionView.reloadItems(at: [indexPath])
                self.notifyDataChanged()
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - PDF Generation

extension ChatHistoryViewController {

    private func shareAsPDF() {
        var pdfContent = "Conversation Title: \(conversationTitle)\n\n"

        for person in participantsData {
            pdfContent += "\(person.name):\n\(person.summary)\n\n"
        }

        let notesToPrint = histconversationData?.notes ?? generatedNotesText
        if !notesToPrint.isEmpty {
            pdfContent += "Notes:\n\(notesToPrint)\n\n"
        }

        if let pdfURL = createPDF(from: pdfContent) {
            let activityVC = UIActivityViewController(activityItems: [pdfURL], applicationActivities: nil)
            self.present(activityVC, animated: true)
        }
    }

    private func createPDF(from text: String) -> URL? {
        let pageWidth = 595.2
        let pageHeight = 841.8
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let data = renderer.pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .paragraphStyle: NSMutableParagraphStyle()
            ]
            let textRect = CGRect(x: 40, y: 40, width: pageWidth - 80, height: pageHeight - 80)
            text.draw(in: textRect, withAttributes: attributes)
        }

        let tempFolder = FileManager.default.temporaryDirectory
        let safeTitle = conversationTitle.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(safeTitle) - Summary.pdf"
        let fileURL = tempFolder.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }
}

// MARK: - Collection View Delegate & Data Source

extension ChatHistoryViewController: UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return transcript.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let message = transcript[indexPath.row]

        if message.isIncoming {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PCIncomingCell", for: indexPath) as? ViewIncomingCell else { return UICollectionViewCell() }
            cell.messageLabel.text = message.text
            cell.nameLabel.text = message.senderName
            cell.editedLabel.isHidden = !message.isEdited
            return cell
        } else {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PCOutCell", for: indexPath) as? ViewOutgoingCell else { return UICollectionViewCell() }
            cell.PCmessageLabel.text = message.text
            cell.editedLabel.isHidden = !message.isEdited
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { _ in
                let currentStatus = self.histconversationData?.messages?[indexPath.row].isHighlighted ?? false
                self.histconversationData?.messages?[indexPath.row].isHighlighted = !currentStatus
                collectionView.reloadItems(at: [indexPath])
                self.notifyDataChanged()
            }
            let edit = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                self.showEditAlert(for: indexPath)
            }
            return UIMenu(title: "", children: [highlight, edit])
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: collectionView.bounds.width, height: 100)
    }
}

// MARK: - Table View Delegate & Data Source

extension ChatHistoryViewController: UITableViewDelegate, UITableViewDataSource, ViewSummaryCardDelegate, ViewNotesCardCellDelegate {

    func didUpdateText(in cell: ViewNotesCardCell) {
        if cell.notesTextView.text != cell.placeholderText {
            self.histconversationData?.notes = cell.notesTextView.text
            self.generatedNotesText = cell.notesTextView.text
            tableView.beginUpdates()
            tableView.endUpdates()
            self.notifyDataChanged()
        }
    }

    func didChangeTitle(text: String) {
        self.conversationTitle = text
        self.histconversationData?.title = text
        self.navigationItem.title = text
        self.notifyDataChanged()
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 6
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 3 { return participantsData.count }
        return 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "PCSummarySectionHeaderCell", for: indexPath) as? ViewSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Conversation Summary"
            cell.headerIcon.image = UIImage(systemName: "list.clipboard")
            cell.selectionStyle = .none
            return cell

        case 1:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "PCSummaryCardCell", for: indexPath) as? ViewSummaryCardCell else { return UITableViewCell() }
            cell.titleTextField.text = conversationTitle
            if let convo = histconversationData {
                cell.dateLabel.text = convo.date
                cell.locationLabel.text = convo.location.isEmpty ? "No Location" : convo.location
                cell.timeLabel.text = convo.startTime
            }
            cell.delegate = self
            return cell

        case 2:
            return tableView.dequeueReusableCell(withIdentifier: "PCParticipantsSummaryHeaderCell", for: indexPath)

        case 3:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "PCParticipantsCardCell", for: indexPath) as? ViewParticipantsCardCell else { return UITableViewCell() }
            cell.configure(with: participantsData[indexPath.row])
            return cell

        case 4:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "PCSummarySectionHeaderCell", for: indexPath) as? ViewSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Notes"
            cell.headerIcon.image = UIImage(systemName: "note.text")
            return cell

        case 5:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "PCNotesCardCell", for: indexPath) as? ViewNotesCardCell else { return UITableViewCell() }
            let displayNotes = histconversationData?.notes ?? generatedNotesText

            if !displayNotes.isEmpty && displayNotes != "Generating summary..." {
                cell.notesTextView.text = displayNotes
                cell.notesTextView.textColor = .label
            } else {
                cell.notesTextView.text = displayNotes
                cell.notesTextView.textColor = .lightGray
            }
            cell.delegate = self
            return cell

        default:
            return UITableViewCell()
        }
    }
}
