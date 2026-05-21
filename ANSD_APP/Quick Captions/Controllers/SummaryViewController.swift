//
//  SummaryViewController.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 25/11/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import PDFKit
import FoundationModels
import FirebaseAuth // Apple Intelligence

class SummaryViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, QuickCaptionsNotesCardCellDelegate, QuickCaptionsSummaryCardDelegate {

    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var shareButton: UIBarButtonItem!

    // MARK: - Data Sources
    var conversationTitle = "Conversation 1"
    var rawTranscriptText: String = ""
    var rawMessages: [QuickCaptionsChat] = []
    var participantsData: [QuickCaptionsParticipantData] = []

    // MARK: - Header Data
    var dateString: String = ""
    var timeString: String = "" // Acts as End Time
    var startTimeString: String = ""
    var locationString: String = ""

    // MARK: - AI State
    private let model = SystemLanguageModel.default
    private var isProcessing = false
    private var notesContent: String = "Generating summary..."

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemGroupedBackground

        guard tableView != nil else {
            print("Error: Critical TableView is not connected in Storyboard")
            return
        }

        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120

        // Connect Share Button
        if let shareBtn = shareButton {
            shareBtn.target = self
            shareBtn.action = #selector(shareButtonTapped)
        }

        // Dismiss Keyboard Gesture
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        generateDateAndTime()
        generateAISummary()
    }

    private func generateDateAndTime() {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        dateString = dateFormatter.string(from: now)

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        timeString = timeFormatter.string(from: now)
    }

    // MARK: - AI Logic
    private func generateAISummary() {
        guard !rawTranscriptText.isEmpty else {
            self.notesContent = "No transcript available."
            self.tableView.reloadData()
            return
        }

        isProcessing = true
        self.tableView.reloadData()

        Task {
            do {
                var participantPrompts = ""
                for person in participantsData {
                    let safeName = person.name.replacingOccurrences(of: " ", with: "_").uppercased()
                    participantPrompts += """
                    Step: Write a section strictly labeled "PARTICIPANT_\(safeName):" summarizing what \(person.name) said in their own perspective using the third person (e.g., "\(person.name) believes that..."). Do not use dashes (-) for listing things.

                    """
                }
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

                STRICT CONSTRAINTS:
                - The acoustic separation system frequently creates "ghost persons" by assigning multiple speaker numbers (e.g., "Speaker 2", "Speaker 3") to a single physical person (e.g., "Cobb").
                - Read the context carefully to figure out who is who. If it's clear someone is just another name for an existing speaker, you will note this mapping.

                Step 1: Write a section strictly labeled "GHOST_MERGES:". For every ghost person identified (like Speaker 3 being Cobb), write "GhostName = RealName" on a new line (e.g., "Speaker 3 = Cobb"). If none, write "None".

                Step 2: Write a section strictly labeled "NOTES:" summarizing the key takeaways and action items in short, clean sentences. Provide each point on a new line as a standalone sentence.

                \(participantPrompts)

                TRANSCRIPT:
                \(rawTranscriptText)
                """

                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt)

                await MainActor.run {
                    self.parseAIResponse(response.content)
                    self.isProcessing = false
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.notesContent = "Could not generate summary. Error: \(error.localizedDescription)"
                    self.isProcessing = false
                    self.tableView.reloadData()
                }
            }
        }
    }

    private func parseAIResponse(_ text: String) {
        let components = text.components(separatedBy: CharacterSet.newlines)

        var currentSection = ""
        var notesBuffer = ""
        var ghostMappings: [String: String] = [:]

        // Create buffers for each participant
        var participantBuffers: [String: String] = [:]
        for person in participantsData {
            let safeName = person.name.replacingOccurrences(of: " ", with: "_").uppercased()
            participantBuffers[safeName] = ""
        }

        for line in components {
            // Check for Headers
            if line.contains("GHOST_MERGES:") {
                currentSection = "MERGES"
                continue
            }
            if line.contains("NOTES:") {
                currentSection = "NOTES"
                continue
            }

            // Check for Participant Headers Dynamically
            var isParticipantHeader = false
            for person in participantsData {
                let safeName = person.name.replacingOccurrences(of: " ", with: "_").uppercased()
                if line.contains("PARTICIPANT_\(safeName):") {
                    currentSection = safeName
                    // DO NOT continue, let it switch context
                    isParticipantHeader = true
                    break
                }
            }
            if isParticipantHeader { continue }

            // Append content
            if currentSection == "MERGES" {
                if line.contains("=") && !line.lowercased().contains("none") {
                    let parts = line.components(separatedBy: "=")
                    if parts.count == 2 {
                        let ghost = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let real = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        ghostMappings[ghost] = real
                    }
                }
            } else if currentSection == "NOTES" {
                notesBuffer += line + "\n"
            } else if participantBuffers[currentSection] != nil {
                participantBuffers[currentSection]? += line + "\n"
            }
        }

        self.notesContent = notesBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.notesContent.isEmpty { self.notesContent = text }

        // Format summaries
        for i in 0..<participantsData.count {
            let person = participantsData[i]
            let safeName = person.name.replacingOccurrences(of: " ", with: "_").uppercased()
            if let rawSummary = participantBuffers[safeName], !rawSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var cleanSummary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanSummary.hasPrefix("-") || cleanSummary.hasPrefix("•") {
                    cleanSummary.removeFirst()
                    cleanSummary = cleanSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                participantsData[i].summary = cleanSummary
            } else {
                participantsData[i].summary = "No summary available."
            }
        }

        // APPLY GHOST MERGES
        var validParticipants: [QuickCaptionsParticipantData] = []
        var droppedGhostNames: Set<String> = []

        // Process mappings
        for (ghostName, realName) in ghostMappings {
            // Find ghost in participantsData
            if let ghostIndex = participantsData.firstIndex(where: { $0.name.lowercased() == ghostName.lowercased() }),
               let realIndex = participantsData.firstIndex(where: { $0.name.lowercased() == realName.lowercased() }) {

                let ghostSummary = participantsData[ghostIndex].summary
                if ghostSummary != "No summary available.", !ghostSummary.isEmpty {
                    // Append ghost summary to real summary
                    let currentRealSummary = participantsData[realIndex].summary
                    if currentRealSummary == "No summary available." || currentRealSummary.isEmpty {
                        participantsData[realIndex].summary = ghostSummary
                    } else {
                        participantsData[realIndex].summary = currentRealSummary + "\n" + ghostSummary
                    }
                }
                droppedGhostNames.insert(participantsData[ghostIndex].name)

                // Update rawMessages so history is clean
                let theGhostName = participantsData[ghostIndex].name
                let theRealName = participantsData[realIndex].name
                let theRealSenderID = participantsData[realIndex].senderID

                for m in 0..<rawMessages.count where rawMessages[m].sender == theGhostName {
                    rawMessages[m].sender = theRealName
                    rawMessages[m].senderID = theRealSenderID
                }
            }
        }

        // Filter out ghosts and empty summaries
        for p in participantsData where !droppedGhostNames.contains(p.name) {
            validParticipants.append(p)
        }

        self.participantsData = validParticipants
    }

    // MARK: - Actions
    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @IBAction func backTapped(_ sender: Any) {
        self.saveSessionToHistory()
        self.view.endEditing(true)
        // Return to Home Storyboard
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

    @IBAction func shareButtonTapped(_ sender: Any) {
        shareAsPDF()
    }

    // MARK: - PDF Generation
    private func shareAsPDF() {
        var pdfContent = "Conversation Title: \(conversationTitle)\n"
        pdfContent += "\(dateString) | \(timeString) | \(locationString)\n\n"

        pdfContent += "--- NOTES ---\n"
        pdfContent += "\(notesContent)\n\n"

        pdfContent += "--- PARTICIPANTS ---\n"
        for person in participantsData {
            pdfContent += "\(person.name):\n\(person.summary)\n\n"
        }

        if let pdfURL = createPDF(from: pdfContent) {
            let activityVC = UIActivityViewController(activityItems: [pdfURL], applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
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
        let fileName = "\(conversationTitle) - Summary.pdf"
        let fileURL = tempFolder.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            print("Error generating PDF: \(error)")
            return nil
        }
    }

    // MARK: - TableView Data Source

    func numberOfSections(in tableView: UITableView) -> Int {
        return 6
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0, 1, 2: return 1
        case 3: return participantsData.count
        case 4, 5: return 1
        default: return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {

        switch indexPath.section {

        // MARK: SECTION 0 - Header: "Conversation Summary"
        case 0:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "SummarySectionHeaderCell", for: indexPath) as? QuickCaptionsSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Conversation Summary"
            cell.headerIcon.image = UIImage(systemName: "list.clipboard")
            cell.selectionStyle = .none
            return cell

        // MARK: SECTION 1 - Card: Date, Time, Location
        case 1:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "SummaryCardCell", for: indexPath) as? QuickCaptionsSummaryCardCell else { return UITableViewCell() }

            cell.configure(
                title: self.conversationTitle,
                date: self.dateString,
                time: self.timeString,
                location: self.locationString
            )

            cell.delegate = self

            cell.selectionStyle = .none
            return cell

        // MARK: SECTION 2 - Header: "Participants Summary"
        case 2:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "SummarySectionHeaderCell", for: indexPath) as? QuickCaptionsSummarySectionHeaderCell else { return UITableViewCell() }

            cell.headerLabel.text = "Participants Summary"
            cell.headerIcon.image = UIImage(systemName: "person.2.fill")
            cell.selectionStyle = .none
            return cell

        // MARK: SECTION 3 - List: Participant Rows
        case 3:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "ParticipantCardCell", for: indexPath) as? QuickCaptionsParticipantCardCell else { return UITableViewCell() }
            let participant = participantsData[indexPath.row]

            cell.configure(with: participant)

            cell.selectionStyle = .none
            return cell

        // MARK: SECTION 4 - Header: "Notes"
        case 4:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "SummarySectionHeaderCell", for: indexPath) as? QuickCaptionsSummarySectionHeaderCell else { return UITableViewCell() }
            cell.headerLabel.text = "Notes"
            cell.headerIcon.image = UIImage(systemName: "note.text")
            cell.selectionStyle = .none
            return cell

        // MARK: SECTION 5 - Card: Key Takeaways
        case 5:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "NotesCardCell", for: indexPath) as? QuickCaptionsNotesCardCell else { return UITableViewCell() }
            cell.notesTextView.text = self.notesContent
            cell.delegate = self
            cell.selectionStyle = .none
            return cell

        default:
            return UITableViewCell()
        }
    }

    // MARK: - Delegates
    func didUpdateText(in cell: QuickCaptionsNotesCardCell) {
        self.notesContent = cell.notesTextView.text
        tableView.performBatchUpdates(nil, completion: nil)

        if let indexPath = tableView.indexPath(for: cell) {
            tableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
        }
    }

    func didChangeTitle(text: String) {
        self.conversationTitle = text
        // If the user manually changes the title, reset the auto-incrementing counter back to 1
        if !text.starts(with: "Conversation ") {
            UserDefaults.standard.set(1, forKey: "quickCaptionSessionCounter")
        }
    }

    // MARK: - Save to History Translator

    private func saveSessionToHistory() {
        // SAFETY: If time or date is empty, generate it now
        if dateString.isEmpty || timeString.isEmpty {
            generateDateAndTime()
        }

        // 1. Map Participants to History Format
        let historyParticipants: [Participant] = participantsData.map { person in
            Participant(name: person.name, summary: person.summary, image: "person.circle.fill")
        }

        // 2. Map Transcript back into Message Bubbles using the rich rawMessages array
        var historyMessages: [Message] = []

        for chat in rawMessages {
            let msg = Message(
                id: UUID(),
                text: chat.text,
                senderId: chat.senderID,
                senderName: chat.sender,
                isIncoming: chat.isIncoming, // Pass the exact flag from the diarizer
                timestamp: Date(),
                isHighlighted: false,
                isEdited: false
            )
            historyMessages.append(msg)
        }

        // 3. Grab the AI notes (or fallback text) and format for the 1-2 liner description
        let finalNotes = self.notesContent == "Generating summary..." ? "No notes generated." : self.notesContent
        let cleanOneLiner = finalNotes.replacingOccurrences(of: "\n", with: " ") // Removes enters for a clean preview

        // 4. Package everything into a Conversation Object (SwiftData Model parameters)
        let newConversation = Conversation(
            id: UUID().uuidString,
            title: self.conversationTitle,
            details: cleanOneLiner,
            date: self.dateString,
            startTime: self.startTimeString.isEmpty ? self.timeString : self.startTimeString,
            endTime: self.timeString,
            location: self.locationString,
            category: "Quick Captions",
            icon: "waveform",
            calendarDate: Date(), // <--- Feed the current date so sorting works
            notes: finalNotes,
            ownerUID: Auth.auth().currentUser?.uid ?? "",
            participants: historyParticipants,
            messages: historyMessages
        )

        // 5. Send to DataManager to permanently save!
        let currentUID = Auth.auth().currentUser?.uid ?? "NIL_UID"
        print("DEBUG: Saving Conversation with UID: \(currentUID) | Title: \(newConversation.title)")
        DataManager.shared.addConversation(newConversation)

        // 6. Sync full transcript to Firebase for persistent history
        FirebaseManager.shared.saveFullConversation(newConversation)

        print("Success: Saved \(self.conversationTitle) to History!")
    }
}
