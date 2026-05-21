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
import FirebaseAuth
import FirebaseDatabase

class GroupJoinViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, SFSpeechRecognizerDelegate {
    
    // MARK: - IBOutlets
    @IBOutlet weak var GroupJoinCollectionView: UICollectionView!
    @IBOutlet weak var GroupJoinPauseButton: UIButton!
    @IBOutlet weak var GroupJoinMicButton: UIButton!
    @IBOutlet weak var GroupJoinEndButton: UIButton!
    
    // MARK: - Properties
    private let firebase = FirebaseManager.shared
    private let cleanupManager = TextCleanupManager()
    
    // Reused single instance session to prevent continuous memory allocations
    private let model = SystemLanguageModel.default
    private lazy var aiSession: LanguageModelSession = {
        let instructions = """
        You are a real-time text cleanup assistant for a live captioning app designed for people with hearing loss. Your sole job is to fix grammar and punctuation in conversational speech-to-text output.
        GUARDRAILS:
        - Never fabricate information not present in the input.
        - If input is empty or unintelligible, return it as-is.
        - Always respond in the SAME language as input.
        - Return ONLY the cleaned text with no extra formatting, apologies, or explanation.
        """
        return LanguageModelSession(model: model, instructions: instructions)
    }()
    
    private var speechRecognizer = SFSpeechRecognizer(locale: LanguageManager.shared.currentLocale)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    var isRecording = false
    var isPaused = false
    var isHost = false
    var isRestarting = false
    
    var messages: [GroupJoinChatMessage] = []
    // Track cleaned messages safely by unique IDs instead of fragile array indexing
    var cleanedMessageKeys = Set<String>()
    var isSessionEnded = false
    
    var consumedTranscriptOffset = 0
    var currentSessionID: String = ""
    var sessionTitle: String = "Session"
    var hostUserIDFromLink: String = ""
    
    var currentUserID: String {
        let rawID = Auth.auth().currentUser?.uid ?? UIDevice.current.identifierForVendor?.uuidString ?? "GuestUser"
        return rawID.components(separatedBy: CharacterSet(charactersIn: ".#$[]")).joined(separator: "_")
    }
    
    var myName: String {
        UserDefaults.standard.string(forKey: "user_first_name") ?? UIDevice.current.name
    }
    var otherPersonName = "Host"
    let MAX_BUBBLE_CHAR_LIMIT = 240

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupSpeechPermissions()
        setupAudioSession()
        
        self.title = sessionTitle
        NotificationCenter.default.addObserver(self, selector: #selector(handleLanguageChange), name: .languageDidChange, object: nil)
        
        if !currentSessionID.isEmpty {
            firebase.findHostID(for: currentSessionID) { [weak self] hostUID in
                guard let self = self, let uid = hostUID else { return }
                self.hostUserIDFromLink = uid
                self.startSession()
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isRecording { startRecording() }
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
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Audio Session Error: \(error)")
        }
    }
    
    private func setupSpeechPermissions() {
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
        // FIX 1: Safe hardware device input alignment
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        
#if targetEnvironment(simulator)
        let alert = UIAlertController(title: "Simulator Unsupported", message: "Speech-to-text requires a physical microphone. Please test on a real device.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
        self.isRecording = false
        self.updateMicButtonVisuals(isActive: false)
        self.removeListeningBubble()
        return
#else
        guard hardwareFormat.sampleRate > 0 else {
            print("Audio Engine Error: Invalid sample rate. No physical mic detected.")
            self.isRecording = false
            self.updateMicButtonVisuals(isActive: false)
            self.removeListeningBubble()
            return
        }
#endif
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] (buffer, when) in
            self?.recognitionRequest?.append(buffer)
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
                    
                    if self.consumedTranscriptOffset > fullString.count {
                        self.consumedTranscriptOffset = 0
                    }
                    
                    let startIndex = fullString.index(fullString.startIndex, offsetBy: self.consumedTranscriptOffset)
                    let newContent = String(fullString[startIndex...])
                    self.consumedTranscriptOffset = fullString.count
                    
                    guard !newContent.isEmpty else { return }
                    
                    if let lastIndex = self.messages.lastIndex(where: { !$0.isIncoming }) {
                        let currentText = self.messages[lastIndex].text
                        let isPlaceholder = (currentText == "Listening..." || currentText == "..." || currentText == "Identifying\u{2026}")
                        let baseText = isPlaceholder ? "" : currentText
                        let combinedText = baseText + newContent
                        
                        if combinedText.count > self.MAX_BUBBLE_CHAR_LIMIT {
                            let boundaries = [". ", "? ", "! ", ".\n", "?\n", "!\n"]
                            var splitIndex: String.Index? = nil
                            
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
                                
                                // Call processing with the safe targeted object instead of indices
                                self.processTextWithAppleIntelligence(text: firstPart, originalMessageIndex: lastIndex)
                                
                                let newMsg = GroupJoinChatMessage(text: secondPart.isEmpty ? "..." : secondPart, isIncoming: false, sender: self.myName, senderID: self.currentUserID)
                                self.messages.append(newMsg)
                                self.reloadDataAndScroll()
                            } else {
                                self.messages[lastIndex].text = combinedText
                                self.GroupJoinCollectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                            }
                        } else {
                            self.messages[lastIndex].text = combinedText
                            self.GroupJoinCollectionView.reloadItems(at: [IndexPath(item: lastIndex, section: 0)])
                            self.scrollToBottom()
                        }
                        
                        self.cleanupManager.scheduleCleanup(text: "keepalive", at: 0) { _, _ in
                            Task { @MainActor in
                                if let finalIndex = self.messages.lastIndex(where: { !$0.isIncoming }) {
                                    let finalText = self.messages[finalIndex].text
                                    if finalText != "Listening..." && finalText != "..." && !finalText.isEmpty {
                                        self.processTextWithAppleIntelligence(text: finalText, originalMessageIndex: finalIndex)
                                    }
                                }
                                if self.isRecording {
                                    self.restartRecordingCycle()
                                }
                            }
                        }
                    }
                }
                
                if let error = error {
                    if !self.isRestarting {
                        print("Speech Error: \(error)")
                        let nsError = error as NSError
                        if self.isRecording && (nsError.domain == "kAFAssistantErrorDomain" || nsError.code == 203 || nsError.code == 216 || nsError.code == 1107) {
                            self.restartRecordingCycle()
                        } else {
                            self.stopRecording()
                        }
                    } else {
                        self.isRestarting = false
                    }
                }
            }
        }
    }
    
    // MARK: - Apple Intelligence Logic
    // MARK: - Apple Intelligence Logic
    private func processTextWithAppleIntelligence(text: String, originalMessageIndex: Int) {
        // 1. Create a stable, unique tracking key based on sender and content
        let trackingKey = "\(self.currentUserID)_\(text)"
        
        // 2. Safety validation utilizing the custom compound string key
        if cleanedMessageKeys.contains(trackingKey) { return }
        cleanedMessageKeys.insert(trackingKey)
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let prompt = """
                Clean up the following conversational text by fixing grammar and punctuation. Return ONLY the cleaned text.
                Text: "\(text)"
                """
                
                let response = try await self.aiSession.respond(to: prompt)
                var cleanedText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let lowercaseResponse = cleanedText.lowercased()
                if lowercaseResponse.contains("i'm sorry") || lowercaseResponse.contains("as an ai") || lowercaseResponse.contains("can't process") {
                    cleanedText = text
                }
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    
                    // 3. Locate the target message safely by matching the specific sender and text content
                    // (This protects against array race conditions/shifting indices)
                    if let directIndex = self.messages.firstIndex(where: { $0.text == text && $0.senderID == self.currentUserID }) {
                        self.messages[directIndex].text = cleanedText
                        self.GroupJoinCollectionView.reloadItems(at: [IndexPath(item: directIndex, section: 0)])
                        self.firebase.send(text: cleanedText, sender: self.myName, senderID: self.currentUserID)
                    }
                }
            } catch {
                print("Apple Intelligence Error: \(error)")
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.firebase.send(text: text, sender: self.myName, senderID: self.currentUserID)
                }
            }
        }
    }
    
    private func stopRecording() {
        guard isRecording else { return }
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
        firebase.setupSession(hostUID: targetUID, conversationID: currentSessionID, isHost: isHost)
        firebase.linkConversationToJoiner(hostUID: targetUID, conversationID: currentSessionID, conversationTitle: self.sessionTitle)
        setupFirebaseObservers()
    }

    private func setupFirebaseObservers() {
        firebase.observeSessionStatus { [weak self] status in
            guard let self = self else { return }
            if status == "ended" { self.handleGlobalSessionEnd() }
        }
        
        firebase.observeMessages { [weak self] data in
            guard let self = self else { return }
            guard let text = data["text"] as? String,
                  let sender = data["sender"] as? String,
                  let senderID = data["senderID"] as? String else { return }
            
            if senderID == self.currentUserID {
                let lastFinalized = self.messages.last(where: { !$0.isIncoming && $0.text != "..." && $0.text != "Listening..." })
                if let last = lastFinalized, last.text == text { return }
            }
            
            self.processIncomingMessage(text: text, sender: sender, senderID: senderID)
        }
    }

    private func processIncomingMessage(text: String, sender: String, senderID: String) {
        let trackingKey = "\(senderID)_\(text)"
        if cleanedMessageKeys.contains(trackingKey) { return }
        cleanedMessageKeys.insert(trackingKey)
        
        if messages.contains(where: { $0.text == text && $0.senderID == senderID }) { return }
        
        let isListeningPresent: Bool
        if let last = self.messages.last {
            isListeningPresent = (last.text == "Listening..." || last.text == "...") && !last.isIncoming
        } else {
            isListeningPresent = false
        }
        
        if isListeningPresent { self.removeListeningBubble() }
        
        let msg = GroupJoinChatMessage(text: text, isIncoming: (senderID != self.currentUserID), sender: sender, senderID: senderID)
        self.messages.append(msg)
        self.reloadDataAndScroll()
        
        if isListeningPresent && self.isRecording { self.addListeningBubble() }
    }
    
    // MARK: - Actions
    @IBAction func micButtonTapped(_ sender: UIButton) {
        isRecording ? stopRecording() : startRecording()
    }
    
    @IBAction func pauseButtonTapped(_ sender: UIButton) {
        isPaused.toggle()
        let iconName = isPaused ? "play.fill" : "pause.fill"
        GroupJoinPauseButton.setImage(UIImage(systemName: iconName), for: .normal)
        isPaused ? stopRecording() : startRecording()
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
            if self.isRecording { self.stopRecording() } else { self.removeListeningBubble() }
            
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
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "GroupJoinIncomingCell", for: indexPath) as! GroupJoinIncomingCell
            cell.configure(with: message)
            return cell
        } else {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "GroupJoinOutgoingCell", for: indexPath) as! GroupJoinOutgoingCell
            cell.configure(with: message)
            return cell
        }
    }
    
    // FIX 3: Removed sizeForItemAt completely to stop Auto Layout engine constraint fights.
}
