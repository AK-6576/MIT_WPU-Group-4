//
//  GroupNewViewController.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 25/11/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import AVFoundation
import Speech
import Combine
import FoundationModels
import FirebaseAuth
import FirebaseDatabase

class GroupNewViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, SFSpeechRecognizerDelegate {
        @IBOutlet weak var collectionView: UICollectionView!
        @IBOutlet weak var pauseButton: UIButton!
        @IBOutlet weak var micButton: UIButton!
        @IBOutlet weak var endButton: UIButton!

        private let firebase = FirebaseManager.shared
        private let cleanupManager = TextCleanupManager()

        private let model = SystemLanguageModel.default

        private var speechRecognizer = SFSpeechRecognizer(locale: LanguageManager.shared.currentLocale)
        private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        private var recognitionTask: SFSpeechRecognitionTask?
        private let audioEngine = AVAudioEngine()

        // State
        var isRecording = false
        var isPaused = false
        var isHost = true
        var isRestarting = false
        var roomCodeShown = false

        var otherPersonName = "Guest"
        var messages: [GroupNewChatMessage] = []
        var cleanedMessageIndices = Set<Int>()
        var sentMessageIndices = Set<Int>()
        var currentSessionID: String = ""

    // --- FIXED PROPERTY DECLARATIONS ---
    var currentUserID: String {
        let rawID = Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "UnknownUser"
        // Remove illegal characters to prevent Firebase key errors
        return rawID.components(separatedBy: CharacterSet(charactersIn: ".#$[]")).joined(separator: "_")
    }

    var myName: String {
        UserDefaults.standard.string(forKey: "user_first_name") ?? UIDevice.current.name
    }
        // -----------------------------------

        var consumedTranscriptOffset = 0
        private let MAX_BUBBLE_CHAR_LIMIT = 180

        override func viewDidLoad() {
            super.viewDidLoad()

            setupCollectionView()
            setupSpeechPermissions()
            setupAudioSession()

            if currentSessionID.isEmpty {
                self.currentSessionID = String(Int.random(in: 1000...9999))
            }
            self.title = "Room: \(currentSessionID)"

            startSession()

            NotificationCenter.default.addObserver(self, selector: #selector(handleLanguageChange), name: .languageDidChange, object: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showRoomCodeAlert()
            }
        }

    @objc private func handleLanguageChange() {
        speechRecognizer = SFSpeechRecognizer(locale: LanguageManager.shared.currentLocale)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRecording()
        NotificationCenter.default.removeObserver(self, name: .languageDidChange, object: nil)
    }

    // MARK: - Setup
    private func setupCollectionView() {
        collectionView.dataSource = self
        collectionView.delegate = self
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
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

    // MARK: - Speech Logic
    private func startRecording() {
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        // Reset offset for new session
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

                    // Safety check for backspacing/correction
                    if self.consumedTranscriptOffset > fullString.count {
                        self.consumedTranscriptOffset = 0
                    }

                    // Calculate Delta
                    let startIndex = fullString.index(fullString.startIndex, offsetBy: self.consumedTranscriptOffset)
                    let newContent = String(fullString[startIndex...])
                    self.consumedTranscriptOffset = fullString.count

                    guard !newContent.isEmpty else { return }

                    // Update Bubble Logic
                    if let lastIndex = self.messages.lastIndex(where: { !$0.isIncoming }) {
                        let currentText = self.messages[lastIndex].text
                        let isPlaceholder = (currentText == "Listening..." || currentText == "..." || currentText == "Identifying\u{2026}" || currentText == "Identifying...")
                        let baseText = isPlaceholder ? "" : currentText
                        let combinedText = baseText + newContent

                        // CHECK LIMIT (3-4 Lines Logic)
                        // --- UPDATED BUBBLE SPLITTING LOGIC ---
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

                                let newMsg = GroupNewChatMessage(text: secondPart.isEmpty ? "..." : secondPart, isIncoming: false, sender: self.myName, senderID: self.currentUserID)
                                self.messages.append(newMsg)
                                self.reloadDataAndScroll()
                            } else {
                                // No boundary found yet, just append
                                self.messages[lastIndex].text = combinedText
                                self.collectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                                self.scrollToBottom()
                            }
                        } else {
                            // JUST APPEND
                            self.messages[lastIndex].text = combinedText
                            self.collectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
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
                self.collectionView.reloadItems(at: [IndexPath(item: cleanedIndex, section: 0)])
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

        // Ensure we only remove bubbles that are strictly "Listening..." placeholders
        removeListeningBubble()

        startRecording()
    }

    // MARK: - Bubble Logic
    private func addListeningBubble() {
        if let last = messages.last, last.text == "Listening..." && !last.isIncoming { return }
        let listeningMsg = GroupNewChatMessage(text: "Listening...", isIncoming: false, sender: myName, senderID: currentUserID)
        messages.append(listeningMsg)
        reloadDataAndScroll()
    }

    private func updateListeningBubble(with text: String) {
        if let index = messages.lastIndex(where: { !$0.isIncoming }) {
            messages[index].text = text
            let indexPath = IndexPath(item: index, section: 0)
            UIView.performWithoutAnimation {
                self.collectionView.reloadItems(at: [indexPath])
            }
            scrollToBottom()
        }
    }

    private func removeListeningBubble() {
        messages.removeAll { ($0.text == "Listening..." || $0.text == "...") && !$0.isIncoming }
        reloadDataAndScroll()
    }

    private func startSession() {
        let hostID = currentUserID

        // PRINT THIS: You need this UID to let the other user join your room
        // print("DEBUG: Host UID is: \(hostID)")
        // print("DEBUG: Room ID is: \(currentSessionID)")
            firebase.registerRoom(code: currentSessionID, hostUID: hostID)

            // 2. Setup the actual room path
            firebase.setupSession(hostUID: hostID, conversationID: currentSessionID, isHost: isHost)

        firebase.observeSessionStatus { [weak self] status in
            guard let self = self else { return }
            if status == "ended" {
                self.handleGlobalSessionEnd()
            }
        }

        firebase.observeMessages { [weak self] data in
            guard let self = self else { return }

            // Corrected syntax for the if-let block
            if let text = data["text"] as? String,
               let sender = data["sender"] as? String,
               let senderID = data["senderID"] as? String {

                if senderID == self.currentUserID {
                    let lastFinalized = self.messages.last(where: {
                        $0.text != "Listening..." && $0.text != "..." && !$0.isIncoming
                    })
                    if let last = lastFinalized, last.text == text {
                        return
                    }
                }

                let isListeningPresent = (self.messages.last?.text == "Listening..." || self.messages.last?.text == "...") && !self.messages.last!.isIncoming

                if isListeningPresent {
                    self.removeListeningBubble()
                }

                let msg = GroupNewChatMessage(
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
        }
    }

    // MARK: - Popups
    private func showRoomCodeAlert() {
        guard !roomCodeShown else { return }
        roomCodeShown = true
        let alert = UIAlertController(title: "Room Code", message: "Share this code: \(currentSessionID)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Copy", style: .default, handler: { _ in
            UIPasteboard.general.string = self.currentSessionID
        }))
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Actions
    @IBAction func micButtonTapped(_ sender: UIButton) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func updateMicButtonVisuals(isActive: Bool) {
        let imageName = isActive ? "mic.fill" : "mic.slash.fill"
        micButton.setImage(UIImage(systemName: imageName), for: .normal)
    }

    @IBAction func pauseButtonTapped(_ sender: UIButton) {
        isPaused.toggle()
        let iconName = isPaused ? "play.fill" : "pause.fill"
        pauseButton.setImage(UIImage(systemName: iconName), for: .normal)
        if isPaused {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @IBAction func endButtonTapped(_ sender: UIButton) {
        let actionSheet = UIAlertController(
            title: "End Session?",
            message: "This will end the session for all participants and show the summary.",
            preferredStyle: .alert
        )

        let endAction = UIAlertAction(title: "End Session", style: .destructive) { [weak self] _ in
            self?.firebase.endSession()
        }

        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)

        actionSheet.addAction(endAction)
        actionSheet.addAction(cancelAction)

        present(actionSheet, animated: true)
    }

    private func handleGlobalSessionEnd() {
        // 1. Stop Recording
        self.stopRecording()

        // 2. Clear UI artifacts
        self.removeListeningBubble()

        // 3. Navigate to Summary
        let storyboard = UIStoryboard(name: "Group-New", bundle: nil)
        if let summaryVC = storyboard.instantiateViewController(withIdentifier: "GroupNewSummaryViewController") as? GroupNewSummaryViewController {
            summaryVC.transcriptMessages = self.messages
            summaryVC.conversationTitle = "Room \(self.currentSessionID)"

            let nav = UINavigationController(rootViewController: summaryVC)
            nav.modalPresentationStyle = .pageSheet
            nav.isModalInPresentation = true
            self.present(nav, animated: true)
        }

        // 4. Cleanup Firebase
        firebase.stop()
    }

    // MARK: - Helpers

    private func reloadDataAndScroll() {
        collectionView.reloadData()
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard !messages.isEmpty else { return }
        let lastItem = IndexPath(item: messages.count - 1, section: 0)
        collectionView.scrollToItem(at: lastItem, at: .bottom, animated: true)
    }

    // MARK: - DataSource
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return messages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let message = messages[indexPath.row]
        if message.isIncoming {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "GroupNewIncomingCell", for: indexPath) as? GroupNewIncomingCell else { return UICollectionViewCell() }
            cell.configure(with: message)
            return cell
        } else {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "GroupNewOutgoingCell", for: indexPath) as? GroupNewOutgoingCell else { return UICollectionViewCell() }
            cell.configure(with: message)
            return cell
        }
    }

    // MARK: - Navigation
    @IBAction func addPersonTapped(_ sender: UIBarButtonItem) {
        let storyboard = UIStoryboard(name: "Group-New", bundle: nil)
        if let selectionVC = storyboard.instantiateViewController(withIdentifier: "ParticipantSelectionViewController") as? ParticipantSelectionViewController {
            selectionVC.roomCode = self.currentSessionID
            selectionVC.onParticipantsSelected = { [weak self] (names: [String]) in
                self?.otherPersonName = names.first ?? "Guest"
                self?.collectionView.reloadData()
            }
            let nav = UINavigationController(rootViewController: selectionVC)
            self.present(nav, animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: collectionView.bounds.width, height: 50)
    }
}
