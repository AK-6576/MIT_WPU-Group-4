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
import FirebaseAuth
import CoreLocation

class GroupJoinSummaryViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, GroupJoinNotesCardCellDelegate, CLLocationManagerDelegate {

    @IBOutlet weak var GroupJoinTableView: UITableView!
    @IBOutlet weak var GroupJoinOptionsButton: UIBarButtonItem!

    var conversationTitle = "Session Summary"
    var transcriptMessages: [GroupJoinChatMessage] = []
    var participantsData: [GroupJoinParticipants] = []

    var dateString: String = ""
    var timeString: String = ""
    var locationString: String = "Locating..."
    
    var sessionStartTime: Date?
    var sessionEndTime: Date?

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

    // MARK: - Data Preparation
    private func prepareParticipantsFromMessages() {
        let placeholders: Set<String> = ["system", "listening...", "identifying…", "identifying..."]
        var seenIDs = [String: Int]()
        var result = [GroupJoinParticipants]()

        for msg in transcriptMessages {
            let trimmedName = msg.sender.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerName = trimmedName.lowercased()
            if placeholders.contains(lowerName) { continue }

            let key = msg.senderID.isEmpty ? lowerName : msg.senderID

            if let idx = seenIDs[key] {
                result[idx] = GroupJoinParticipants(name: trimmedName, senderID: msg.senderID, summary: "Analysing...", avatarTitle: "")
            } else {
                seenIDs[key] = result.count
                result.append(GroupJoinParticipants(name: trimmedName, senderID: msg.senderID, summary: "Analysing...", avatarTitle: ""))
            }
        }

        participantsData = result
        GroupJoinTableView.reloadData()
    }

    // MARK: - AI Summary
    private func generateAISummary() {
        guard !transcriptMessages.isEmpty else {
            notesText = "No transcript available."
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

                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt)

                await MainActor.run {
                    self.parseAIResponse(response.content)
                    self.isProcessing = false
                    self.GroupJoinTableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.notesText = "Summary unavailable."
                    // Mark any still-pending participants
                    for i in self.participantsData.indices {
                        if self.participantsData[i].summary == "Analysing..." {
                            self.participantsData[i].summary = "Summary unavailable."
                        }
                    }
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
            if line.contains("NOTES:") {
                currentSection = "NOTES"
                continue
            }
            if line.contains("SUMMARY_") && line.contains(":") {
                let start = line.index(line.startIndex, offsetBy: 8)
                if let end = line.firstIndex(of: ":") {
                    let name = String(line[start..<end])
                    currentSection = name
                    continue
                }
            }
            if currentSection == "NOTES" {
                notesBuffer += line + "\n"
            } else if !currentSection.isEmpty {
                let existing = participantSummaries[currentSection] ?? ""
                participantSummaries[currentSection] = existing + line + " "
            }
        }

        self.notesText = notesBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.notesText.isEmpty { self.notesText = text }

        for (name, summary) in participantSummaries {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = participantsData.firstIndex(where: {
                trimmedName.localizedCaseInsensitiveContains($0.name.trimmingCharacters(in: .whitespacesAndNewlines)) ||
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveContains(trimmedName)
            }) {
                var cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanSummary.hasPrefix("-") || cleanSummary.hasPrefix("•") {
                    cleanSummary.removeFirst()
                    cleanSummary = cleanSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !cleanSummary.isEmpty {
                    participantsData[index].summary = cleanSummary
                }
            }
        }

        // Replace any remaining placeholder with a clear fallback
        for i in participantsData.indices {
            if participantsData[i].summary == "Analysing..." {
                participantsData[i].summary = "No summary available."
            }
        }
    }

    // MARK: - TableView
    func numberOfSections(in tableView: UITableView) -> Int { 6 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 3 ? max(participantsData.count, 1) : 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinSummarySectionHeaderCell", for: indexPath) as? GroupJoinSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Conversation Summary"
            cell.headerIcon.image = UIImage(systemName: "list.clipboard")
            cell.selectionStyle = .none
            return cell

        case 1:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinSummaryCardCell", for: indexPath) as? GroupJoinSummaryCardCell else { return UITableViewCell() }
            cell.configure(title: conversationTitle, date: dateString, time: timeString, location: locationString)
            cell.selectionStyle = .none
            return cell

        case 2:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinSummarySectionHeaderCell", for: indexPath) as? GroupJoinSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Participants Summary"
            cell.headerIcon.image = UIImage(systemName: "person.2.fill")
            cell.selectionStyle = .none
            return cell

        case 3:
            guard !participantsData.isEmpty else {
                let cell = UITableViewCell()
                cell.textLabel?.text = "No participants detected."
                cell.textLabel?.textColor = .secondaryLabel
                cell.selectionStyle = .none
                return cell
            }
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinParticipantsCardCell", for: indexPath) as? GroupJoinParticipantsCardCell else { return UITableViewCell() }
            cell.configure(with: participantsData[indexPath.row])
            cell.selectionStyle = .none
            return cell

        case 4:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinSummarySectionHeaderCell", for: indexPath) as? GroupJoinSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Notes"
            cell.headerIcon.image = UIImage(systemName: "note.text")
            cell.selectionStyle = .none
            return cell

        case 5:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "GroupJoinNotesCardCell", for: indexPath) as? GroupJoinNotesCardCell else { return UITableViewCell() }
            cell.notesTextView.text = self.notesText
            cell.delegate = self
            cell.selectionStyle = .none
            return cell

        default:
            return UITableViewCell()
        }
    }

    // MARK: - Date & Location
    private func generateDateAndTime() {
        let start = sessionStartTime ?? Date()
        let end = sessionEndTime ?? Date()

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        dateString = dateFormatter.string(from: start)

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        
        let startStr = timeFormatter.string(from: start)
        let endStr = timeFormatter.string(from: end)
        timeString = "\(startStr) - \(endStr)"
    }

    private func setupLocation() {
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        locationManager.stopUpdatingLocation()

        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self, error == nil, let place = placemarks?.first else {
                DispatchQueue.main.async { self?.locationString = "Location unavailable" }
                return
            }
            let city = place.locality ?? place.subAdministrativeArea ?? ""
            let region = place.administrativeArea ?? ""
            let parts = [city, region].filter { !$0.isEmpty }
            let resolved = parts.isEmpty ? "Location unavailable" : parts.joined(separator: ", ")
            DispatchQueue.main.async {
                self.locationString = resolved
                self.GroupJoinTableView.reloadSections(IndexSet(integer: 1), with: .none)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationString = "Location unavailable"
        DispatchQueue.main.async {
            self.GroupJoinTableView.reloadSections(IndexSet(integer: 1), with: .none)
        }
    }

    // MARK: - PDF Share
    private func shareAsPDF() {
        let pdfMetaData = [kCGPDFContextCreator: "Sāmwaad", kCGPDFContextTitle: conversationTitle]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.2, height: 841.8), format: format)

        let data = renderer.pdfData { context in
            context.beginPage()
            let titleAttr: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 24)]
            let bodyAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]

            conversationTitle.draw(at: CGPoint(x: 40, y: 40), withAttributes: titleAttr)

            var body = "Date: \(dateString) | \(timeString)\nLocation: \(locationString)\n\n"
            body += "--- NOTES ---\n\(notesText)\n\n"
            body += "--- PARTICIPANTS ---\n"
            for p in participantsData {
                body += "\(p.name):\n\(p.summary)\n\n"
            }
            body.draw(in: CGRect(x: 40, y: 80, width: 515, height: 740), withAttributes: bodyAttr)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionSummary.pdf")
        try? data.write(to: url)

        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = vc.popoverPresentationController {
            popover.barButtonItem = GroupJoinOptionsButton
        }
        present(vc, animated: true)
    }

    // MARK: - Delegate
    func didUpdateText(in cell: GroupJoinNotesCardCell) {
        notesText = cell.notesTextView.text
        GroupJoinTableView.performBatchUpdates(nil)
        if let indexPath = GroupJoinTableView.indexPath(for: cell) {
            GroupJoinTableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
        }
    }

    func didChangeTitle(text: String) {
        conversationTitle = text
    }

    // MARK: - Save to History
    private func saveSessionToHistory() {
        if dateString.isEmpty || timeString.isEmpty {
            generateDateAndTime()
        }

        let historyParticipants: [Participant] = participantsData.map {
            Participant(name: $0.name, summary: $0.summary, image: "person.circle.fill")
        }

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

        let finalNotes = (notesText == "Generating summary..." || notesText == "Analysing...") ? "No notes generated." : notesText
        let cleanOneLiner = finalNotes.replacingOccurrences(of: "\n", with: " ")

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let startStr = timeFormatter.string(from: sessionStartTime ?? Date())
        let endStr = timeFormatter.string(from: sessionEndTime ?? Date())

        let newConversation = Conversation(
            id: UUID().uuidString,
            title: conversationTitle,
            details: cleanOneLiner,
            date: dateString,
            startTime: startStr,
            endTime: endStr,
            location: locationString,
            category: "Group-Join",
            icon: "person.bubble",
            info: nil,
            calendarDate: sessionStartTime ?? Date(),
            notes: finalNotes,
            isPinned: false,
            ownerUID: Auth.auth().currentUser?.uid ?? "",
            participants: historyParticipants,
            messages: historyMessages
        )

        DataManager.shared.addConversation(newConversation)
        FirebaseManager.shared.saveFullConversation(newConversation)
        print("Success: Saved Group Join session \(conversationTitle) to History!")
    }
}
