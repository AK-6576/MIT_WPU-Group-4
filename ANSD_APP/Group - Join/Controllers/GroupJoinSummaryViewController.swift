//
//  GroupJoinSummaryViewController.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 25/11/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import PDFKit
import FoundationModels
import FirebaseAuth // Apple Intelligence
import CoreLocation
import MapKit

class GroupJoinSummaryViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, GroupJoinNotesCardCellDelegate, CLLocationManagerDelegate {

    @IBOutlet weak var GroupJoinTableView: UITableView!
    @IBOutlet weak var GroupJoinOptionsButton: UIBarButtonItem!

    var conversationTitle = "Session Summary"
    var transcriptMessages: [GroupJoinChatMessage] = []

    // Using the correct data model for group join participants.
    var participantsData: [GroupJoinParticipants] = []

    // State variables for session metadata displayed on the summary card.
    var dateString: String = ""
    var timeString: String = ""
    var locationString: String = "Location Unknown"

    private let model = SystemLanguageModel.default
    private var isProcessing = false
    private(set) var notesText: String = "Generating summary..."
    let locationManager = CLLocationManager()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        generateDateAndTime()
        setupLocation()

        if !transcriptMessages.isEmpty {
            prepareParticipantsFromMessages()
        }

        generateAISummary()
    }

    private func configureUI() {
        view.backgroundColor = .systemGroupedBackground
        GroupJoinTableView.delegate = self
        GroupJoinTableView.dataSource = self
        GroupJoinTableView.separatorStyle = .none
        GroupJoinTableView.backgroundColor = .clear
        GroupJoinTableView.rowHeight = UITableView.automaticDimension
        GroupJoinTableView.estimatedRowHeight = 120
    }

    // MARK: - Actions
    @IBAction func doneButtonTapped(_ sender: Any) {
        self.view.endEditing(true)
        self.saveSessionToHistory()
        // Returns to the Home storyboard after saving the session to history.
        let storyboard = UIStoryboard(name: "Home", bundle: nil)
        let homeVC = storyboard.instantiateViewController(withIdentifier: "Home")

        let navController = UINavigationController(rootViewController: homeVC)
        navController.isNavigationBarHidden = false
        navController.modalPresentationStyle = .fullScreen

        if let window = self.view.window {
            UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: {
                window.rootViewController = navController
            }, completion: nil)
            window.makeKeyAndVisible()
        }
    }

    @IBAction func shareButtonTapped(_ sender: UIBarButtonItem) {
        shareAsPDF()
    }

    // MARK: - Logic
    private func prepareParticipantsFromMessages() {
        let placeholders: Set<String> = ["system", "listening...", "identifying…", "identifying..."]
        var seenIDs = [String: Int]() // senderID -> index
        var result = [GroupJoinParticipants]()

        for msg in transcriptMessages {
            let trimmedName = msg.sender.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerName = trimmedName.lowercased()
            if placeholders.contains(lowerName) { continue }

            let key = msg.senderID.isEmpty ? lowerName : msg.senderID

            if let idx = seenIDs[key] {
                result[idx] = GroupJoinParticipants(name: trimmedName, senderID: msg.senderID, summary: "Waiting for analysis...", avatarTitle: "")
            } else {
                seenIDs[key] = result.count
                result.append(GroupJoinParticipants(name: trimmedName, senderID: msg.senderID, summary: "Waiting for analysis...", avatarTitle: ""))
            }
        }

        participantsData = result
        GroupJoinTableView.reloadData()
    }

    private func generateAISummary() {
        guard !transcriptMessages.isEmpty else {
            notesText = "No transcript."
            GroupJoinTableView.reloadData()
            return
        }

        isProcessing = true
        let text = transcriptMessages.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")

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
                \(text)
                """
                // Trigger AI text cleanup for a finalized speech bubble.
                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt)

                await MainActor.run {
                    self.parseAIResponse(response.content)
                    self.isProcessing = false
                    self.GroupJoinTableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.notesText = "Error: \(error.localizedDescription)"
                    self.isProcessing = false
                    self.GroupJoinTableView.reloadData()
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
            if line.contains("NOTES:") { currentSection = "NOTES"; continue }
            if line.contains("SUMMARY_") && line.contains(":") {
                let start = line.index(line.startIndex, offsetBy: 8)
                if let end = line.firstIndex(of: ":") {
                    let name = String(line[start..<end])
                    currentSection = name
                    continue
                }
            }

            if currentSection == "NOTES" { notesBuffer += line + "\n" } else if !currentSection.isEmpty {
                let existing = participantSummaries[currentSection] ?? ""
                participantSummaries[currentSection] = existing + line + " "
            }
        }

        self.notesText = notesBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.notesText.isEmpty { self.notesText = text }

        for (name, summary) in participantSummaries {
            if let index = participantsData.firstIndex(where: { name.localizedCaseInsensitiveContains($0.name) || $0.name.localizedCaseInsensitiveContains(name) }) {
                var cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanSummary.hasPrefix("-") || cleanSummary.hasPrefix("•") {
                    cleanSummary.removeFirst()
                    cleanSummary = cleanSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                participantsData[index].summary = cleanSummary
            }
        }
    }

    // MARK: - TableView
    func numberOfSections(in tableView: UITableView) -> Int { 6 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 3 ? participantsData.count : 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinSummarySectionHeaderCell", for: indexPath) as? GroupJoinSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Conversation Summary"
            cell.headerIcon.image = UIImage(systemName: "list.clipboard")
            cell.selectionStyle = .none
            return cell

        case 1: // Main Card
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinSummaryCardCell", for: indexPath) as? GroupJoinSummaryCardCell else { return UITableViewCell() }
            cell.configure(title: conversationTitle, date: dateString, time: timeString, location: locationString)
            cell.selectionStyle = .none
            return cell

        case 2: // Header Participants
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinSummarySectionHeaderCell", for: indexPath) as? GroupJoinSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Participants Summary"
            cell.headerIcon.image = UIImage(systemName: "person.2.fill")
            cell.selectionStyle = .none
            return cell

        case 3: // LIST OF PARTICIPANTS (Using Card Cell)
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinParticipantsCardCell", for: indexPath) as? GroupJoinParticipantsCardCell else { return UITableViewCell() }
            let data = participantsData[indexPath.row]
            cell.configure(with: data)
            cell.selectionStyle = .none
            return cell

        case 4:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinSummarySectionHeaderCell", for: indexPath) as? GroupJoinSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Notes"
            cell.headerIcon.image = UIImage(systemName: "note.text")
            cell.selectionStyle = .none
            return cell

        case 5: // Notes Card
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinNotesCardCell", for: indexPath) as? GroupJoinNotesCardCell else { return UITableViewCell() }
            cell.notesTextView.text = self.notesText
            cell.delegate = self
            cell.selectionStyle = .none
            return cell

        default: return UITableViewCell()
        }
    }

    // MARK: - Helpers (Date, Location, PDF)
    private func generateDateAndTime() {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateString = dateFormatter.string(from: now)
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        timeString = timeFormatter.string(from: now)
    }

    private func setupLocation() {
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        if let request = MKReverseGeocodingRequest(location: location) {
            request.getMapItems { mapItems, _ in
                if let place = mapItems?.first {
                    self.locationString = [place.addressRepresentations?.cityName, place.addressRepresentations?.regionName].compactMap { $0 }.joined(separator: ", ")
                    self.locationManager.stopUpdatingLocation()
                    DispatchQueue.main.async {
                        self.GroupJoinTableView.reloadSections(IndexSet(integer: 1), with: .none)
                    }
                }
            }
        }
    }

    private func shareAsPDF() {
        let pdfMetaData = [kCGPDFContextCreator: "Sāmwaad", kCGPDFContextTitle: conversationTitle]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.2, height: 841.8), format: format)

        let data = renderer.pdfData { (context) in
            context.beginPage()
            let titleAttr = [NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 24)]
            let bodyAttr = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 12)]

            conversationTitle.draw(at: CGPoint(x: 40, y: 40), withAttributes: titleAttr)

            var text = "Date: \(dateString) | \(timeString)\nLocation: \(locationString)\n\n"
            text += "--- NOTES ---\n\(notesText)\n\n"
            text += "--- PARTICIPANTS ---\n"
            for p in participantsData {
                text += "\(p.name):\n\(p.summary)\n\n"
            }

            text.draw(in: CGRect(x: 40, y: 80, width: 515, height: 740), withAttributes: bodyAttr)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionSummary.pdf")
        try? data.write(to: url)

        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = vc.popoverPresentationController {
            popover.barButtonItem = GroupJoinOptionsButton
        }
        present(vc, animated: true)
    }

    func didUpdateText(in cell: GroupJoinNotesCardCell) {
        notesText = cell.notesTextView.text
        GroupJoinTableView.performBatchUpdates(nil)
        if let indexPath = GroupJoinTableView.indexPath(for: cell) {
            GroupJoinTableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
        }
    }
    func didChangeTitle(text: String) { conversationTitle = text }

    // MARK: - Save to History
    private func saveSessionToHistory() {
        // SAFETY: If time or date is empty, generate it now
        if dateString.isEmpty || timeString.isEmpty {
            generateDateAndTime()
        }

        // Converts participant data to the history-compatible Participant model.
        let historyParticipants: [Participant] = participantsData.map { person in
            Participant(name: person.name, summary: person.summary, image: "person.circle.fill")
        }

        // Maps transcript messages to the generic Message model for history storage.
        let historyMessages: [Message] = transcriptMessages.map { msg in
            Message(
                id: UUID(),
                text: msg.text,
                senderId: msg.sender,
                senderName: msg.sender,
                isIncoming: msg.isIncoming,
                timestamp: Date(),
                isHighlighted: false,
                isEdited: false
            )
        }

        // Falls back to a default message if the AI summary is not yet available.
        let finalNotes = self.notesText == "Generating summary..." ? "No notes generated." : self.notesText
        let cleanOneLiner = finalNotes.replacingOccurrences(of: "\n", with: " ")

        // Packages the full session data into a Conversation object for persistent storage.
        let newConversation = Conversation(
            id: UUID().uuidString,
            title: self.conversationTitle,
            details: cleanOneLiner,     // Matches 'details' in ConversationDataModels.swift
            date: self.dateString,
            startTime: self.timeString,
            endTime: self.timeString,
            location: self.locationString,
            category: "Group-Join",
            icon: "person.bubble",
            info: nil,                  // Matches 'info' in @Model
            calendarDate: Date(),          // Matches 'calendarDate' in @Model
            notes: finalNotes,          // Matches 'notes' in @Model
            isPinned: false,            // Matches 'isPinned' in @Model
            ownerUID: Auth.auth().currentUser?.uid ?? "",
            participants: historyParticipants, // Matches relationship
            messages: historyMessages          // Matches relationship
        )
        // 5. Send to DataManager to permanently save!
        DataManager.shared.addConversation(newConversation)

        // 6. Sync full transcript to Firebase for persistent history
        FirebaseManager.shared.saveFullConversation(newConversation)

        print("Success: Saved Group Join session \(self.conversationTitle) to History!")
    }
}
