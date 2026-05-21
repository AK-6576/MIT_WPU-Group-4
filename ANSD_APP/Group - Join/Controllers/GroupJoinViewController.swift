//
//  GroupJoinViewController.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 25/11/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import AVFoundation
import Speech
import Combine
import FoundationModels // Apple Intelligence
import FirebaseAuth    // Required to fix "Cannot find 'Auth' in scope"
import FirebaseDatabase // Required for Firebase types

class GroupJoinViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, SFSpeechRecognizerDelegate {

    // MARK: - IBOutlets
    @IBOutlet weak var GroupJoinCollectionView: UICollectionView!
    @IBOutlet weak var GroupJoinPauseButton: UIButton!
    @IBOutlet weak var GroupJoinMicButton: UIButton!
    @IBOutlet weak var GroupJoinEndButton: UIButton!

    // MARK: - Properties
    private let firebase = FirebaseManager.shared
    private let cleanupManager = TextCleanupManager()

    // Apple Intelligence on-device language model used for text cleanup.
    private let model = SystemLanguageModel.default

    private var speechRecognizer = SFSpeechRecognizer(locale: LanguageManager.shared.currentLocale)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    var isRecording = false
    var isPaused = false
    var isHost = false
    var isRestarting = false

    var messages: [GroupJoinChatMessage] = []
    var cleanedMessageIndices = Set<Int>()
    var sentMessageIndices = Set<Int>()
    var isSessionEnded = false

    // Tracks the character offset into the full cumulative transcript string to extract only new speech.
    var consumedTranscriptOffset = 0

    // Session identifiers passed from the session selection screen.
    var currentSessionID: String = ""
    var sessionTitle: String = "Session"
    var hostUserIDFromLink: String = ""

    // Fixed: Using a computed property to safely fetch the Firebase UID
    // CRITICAL: Must sanitize to match GroupNewViewController & ActionJoinViewController
    var currentUserID: String {
        let rawID = Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "GuestUser"
        return rawID.components(separatedBy: CharacterSet(charactersIn: ".#$[]")).joined(separator: "_")
    }

    var myName: String {
        UserDefaults.standard.string(forKey: "user_first_name") ?? UIDevice.current.name
    }
    var otherPersonName = "Host"

    // Constant for bubble splitting (Adjust based on your UI)
    private let MAX_BUBBLE_CHAR_LIMIT = 180

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupSpeechPermissions()
        setupAudioSession()

        self.title = sessionTitle

        NotificationCenter.default.addObserver(self, selector: #selector(handleLanguageChange), name: .languageDidChange, object: nil)

        if !currentSessionID.isEmpty {
                // Only have the code? Find the Host UID first!
                firebase.findHostID(for: currentSessionID) { [weak self] hostUID in
                    guard let self = self, let uid = hostUID else {
                        // print("DEBUG: Room code not found.")
                        return
                    }
                    self.hostUserIDFromLink = uid
                    self.startSession() // Now startSession has the correct UID
                }
            }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRecording()
        NotificationCenter.default.removeObserver(self, name: .languageDidChange, object: nil)
    }

    @objc private func handleLanguageChange() {
        speechRecognizer = SFSpeechRecognizer(locale: LanguageManager.shared.currentLocale)
    }

    // MARK: - Setup
    private func setupCollectionView() {
        GroupJoinCollectionView.dataSource = self
        GroupJoinCollectionView.delegate = self
        if let layout = GroupJoinCollectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
            layout.minimumLineSpacing = 12
        }
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

    private func setupSpeechPermissions() {
        GroupJoinMicButton.isEnabled = false
        GroupJoinPauseButton.isEnabled = true
        GroupJoinEndButton.isEnabled = true

        // Initial muted state visuals
        GroupJoinMicButton.setImage(UIImage(systemName: "mic.slash.fill"), for: .normal)
        GroupJoinMicButton.tintColor = .label

        speechRecognizer?.delegate = self
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                self.GroupJoinMicButton.isEnabled = (authStatus == .authorized)
            }
        }
    }

    // MARK: - Speech Recognition
    private func startRecording() {
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        consumedTranscriptOffset = 0
        addListeningBubble()

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
            updateMicButtonVisuals(isActive: true)
        } catch {
            print("Audio Engine Start Error: \(error)")
            isRecording = false
            updateMicButtonVisuals(isActive: false)
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] (result, error) in
            guard let self = self else { return }

            Task { @MainActor in
                    if let result = result {
                        let fullString = result.bestTranscription.formattedString
                        
                        if result.isFinal {
                            print("Final transcript: \(fullString)")
                        }

                    if self.consumedTranscriptOffset > fullString.count {
                        self.consumedTranscriptOffset = 0
                    }

                    let startIndex = fullString.index(fullString.startIndex, offsetBy: self.consumedTranscriptOffset)
                    let newContent = String(fullString[startIndex...])
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
                                self.GroupJoinCollectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                                self.processTextWithAppleIntelligence(text: firstPart, index: lastIndex)

                                let newMsg = GroupJoinChatMessage(text: secondPart.isEmpty ? "..." : secondPart, isIncoming: false, sender: self.myName, senderID: self.currentUserID)
                                self.messages.append(newMsg)
                                self.reloadDataAndScroll()
                            } else {
                                // No boundary found yet, just append to current
                                self.messages[lastIndex].text = combinedText
                                self.GroupJoinCollectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                            }
                        } else {
                            self.messages[lastIndex].text = combinedText
                            self.GroupJoinCollectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                            self.scrollToBottom()
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                            guard let self = self else { return }
                            
                            if let finalIndex = self.messages.lastIndex(where: { !$0.isIncoming }) {
                                let finalText = self.messages[finalIndex].text
                                if finalText != "Listening..." && finalText != "..." && !finalText.isEmpty {
                                    self.processTextWithAppleIntelligence(text: finalText, index: finalIndex)
                                }
                            }
                        }
                        
                        if result.isFinal {
                            self.finalizeCurrentOutgoingMessage()
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
    }

    // MARK: - Apple Intelligence Logic
    private func processTextWithAppleIntelligence(text: String, index: Int) {
        if cleanedMessageIndices.contains(index) { return }
        cleanedMessageIndices.insert(index)
        
        cleanupManager.scheduleCleanup(text: text, at: index) { [weak self] cleanedIndex, cleanedText in
            guard let self = self else { return }
            
            if cleanedIndex < self.messages.count {
                self.messages[cleanedIndex].text = cleanedText
                self.GroupJoinCollectionView.reloadItems(at: [IndexPath(item: cleanedIndex, section: 0)])
            }
            
            self.sendMessageIfNeeded(text: cleanedText, index: cleanedIndex)
        }
    }
    
    private func sendMessageIfNeeded(text: String, index: Int) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              trimmedText != "Listening...",
              trimmedText != "...",
              !sentMessageIndices.contains(index) else { return }
        
        sentMessageIndices.insert(index)
        firebase.send(text: trimmedText, sender: myName, senderID: currentUserID)
    }
    
    private func finalizeCurrentOutgoingMessage() {
        guard let finalIndex = messages.lastIndex(where: { !$0.isIncoming }) else { return }
        processTextWithAppleIntelligence(text: messages[finalIndex].text, index: finalIndex)
    }

    private func stopRecording() {
        guard isRecording else { return }
        finalizeCurrentOutgoingMessage()
        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        removeListeningBubble()
        updateMicButtonVisuals(isActive: false)
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

    // MARK: - Bubble Logic
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

    private func startSession() {
        let targetUID = hostUserIDFromLink

        if targetUID.isEmpty { return }

        // 1. Point the Firebase reference to the HOST'S folder (The Source of Truth)
        firebase.setupSession(hostUID: targetUID, conversationID: currentSessionID, isHost: isHost)

        // 2. Mirror the room info to the JOINER'S folder so it shows in their personal history
        firebase.linkConversationToJoiner(hostUID: targetUID,
                                         conversationID: currentSessionID,
                                         conversationTitle: self.sessionTitle)

        // 3. Start observing (this will now pull all history from the host's folder)
        setupFirebaseObservers()
    }

    private func setupFirebaseObservers() {
        // Observe Session Status (Ended/Active)
        firebase.observeSessionStatus { [weak self] status in
            guard let self = self else { return }
            if status == "ended" {
                // print("DEBUG: Session ended signal received.")
                self.handleGlobalSessionEnd()
            }
        }

        // Observe Incoming Messages
        // Firebase Manager's .childAdded will now pull history + new messages
        firebase.observeMessages { [weak self] data in
            guard let self = self else { return }

            guard let text = data["text"] as? String,
                  let sender = data["sender"] as? String,
                  let senderID = data["senderID"] as? String else { return }

            // Deduplication: Don't add if we just sent this locally
            if senderID == self.currentUserID {
                let lastFinalized = self.messages.last(where: { !$0.isIncoming && $0.text != "..." && $0.text != "Listening..." })
                if let last = lastFinalized, last.text == text {
                    return
                }
            }

            // Update UI on Main Thread
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

        if isListeningPresent {
            self.removeListeningBubble()
        }

        let msg = GroupJoinChatMessage(
            text: text,
            isIncoming: (senderID != self.currentUserID),
            sender: sender,
            senderID: senderID
        )
        self.messages.append(msg)
        self.reloadDataAndScroll()

        if isListeningPresent && self.isRecording {
            self.addListeningBubble()
        }
    }

    // MARK: - Actions
    @IBAction func micButtonTapped(_ sender: UIButton) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @IBAction func pauseButtonTapped(_ sender: UIButton) {
        isPaused.toggle()
        let iconName = isPaused ? "play.fill" : "pause.fill"
        GroupJoinPauseButton.setImage(UIImage(systemName: iconName), for: .normal)
        if isPaused {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @IBAction func endButtonTapped(_ sender: UIButton) {
        let alert = UIAlertController(title: "End Session?", message: "This will end the session for all participants.", preferredStyle: .alert)
        let endAction = UIAlertAction(title: "End Session", style: .destructive) { [weak self] _ in
            self?.firebase.endSession()
        }
        alert.addAction(endAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func handleGlobalSessionEnd() {
        guard !isSessionEnded else { return }
        isSessionEnded = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            if self.isRecording {
                self.stopRecording()
            } else {
                self.removeListeningBubble()
            }

            let storyboard = UIStoryboard(name: "Group-Join", bundle: nil)
            if let summaryVC = storyboard.instantiateViewController(withIdentifier: "GroupJoinSummaryViewController") as? GroupJoinSummaryViewController {
                summaryVC.transcriptMessages = self.messages
                summaryVC.conversationTitle = self.sessionTitle
                let nav = UINavigationController(rootViewController: summaryVC)
                nav.modalPresentationStyle = .pageSheet
                nav.isModalInPresentation = true
                self.present(nav, animated: true)
            }
            self.firebase.stop()
        }
    }

    // MARK: - Helpers
    private func updateMicButtonVisuals(isActive: Bool) {
        let imageName = isActive ? "mic.fill" : "mic.slash.fill"
        GroupJoinMicButton.setImage(UIImage(systemName: imageName), for: .normal)
    }

    private func reloadDataAndScroll() {
        GroupJoinCollectionView.reloadData()
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard !messages.isEmpty else { return }
        let lastItem = IndexPath(item: messages.count - 1, section: 0)
        GroupJoinCollectionView.scrollToItem(at: lastItem, at: .bottom, animated: true)
    }

    // MARK: - DataSource
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return messages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let message = messages[indexPath.row]
        if message.isIncoming {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "GroupJoinIncomingCell", for: indexPath) as? GroupJoinIncomingCell else { return UICollectionViewCell() }
            cell.configure(with: message)
            return cell
        } else {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "GroupJoinOutgoingCell", for: indexPath) as? GroupJoinOutgoingCell else { return UICollectionViewCell() }
            cell.configure(with: message)
            return cell
        }
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: collectionView.bounds.width, height: 50)
    }
}
