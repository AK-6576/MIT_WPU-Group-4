//
//  VoiceCalibrationViewController.swift
//  ANSD_APP
//
//  Created by Dhiraj Bodake on 19/02/26.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import AVFoundation
import CoreML
import Accelerate
import FirebaseAuth

// MARK: - Calibration Phase
private enum CalibrationPhase {
    case ready                  // Waiting for the user to tap once
    case countdown(Int)         // 3-2-1 countdown before recording starts
    case recording(Int)         // Actively recording sentence at index
    case verifying(Int)         // Processing & verifying voice after a sentence
    case betweenSentences(Int)  // Brief pause before the next sentence
    case mismatch               // Voice mismatch detected — retry
    case finished               // All done — show Finish button
}

class VoiceCalibrationViewController: UIViewController {

    // MARK: - Outlets
    @IBOutlet weak var promptCardView: UIView!
    @IBOutlet weak var promptTextLabel: UILabel!
    @IBOutlet weak var visualizerContainerView: UIView!
    @IBOutlet weak var instructionLabel: UILabel!
    @IBOutlet weak var recordButton: UIButton!

    // MARK: - State
    private var phase: CalibrationPhase = .ready {
        didSet { updateUI(for: phase) }
    }

    // MARK: - Timers & Audio
    private var audioRecorder: AVAudioRecorder?
    private var meteringTimer: Timer?
    private var phaseTimer: Timer?

    // MARK: - Visualizer
    private var audioBars: [UIView] = []
    private let barCount = 28

    // MARK: - ML Model
    private var model: VL1004?
    private let requiredSamples = 96000  // 6 seconds × 16kHz
    private let similarityThreshold: Float = 0.62

    // MARK: - Voice Embeddings
    private var sentenceEmbeddings: [[Float]] = []

    // MARK: - Sentence Status Indicators
    private var statusLabels: [UILabel] = []
    private var statusStack: UIStackView!

    // MARK: - Data
    private let sentences = [
        "The quick brown fox jumps over the lazy dog near the river bank.",
        "Please verify my identity by recognizing my unique voice pattern.",
        "Artificial intelligence is transforming the way we communicate daily."
    ]

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Navigation bar title
        title = "Voice Setup"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        setupCard()
        setupVisualizer()
        setupSentenceStatusIndicators()
        setupMLModel()
        requestMicrophoneAccess()
        updatePromptText(index: 0)
        setupNavigationBar()
        phase = .ready
    }

    // MARK: - ML Model Setup

    private func setupMLModel() {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            model = try VL1004(configuration: config)
            print("VoiceCalibration: VL1004 model loaded successfully")
        } catch {
            print("VoiceCalibration: Failed to load VL1004 model — \(error)")
        }
    }

    // MARK: - Navigation Bar Setup
    private func setupNavigationBar() {
        let infoButton = UIBarButtonItem(image: UIImage(systemName: "info.circle"), style: .plain, target: self, action: #selector(infoButtonTapped))
        navigationItem.rightBarButtonItem = infoButton
    }

    @objc private func infoButtonTapped() {
        let alert = UIAlertController(title: "Why Voice Profile?", message: "We use your voice profile to accurately transcribe your speech and differentiate it from other speakers in a conversation. It's stored securely on your device.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Got it", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    @IBAction func skipTapped(_ sender: UIButton) {
        navigateToHome()
    }

    // MARK: - UI Setup

    private func setupCard() {
        promptCardView.layer.cornerRadius = 20
        promptCardView.layer.shadowColor = UIColor.black.cgColor
        promptCardView.layer.shadowOpacity = 0.07
        promptCardView.layer.shadowOffset = CGSize(width: 0, height: 4)
        promptCardView.layer.shadowRadius = 12
        promptCardView.backgroundColor = .secondarySystemBackground
    }

    private func setupVisualizer() {
        visualizerContainerView.subviews.forEach { $0.removeFromSuperview() }
        audioBars.removeAll()

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        visualizerContainerView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: visualizerContainerView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: visualizerContainerView.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: visualizerContainerView.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: visualizerContainerView.heightAnchor)
        ])

        for _ in 0..<barCount {
            let bar = UIView()
            bar.backgroundColor = view.tintColor.withAlphaComponent(0.35)
            bar.layer.cornerRadius = 3
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 4).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            audioBars.append(bar)
            stack.addArrangedSubview(bar)
        }
    }

    private func setupSentenceStatusIndicators() {
        statusStack = UIStackView()
        statusStack.axis = .horizontal
        statusStack.distribution = .fillEqually
        statusStack.spacing = 12
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusStack)

        NSLayoutConstraint.activate([
            statusStack.topAnchor.constraint(equalTo: promptCardView.bottomAnchor, constant: 16),
            statusStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            statusStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -40),
            statusStack.heightAnchor.constraint(equalToConstant: 30)
        ])

        statusLabels.removeAll()
        for i in 0..<sentences.count {
            let label = UILabel()
            label.text = "Sentence \(i + 1)"
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .systemGray
            label.layer.cornerRadius = 8
            label.layer.masksToBounds = true
            label.backgroundColor = .systemGray6
            statusLabels.append(label)
            statusStack.addArrangedSubview(label)
        }
    }

    private func updateSentenceStatus(index: Int, verified: Bool) {
        guard index < statusLabels.count else { return }
        UIView.animate(withDuration: 0.3) {
            if verified {
                self.statusLabels[index].text = "Verified"
                self.statusLabels[index].textColor = .white
                self.statusLabels[index].backgroundColor = .systemGreen
            } else {
                self.statusLabels[index].text = "Mismatch"
                self.statusLabels[index].textColor = .white
                self.statusLabels[index].backgroundColor = .systemRed
            }
        }
    }

    private func resetSentenceStatuses() {
        for (i, label) in statusLabels.enumerated() {
            UIView.animate(withDuration: 0.3) {
                label.text = "Sentence \(i + 1)"
                label.textColor = .systemGray
                label.backgroundColor = .systemGray6
            }
        }
    }

    // MARK: - State → UI

    private func updateUI(for phase: CalibrationPhase) {
        switch phase {

        case .ready:
            setButton(title: "Start Voice Setup", image: "mic.fill", color: view.tintColor, enabled: true)
            instructionLabel.text = "Tap once. Read all three sentences."
            animateBarsToResting()

        case .countdown(let n):
            setButton(title: "Starting in \(n)…", image: "timer", color: .systemOrange, enabled: false)
            instructionLabel.text = "Get ready to speak…"
            animateBarsToResting()

        case .recording(let idx):
            let ordinals = ["first", "second", "third"]
            let label = idx < ordinals.count ? ordinals[idx] : "\(idx + 1)th"
            setButton(title: "Listening…  (\(idx + 1) of \(sentences.count))", image: "waveform", color: .systemRed, enabled: false)
            instructionLabel.text = "Read the sentence aloud (\(label) of three)"

        case .verifying(let idx):
            setButton(title: "Verifying voice…", image: "person.wave.2.fill", color: .systemPurple, enabled: false)
            instructionLabel.text = "Checking voice identity for sentence \(idx + 1)…"

        case .betweenSentences(let nextIdx):
            let next = min(nextIdx, sentences.count - 1)
            setButton(title: "Next sentence in 2s…", image: "arrow.right.circle", color: .systemOrange, enabled: false)
            instructionLabel.text = "Voice verified! Next coming up…"
            updatePromptText(index: next)
            animateBarsToResting()

        case .mismatch:
            setButton(title: "Try Again", image: "arrow.counterclockwise", color: .systemRed, enabled: true)
            instructionLabel.text = "Voice mismatch detected.\nPlease ensure only one person speaks."
            animateBarsToResting()

        case .finished:
            setButton(title: "Go to Home", image: "checkmark.circle.fill", color: .systemGreen, enabled: true)
            instructionLabel.text = "Voice profile saved.\nYour unique voice is now set up."
            animateBarsToResting()
        }
    }

    private func setButton(title: String, image: String, color: UIColor, enabled: Bool) {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.imagePadding = 8
        config.image = UIImage(systemName: image)
        config.title = title
        config.baseBackgroundColor = color
        config.baseForegroundColor = .white
        recordButton.configuration = config
        recordButton.isEnabled = enabled
    }

    // MARK: - Prompt

    private func updatePromptText(index: Int) {
        guard index < sentences.count else { return }
        UIView.transition(with: promptTextLabel, duration: 0.35, options: .transitionCrossDissolve) {
            self.promptTextLabel.text = self.sentences[index]
        }
    }

    // MARK: - Microphone Permission

    private func requestMicrophoneAccess() {
        let handlePermission: (Bool) -> Void = { [weak self] allowed in
            DispatchQueue.main.async {
                if allowed {
                    // Permission just granted — ensure the button is active and ready
                    self?.phase = .ready
                } else {
                    self?.instructionLabel.text = "Microphone access is required. Enable it in Settings → Privacy."
                    self?.setButton(title: "Microphone Required", image: "mic.slash.fill", color: .systemRed, enabled: false)
                }
            }
        }

        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: handlePermission)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(handlePermission)
        }
    }

    private func isMicrophonePermissionGranted() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    // MARK: - Audio Recorder (16kHz for VL1004 compatibility)

    private func setupAudioRecorder(for sentenceIndex: Int) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            try session.setActive(true)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = docs.appendingPathComponent("VoiceProfile_Sentence\(sentenceIndex).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,   // 16kHz to match VL1004 model
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
        } catch {
            print("VoiceCalibration: Recorder setup failed — \(error)")
        }
    }

    // MARK: - Main Flow

    @IBAction func recordButtonTapped(_ sender: UIButton) {
        switch phase {
        case .ready, .mismatch:
            // Guard: mic must be granted before starting
            guard isMicrophonePermissionGranted() else {
                let alert = UIAlertController(
                    title: "Microphone Required",
                    message: "Please allow microphone access in Settings to use Voice Setup.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                present(alert, animated: true)
                return
            }

            sentenceEmbeddings.removeAll()
            resetSentenceStatuses()
            updatePromptText(index: 0)
            beginCountdown()

        case .finished:
            navigateToHome()

        default:
            break
        }
    }

    /// Initiates the 3-2-1 countdown sequence before recording starts.
    private func beginCountdown() {
        var count = 3
        phase = .countdown(count)

        phaseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            count -= 1
            if count > 0 {
                self.phase = .countdown(count)
            } else {
                timer.invalidate()
                self.phaseTimer = nil
                self.recordSentence(index: 0)
            }
        }
    }

    /// Records a single sentence, triggers voice verification, and continues the flow.
    private func recordSentence(index: Int) {
        guard index < sentences.count else {
            // All sentences verified — save the profile
            saveVoiceProfile()
            self.phase = .finished
            return
        }

        updatePromptText(index: index)
        phase = .recording(index)

        setupAudioRecorder(for: index)

        // Safety guard — if audioRecorder failed to initialise, abort gracefully
        guard let recorder = audioRecorder else {
            print("VoiceCalibration: audioRecorder is nil for sentence \(index) — aborting.")
            DispatchQueue.main.async { self.phase = .mismatch }
            return
        }

        recorder.record()
        startMeteringAnimation()

        // Each sentence gets 7 seconds of recording time (model needs 6s = 96,000 samples @ 16kHz, plus 1s buffer)
        phaseTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.audioRecorder?.stop()
            self.stopMeteringAnimation()

            // Enter verification phase
            self.phase = .verifying(index)
            self.verifySentence(index: index)
        }
    }

    // MARK: - Voice Verification

    /// Extract embedding from recorded audio and verify it matches previous sentences
    private func verifySentence(index: Int) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("VoiceProfile_Sentence\(index).m4a")

        // Extract audio samples from recorded file
        extractAudioSamples(from: url) { [weak self] samples in
            guard let self = self else { return }

            guard let samples = samples else {
                print("VoiceCalibration: Failed to extract samples for sentence \(index)")
                DispatchQueue.main.async {
                    self.phase = .mismatch
                }
                return
            }

            // Run ML inference to get voice embedding
            guard let embedding = self.runVoiceInference(on: samples) else {
                print("VoiceCalibration: ML inference failed for sentence \(index)")
                DispatchQueue.main.async {
                    self.phase = .mismatch
                }
                return
            }

            let normalizedEmbedding = self.normalize(embedding)

            DispatchQueue.main.async {
                // First sentence — always accept as baseline
                if self.sentenceEmbeddings.isEmpty {
                    self.sentenceEmbeddings.append(normalizedEmbedding)
                    self.updateSentenceStatus(index: index, verified: true)
                    self.proceedAfterVerification(index: index)
                    return
                }

                // Compare with the first sentence (baseline voice)
                let baselineEmbedding = self.sentenceEmbeddings[0]
                let similarity = self.cosineSim(normalizedEmbedding, baselineEmbedding)

                print("VoiceCalibration: Sentence \(index + 1) similarity = \(String(format: "%.3f", similarity)) (threshold: \(self.similarityThreshold))")

                if similarity >= self.similarityThreshold {
                    // Voice matches — accept this sentence
                    self.sentenceEmbeddings.append(normalizedEmbedding)
                    self.updateSentenceStatus(index: index, verified: true)
                    self.proceedAfterVerification(index: index)
                } else {
                    // Voice MISMATCH — reject and require restart
                    self.updateSentenceStatus(index: index, verified: false)
                    self.sentenceEmbeddings.removeAll()

                    // Brief delay so user can see the mismatch indicator
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.phase = .mismatch
                    }
                }
            }
        }
    }

    private func proceedAfterVerification(index: Int) {
        if index + 1 < sentences.count {
            // Pause for 2 seconds then move to next sentence
            phase = .betweenSentences(index + 1)
            phaseTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.phaseTimer = nil
                self?.recordSentence(index: index + 1)
            }
        } else {
            // All sentences completed and verified — brief delay for UI to breathe
            print("VoiceCalibration: All sentences verified. Saving profile in 0.5s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.saveVoiceProfile()
                self.phase = .finished
                print("VoiceCalibration: Phase transitioned to .finished")
            }
        }
    }

    // MARK: - Audio Sample Extraction

    /// Read the recorded .m4a file and convert to 96,000 float samples at 16kHz
    private func extractAudioSamples(from url: URL, completion: @escaping ([Float]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let audioFile = try AVAudioFile(forReading: url)
                let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

                let frameCount = AVAudioFrameCount(audioFile.length)
                guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                    completion(nil)
                    return
                }
                try audioFile.read(into: fileBuffer)

                // Convert to 16kHz mono if needed
                let converter = AVAudioConverter(from: audioFile.processingFormat, to: processingFormat)
                let ratio = Float(processingFormat.sampleRate) / Float(audioFile.processingFormat.sampleRate)
                let outputCapacity = AVAudioFrameCount(Float(frameCount) * ratio) + 100

                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: outputCapacity) else {
                    completion(nil)
                    return
                }

                var error: NSError?
                var inputConsumed = false
                converter?.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if inputConsumed {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    inputConsumed = true
                    return fileBuffer
                }

                guard let channelData = outputBuffer.floatChannelData else {
                    completion(nil)
                    return
                }

                var samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))

                // Pad or truncate to exactly 96,000 samples (model requirement)
                let required = 96000
                if samples.count < required {
                    samples.append(contentsOf: [Float](repeating: 0, count: required - samples.count))
                } else if samples.count > required {
                    samples = Array(samples.prefix(required))
                }

                completion(samples)
            } catch {
                print("VoiceCalibration: Audio extraction error — \(error)")
                completion(nil)
            }
        }
    }

    // MARK: - ML Inference

    /// Run the VL1004 model on audio samples to extract a voice embedding vector
    private func runVoiceInference(on samples: [Float]) -> [Float]? {
        guard let model = model else {
            print("VoiceCalibration: Model not loaded")
            return nil
        }

        guard let inputMultiArray = try? MLMultiArray(shape: [1, NSNumber(value: requiredSamples)], dataType: .float32) else {
            return nil
        }

        for (i, sample) in samples.enumerated() {
            inputMultiArray[i] = NSNumber(value: sample)
        }

        do {
            let prediction = try model.prediction(audio: inputMultiArray)
            return extractVector(from: prediction.embedding)
        } catch {
            print("VoiceCalibration: Inference error — \(error)")
            return nil
        }
    }

    // MARK: - Save Voice Profile

    private func saveVoiceProfile() {
        guard !sentenceEmbeddings.isEmpty else { return }

        // Average all sentence embeddings into one representative vector
        let dim = sentenceEmbeddings[0].count
        var averaged = [Float](repeating: 0, count: dim)

        for embedding in sentenceEmbeddings {
            for i in 0..<dim {
                averaged[i] += embedding[i]
            }
        }

        let count = Float(sentenceEmbeddings.count)
        for i in 0..<dim {
            averaged[i] /= count
        }

        let normalizedAvg = normalize(averaged)

        // Save to persistent storage via VoiceProfileManager
        // Use "Me" as default name — user can change it later
        if let uid = Auth.auth().currentUser?.uid {
            VoiceProfileManager.shared.saveVoiceProfile(ownerUID: uid, name: "Me", embedding: normalizedAvg)
            print("VoiceCalibration: Voice profile successfully saved for user \(uid)")
        } else {
            print("VoiceCalibration: Error - No logged-in user to save voice profile.")
        }
    }

    // MARK: - Math Utilities (matching AudioDiarizer)

    private func extractVector(from multiArray: MLMultiArray) -> [Float] {
        let count = multiArray.count
        let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    private func normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        let mag = sqrt(norm) + 1e-9
        var res = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, [mag], &res, 1, vDSP_Length(v.count))
        return res
    }

    private func cosineSim(_ v1: [Float], _ v2: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(v1, 1, v2, 1, &dot, vDSP_Length(v1.count))
        return dot
    }

    // MARK: - Visualizer Animation

    private func startMeteringAnimation() {
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let rec = self.audioRecorder else { return }
            rec.updateMeters()
            let power = rec.averagePower(forChannel: 0)
            let level = CGFloat(max(0, min(1, (power + 60) / 60)))
            self.animateBars(level: level)
        }
    }

    private func stopMeteringAnimation() {
        meteringTimer?.invalidate()
        meteringTimer = nil
    }

    private func animateBars(level: CGFloat) {
        UIView.animate(withDuration: 0.05) {
            for (i, bar) in self.audioBars.enumerated() {
                let wave = CGFloat(sin(Double(i) * 0.5 + Date().timeIntervalSince1970 * 8) * 0.3)
                let barLevel = max(0, level + wave)
                let maxH: CGFloat = 48, minH: CGFloat = 6
                let h = minH + barLevel * (maxH - minH)
                bar.transform = CGAffineTransform(scaleX: 1, y: max(1, h / minH))
                bar.backgroundColor = self.view.tintColor.withAlphaComponent(0.4 + level * 0.6)
            }
        }
    }

    private func animateBarsToResting() {
        UIView.animate(withDuration: 0.4, delay: 0,
                       usingSpringWithDamping: 0.7, initialSpringVelocity: 0.3) {
            for bar in self.audioBars {
                bar.transform = .identity
                bar.backgroundColor = self.view.tintColor.withAlphaComponent(0.35)
            }
        }
    }

    // MARK: - Navigation

    private func navigateToHome() {
        // If presented modally (from Profile or Quick Captions), dismiss cleanly
        if let presenting = presentingViewController ?? navigationController?.presentingViewController {
            dismiss(animated: true)
            return
        }

        // Navigate to Home for onboarding flow by resetting the window root for a clean state
        let storyboard = UIStoryboard(name: "Home", bundle: nil)
        if let homeNav = storyboard.instantiateViewController(withIdentifier: "HomeNav") as? UINavigationController {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.rootViewController = homeNav
                window.makeKeyAndVisible()
                UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: nil, completion: nil)
            } else {
                // Fallback to segue if window lookup fails
                performSegue(withIdentifier: "calibrationToHome", sender: self)
            }
        }
    }

    // MARK: - Cleanup

    deinit {
        phaseTimer?.invalidate()
        meteringTimer?.invalidate()
        audioRecorder?.stop()
    }
}
