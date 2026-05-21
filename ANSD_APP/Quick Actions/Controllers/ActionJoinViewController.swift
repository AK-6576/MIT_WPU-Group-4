//
//  ActionJoinViewController.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 05/02/26.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import Speech
import AVFoundation
import Combine
import FoundationModels
import FirebaseAuth
import FirebaseDatabase

class ActionJoinViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, SFSpeechRecognizerDelegate {

    // MARK: - Outlets
    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet weak var micButton: UIButton!
    @IBOutlet weak var pauseButton: UIButton!
    @IBOutlet weak var endButton: UIButton!

    // MARK: - Properties
    var category: String = "Family"
    var roomCode: String?
    var sessionTitle: String = "Session" {
        didSet {
            self.title = sessionTitle
        }
    }
    var participantNames: [String] = []
    var hostUID: String?

    // Core Managers
    private let firebase = FirebaseManager.shared
    private let cleanupManager = TextCleanupManager()
    private let model = SystemLanguageModel.default

    // State
    var messages: [GroupJoinChatMessage] = [] // Reusing model from Group Join for standard bubble tracking
    var isRecording = false
    var isRestarting = false
    var consumedTranscriptOffset = 0
    var cleanedMessageIndices = Set<Int>()
    var isSessionEnded = false
    var myName: String {
        UserDefaults.standard.string(forKey: "user_first_name") ?? UIDevice.current.name
    }

    var currentUserID: String {
        let rawID = Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "UnknownUser"
        return rawID.components(separatedBy: CharacterSet(charactersIn: ".#$[]")).joined(separator: "_")
    }

    // Speech Engine Properties
    private var speechRecognizer = SFSpeechRecognizer(locale: LanguageManager.shared.currentLocale)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let MAX_BUBBLE_CHAR_LIMIT = 180

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = sessionTitle

        collectionView.delegate = self
        collectionView.dataSource = self
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
            layout.minimumLineSpacing = 12
        }

        setupSpeech()
        setupAudioSession()
        setupParticipantsButton()

        startFirebaseSession()

        NotificationCenter.default.addObserver(self, selector: #selector(handleLanguageChange), name: .languageDidChange, object: nil)
    }

    @objc private func handleLanguageChange() {
        speechRecognizer = SFSpeechRecognizer(locale: LanguageManager.shared.currentLocale)
    }

    private func setupParticipantsButton() {
        let participantsButton = UIBarButtonItem(
            image: UIImage(systemName: "person.2.fill"),
            style: .plain,
            target: self,
            action: #selector(showParticipantsViewer)
        )
        navigationItem.rightBarButtonItem = participantsButton
    }

    @objc private func showParticipantsViewer() {
        let viewerVC = ParticipantsViewController()
        viewerVC.viewerMode = true
        viewerVC.viewerParticipantNames = self.participantNames
        viewerVC.viewerRoomCode = self.roomCode
        let nav = UINavigationController(rootViewController: viewerVC)
        if let sheet = nav.sheetPresentationController { sheet.detents = [.medium(), .large()] }
        present(nav, animated: true)
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            print("Audio Session Error: \(error)")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Mic is now muted by default - user must tap mic button to start.

        // Set presence online
        if let code = roomCode {
            firebase.setPresence(roomCode: code, userName: myName)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRecording()
        // Remove presence
        if let code = roomCode {
            firebase.removePresence(roomCode: code, userName: myName)
        }
    }

    func setupSpeech() {
        micButton.isEnabled = false
        pauseButton.isEnabled = true
        endButton.isEnabled = true

        // Initial muted state visuals
        micButton.setImage(UIImage(systemName: "mic.slash.fill"), for: .normal)
        micButton.tintColor = .label

        speechRecognizer?.delegate = self
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                self.micButton.isEnabled = (authStatus == .authorized)
            }
        }
    }

    // MARK: - Firebase Integration
    private func startFirebaseSession() {
        guard let code = roomCode else { return }

        // Define a unified completion handler to reduce duplication
        let handleHostFound: (String?) -> Void = { [weak self] targetUID in
            guard let self = self else { return }

            if let uid = targetUID {
                // Host ID found (either explicitly passed or found in registry)
                let isMeHost = (uid == self.currentUserID)
                self.firebase.setupSession(hostUID: uid, conversationID: code, isHost: isMeHost)
                self.firebase.linkConversationToJoiner(hostUID: uid, conversationID: code, conversationTitle: self.sessionTitle)
            } else {
                // No host found anywhere -> Register myself as the host
                let hostID = self.currentUserID
                self.firebase.registerRoom(code: code, hostUID: hostID)
                self.firebase.setupSession(hostUID: hostID, conversationID: code, isHost: true)
                self.firebase.linkConversationToJoiner(hostUID: hostID, conversationID: code, conversationTitle: self.sessionTitle)
            }

            self.setupFirebaseObservers()
        }

        // PRIORITIZE: If the Quick Action already told us who the host is, use it!
        if let explicitHost = self.hostUID, !explicitHost.isEmpty {
            // print("DEBUG: ActionJoin - Using explicit hostUID from model: \(explicitHost)")
            handleHostFound(explicitHost)
        } else {
            // FALLBACK: Query the room_registry (Legacy/Other flows)
            // print("DEBUG: ActionJoin - Querying room_registry for code: \(code)")
            firebase.findHostID(for: code, completion: handleHostFound)
        }
    }

    private func setupFirebaseObservers() {
        // print("DEBUG: ActionJoin - Setting up Firebase observers")

        firebase.observeSessionStatus { [weak self] status in
            guard let self = self else { return }
            print("DEBUG: ActionJoin - Session status: \(status)")
            if status == "ended" {
                self.handleGlobalSessionEnd()
            }
        }

        firebase.observeMessages { [weak self] data in
            guard let self = self else { return }
            guard let text = data["text"] as? String,
                  let sender = data["sender"] as? String,
                  let senderID = data["senderID"] as? String else {
                // print("DEBUG: ActionJoin - Received malformed message data: \(data)")
                return
            }

            // print("DEBUG: ActionJoin - Received message from \(sender) (\(senderID)): \(text.prefix(30))...")

            // Deduplication
            if senderID == self.currentUserID {
                let lastFinalized = self.messages.last(where: { !$0.isIncoming && $0.text != "..." && $0.text != "Listening..." })
                if let last = lastFinalized, last.text == text {
                    // print("DEBUG: ActionJoin - Skipping duplicate self-message")
                    return
                }
            }

            DispatchQueue.main.async {
                self.processIncomingMessage(text: text, sender: sender, senderID: senderID)
            }
        }
    }

    private func processIncomingMessage(text: String, sender: String, senderID: String) {
        // Deduplication: Check if the message is already in our list (matching text and sender)
        if messages.contains(where: { $0.text == text && $0.senderID == senderID }) {
            return
        }

        let isListeningPresent = (self.messages.last?.text == "Listening..." || self.messages.last?.text == "...") && !self.messages.last!.isIncoming

        if isListeningPresent { self.removeListeningBubble() }

        let msg = GroupJoinChatMessage(text: text, isIncoming: (senderID != self.currentUserID), sender: sender, senderID: senderID)
        self.messages.append(msg)
        self.reloadDataAndScroll()

        if isListeningPresent && self.isRecording { self.addListeningBubble() }
    }

    // MARK: - Actions
    @IBAction func micButtonTapped(_ sender: UIButton) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @IBAction func endSessionTapped(_ sender: Any) {
        // 1. Initialize the Alert
        let alert = UIAlertController(
            title: "End Session?",
            message: "This will stop transcription and generate a summary.",
            preferredStyle: .alert
        )

        // 2. Define the "End Session" Action (Destructive)
        let endAction = UIAlertAction(title: "End Session", style: .destructive) { [weak self] _ in
            guard let self = self else { return }

            // Block 1: Safety Cleanup
            if self.isRecording {
                self.stopRecording()
            }
            // Block 2: End session globally in Firebase
            self.firebase.endSession()
        }

        // 4. Define the Cancel Action
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)

        // 5. Add actions and present the alert
        alert.addAction(endAction)
        alert.addAction(cancelAction)
        present(alert, animated: true)
    }

    private func handleGlobalSessionEnd() {
        guard !isSessionEnded else { return }
        isSessionEnded = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.stopRecording()
            self.removeListeningBubble()
            self.navigateToSummary()
            self.firebase.stop()
        }
    }

    func navigateToSummary() {
        let storyboard = UIStoryboard(name: "Action", bundle: nil)

        guard let summaryVC = storyboard.instantiateViewController(withIdentifier: "summaryScreen") as? BaseSummaryViewController else {
            print("Error: SummaryViewController not found!")
            return
        }

        summaryVC.category = self.category
        summaryVC.conversationTitle = self.sessionTitle
        summaryVC.transcriptMessages = self.messages.map { msg in
            ChatMessage(text: msg.text, isIncoming: msg.isIncoming, sender: msg.sender, senderID: msg.senderID)
        }

        // 1. Wrap your summaryVC in a new Navigation Controller
        let navController = UINavigationController(rootViewController: summaryVC)

        // 2. Set the modal style on the Nav Controller, not the summaryVC
        navController.modalPresentationStyle = .pageSheet
        navController.isModalInPresentation = true

        // 3. Present the Navigation Controller
        self.present(navController, animated: true, completion: nil)
    }

    // MARK: - Speech Implementation
    func startRecording() {
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        consumedTranscriptOffset = 0
        addListeningBubble()

        micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        micButton.tintColor = .systemRed

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, _) in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            micButton.tintColor = .systemRed
        } catch {
            print("Audio Engine Error: \(error)")
            isRecording = false
            micButton.setImage(UIImage(systemName: "mic.slash.fill"), for: .normal)
            micButton.tintColor = .label
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let fullString = result.bestTranscription.formattedString
                if self.consumedTranscriptOffset > fullString.count { self.consumedTranscriptOffset = 0 }

                let index = fullString.index(fullString.startIndex, offsetBy: self.consumedTranscriptOffset)
                let newContent = String(fullString[index...])
                self.consumedTranscriptOffset = fullString.count

                guard !newContent.isEmpty else { return }

                if let lastIndex = self.messages.lastIndex(where: { !$0.isIncoming }) {
                    let currentText = self.messages[lastIndex].text
                    let isPlaceholder = (currentText == "Listening..." || currentText == "..." || currentText == "Identifying\u{2026}" || currentText == "Identifying...")
                    let baseText = isPlaceholder ? "" : currentText
                    let combinedText = baseText + newContent

                    if combinedText.count > self.MAX_BUBBLE_CHAR_LIMIT {
                        // Find the last sentence boundary to split at
                        let boundaries = [". ", "? ", "! ", ".\n", "?\n", "!\n"]
                        var splitIndex: String.Index?

                        let searchRange = combinedText.startIndex..<combinedText.index(combinedText.startIndex, offsetBy: self.MAX_BUBBLE_CHAR_LIMIT)
                        for boundary in boundaries {
                            if let range = combinedText.range(of: boundary, options: .backwards, range: searchRange) {
                                if splitIndex == nil || range.lowerBound > splitIndex! {
                                    splitIndex = range.lowerBound
                                }
                            }
                        }

                        if let idx = splitIndex {
                            let endOfSentence = combinedText.index(idx, offsetBy: 1)
                            let firstPart = String(combinedText[...endOfSentence]).trimmingCharacters(in: .whitespacesAndNewlines)
                            let secondPart = String(combinedText[combinedText.index(after: endOfSentence)...]).trimmingCharacters(in: .whitespacesAndNewlines)

                            self.messages[lastIndex].text = firstPart
                            self.collectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                            self.processTextWithAppleIntelligence(text: firstPart, index: lastIndex)

                            let newMsg = GroupJoinChatMessage(text: secondPart.isEmpty ? "..." : secondPart, isIncoming: false, sender: self.myName, senderID: self.currentUserID)
                            self.messages.append(newMsg)
                            self.reloadDataAndScroll()
                        } else {
                            // No boundary found yet, just append
                            self.messages[lastIndex].text = combinedText
                            self.collectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                            self.scrollToBottom()
                        }
                    } else {
                        self.messages[lastIndex].text = combinedText
                        self.collectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                        self.scrollToBottom()
                    }

                    self.cleanupManager.scheduleCleanup(text: "keepalive", at: 0) { _, _ in
                        if let finalIndex = self.messages.lastIndex(where: { !$0.isIncoming }) {
                            let finalText = self.messages[finalIndex].text
                            if finalText != "Listening..." && finalText != "..." && !finalText.isEmpty {
                                self.processTextWithAppleIntelligence(text: finalText, index: finalIndex)
                            }
                        }
                        // Silence-based restart removed as per request.
                        // Bubble persists until manual stop or character limit reached.
                    }

                }
            }

            if let error = error {
                if !self.isRestarting {
                    print("Speech Error: \(error)")
                    self.stopRecording()
                } else {
                    self.isRestarting = false
                }
            }
        }
    }

    // MARK: - Apple Intelligence Logic
    private func processTextWithAppleIntelligence(text: String, index: Int) {
        if cleanedMessageIndices.contains(index) { return }
        cleanedMessageIndices.insert(index)

        Task {
            do {
                let instructions = """
                You are a real-time text cleanup assistant for a live captioning app designed for people with hearing loss. Your sole job is to fix grammar and punctuation in conversational speech-to-text output.

                GUARDRAILS:
                - Never fabricate, hallucinate, or invent information not present in the input.
                - Never produce harmful, offensive, biased, or discriminatory content.
                - If the input is empty, unintelligible, or meaningless, return it as-is without any additional words.
                - Always respond in the SAME language as the input.
                - Never include commentary, apologies, disclaimers, or boilerplate text.
                - Return ONLY the cleaned text with no extra formatting or explanation.
                """
                let prompt = """
                Clean up the following conversational text by fixing grammar and punctuation. Return ONLY the cleaned text.

                Text: "\(text)"
                """
                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt)
                var cleanedText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

                // Safety filter: If AI returns a commentary/apology, discard cleanup and use original text
                let lowercaseResponse = cleanedText.lowercased()
                if lowercaseResponse.contains("i'm sorry") || lowercaseResponse.contains("as an ai") || lowercaseResponse.contains("can't process") {
                    cleanedText = text
                }

                await MainActor.run {
                    if index < self.messages.count {
                        self.messages[index].text = cleanedText
                        self.collectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
                        self.firebase.send(text: cleanedText, sender: self.myName, senderID: self.currentUserID)
                    }
                }
            } catch {
                await MainActor.run {
                    self.firebase.send(text: text, sender: self.myName, senderID: self.currentUserID)
                }
            }
        }
    }

    // MARK: - Handlers
    func stopRecording() {
        guard isRecording else { return }
        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false

        removeListeningBubble()

        micButton.setImage(UIImage(systemName: "mic.slash.fill"), for: .normal)
        micButton.tintColor = .label
    }

    private func restartRecordingCycle() {
        isRestarting = true
        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        consumedTranscriptOffset = 0
        removeListeningBubble()
        startRecording()
    }

    private func addListeningBubble() {
        if let last = messages.last, last.text == "Listening..." && !last.isIncoming { return }
        let listeningMsg = GroupJoinChatMessage(text: "Listening...", isIncoming: false, sender: myName, senderID: currentUserID)
        messages.append(listeningMsg)
        reloadDataAndScroll()
    }

    private func removeListeningBubble() {
        messages.removeAll { ($0.text == "Listening..." || $0.text == "...") && !$0.isIncoming }
        reloadDataAndScroll()
    }

    private func reloadDataAndScroll() {
        collectionView.reloadData()
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard !messages.isEmpty else { return }
        let lastItem = IndexPath(item: messages.count - 1, section: 0)
        collectionView.scrollToItem(at: lastItem, at: .bottom, animated: true)
    }

    // MARK: - CollectionView DataSource
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return messages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let message = messages[indexPath.row]

        if message.isIncoming {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "IncomingCell", for: indexPath) as? IncomingCell else { return UICollectionViewCell() }
            cell.messageLabel.text = message.text
            cell.nameLabel.text = message.sender
            return cell
        } else {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "OutgoingCell", for: indexPath) as? OutgoingCell else { return UICollectionViewCell() }
            cell.messageLabel.text = message.text
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: collectionView.bounds.width, height: 80)
    }
}
