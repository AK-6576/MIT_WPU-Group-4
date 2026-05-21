//
//  AudioDiarizer.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 20/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import Foundation
import AVFoundation
import CoreML
import Accelerate
import SoundAnalysis
import Combine

struct DiarizationEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let vector: [Float]
    var assignedSpeakerID: Int
    var confidence: Float
    let locationTag: String?
}

class AudioDiarizer: ObservableObject {
    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var model: VL1004?

    // MARK: - Sliding Window Configuration
    private let requiredSamples = 96000 // 6 seconds @ 16kHz
    private let stride          = 4800  // 300ms slide interval
    private var collectedSamples: [Float] = []

    // MARK: - Core Diarization Parameters
    private let matchThreshold: Float = 0.72 // Strictly identify new speakers (was 0.65)
    private let deadzoneThreshold: Float = 0.50 // Noise floor (was 0.45)
    private let userMatchThreshold: Float = 0.63 // Stricter match for enrolled user (was 0.48)
    private let learningThreshold: Float = 0.85 // Only learn from high-quality audio (was 0.82)

    // MARK: - Temporal Continuity & Probation
    private var unknownFrameCount = 0
    private let probationLimit = 2 // Faster reaction to new speakers (was 3)
    private var lastMatchedSpeakerID: Int?

    // MARK: - SoundAnalysis Speech Gate
    private let speechGate     = SpeechActivityGate()
    private var soundAnalyzer: SNAudioStreamAnalyzer?
    private let analysisQueue  = DispatchQueue(label: "com.ansd.soundanalysis", qos: .userInitiated)
    private var analysisFrame: AVAudioFramePosition = 0

    // MARK: - Published State (60/40 Centroid Architecture)
    @Published var speakerProfiles: [Int: [Float]] = [:] // The Active Scoring Profile
    var baseAnchors: [Int: [Float]] = [:]                // ⭐️ 60% Permanent Anchor (Never changes)
    private var activeClusters: [Int: [[Float]]] = [:]   // ⭐️ 40% Recent Adaptation (Last 15 clean frames)
    private let maxClusterSize = 15                      // ~4.5 seconds of memory

    @Published var speakerNames: [Int: String] = [:]
    @Published var currentStatus: String = "Ready"
    @Published var confidence: String = "--"
    @Published var isRunning               = false
    @Published var currentSpeakerID: Int?
    @Published var segmentHistory: [DiarizationEvent] = []

    public var currentLocation: String?
    private var isEnrolling = false
    private var enrollmentCompletion: ((Bool) -> Void)?

    // MARK: - Inference Queue
    private let inferenceQueue = DispatchQueue(label: "com.ansd.audiodiarizer.inference", qos: .userInitiated)
    private var pendingInferenceCount = 0
    private let maxPendingInferences  = 1

    // MARK: - Simulator debug
    #if targetEnvironment(simulator)
    private var simFrameCount = 0
    #endif

    init() {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            self.model = try VL1004(configuration: config)
            print("✅ VL1004 Model Loaded Successfully")
        } catch {
            print("❌ Model Load Error: \(error.localizedDescription)")
            #if targetEnvironment(simulator)
            print("💡 Note: CoreML models can sometimes fail on simulators due to architecture mismatches.")
            #endif
        }
    }

    // MARK: - Enrollment & Profile Injection
    func enrollUser(completion: @escaping (Bool) -> Void) {
        print("Starting Enrollment for User (ID: 0)...")
        self.isEnrolling = true
        self.enrollmentCompletion = completion
        self.collectedSamples.removeAll()

        self.speakerProfiles.removeAll()
        self.baseAnchors.removeAll()
        self.activeClusters.removeAll()

        self.speakerNames.removeAll()
        self.lastMatchedSpeakerID = nil
        self.unknownFrameCount = 0
    }

    // Helper for the VC to inject profiles cleanly into all 3 dictionaries
    func setPreEnrolledProfile(vector: [Float], name: String) {
        self.speakerProfiles[0] = vector
        self.baseAnchors[0] = vector
        self.activeClusters[0] = [vector]
        self.speakerNames[0] = name
        print("✅ Pre-Enrolled Profile Loaded and Anchored for: \(name)")
    }

    func setUserName(_ name: String) {
        speakerNames[0] = name
    }

    // MARK: - Audio Processing
    func handleAudio(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        #if targetEnvironment(simulator)
        // Track frames received via instance variable (local vars reset every call).
        simFrameCount += 1
        if simFrameCount % 200 == 0 {
            print("🔊 [Diarizer] Simulator audio pulse: \(simFrameCount) frames received")
        }
        #endif

        // SoundAnalysis runs on both device and simulator for sound classification.
        // On the simulator the speech gate result is ignored for diarization inference
        // (gateOpen is forced true in processSamples), but classification logging still works.
        if soundAnalyzer == nil { setupSoundAnalyzer(format: buffer.format) }
        let framePos = analysisFrame
        analysisFrame += AVAudioFramePosition(buffer.frameLength)
        let bufferCopy = buffer
        analysisQueue.async { [weak self] in
            self?.soundAnalyzer?.analyze(bufferCopy, atAudioFramePosition: framePos)
        }

        guard let converter = getConverter(from: buffer.format, to: targetFormat) else { return }
        let ratio = Float(targetFormat.sampleRate) / Float(buffer.format.sampleRate)
        let capacity = UInt32(Float(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let channelData = outputBuffer.floatChannelData {
            var samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
            normalizeAudioSignal(&samples)
            DispatchQueue.main.async { self.processSamples(samples) }
        }
    }

    private func processSamples(_ samples: [Float]) {
        // On the simulator the SoundAnalysis VAD gate is bypassed (see handleAudio),
        // so we treat all audio as speech for both enrollment and normal inference.
        #if targetEnvironment(simulator)
        let gateOpen = true
        #else
        let gateOpen = speechGate.isActive
        #endif

        if isEnrolling {
            // Collect samples only when the gate is open (i.e. always on simulator).
            if gateOpen {
                collectedSamples.append(contentsOf: samples)
                if collectedSamples.count % 16000 == 0 {
                    print("🎙 Enrolling: Captured \(collectedSamples.count)/\(requiredSamples) speech samples...")
                }
            }
        } else {
            // Always collect samples during normal session.
            collectedSamples.append(contentsOf: samples)
            if collectedSamples.count % 16000 == 0 {
                print("🎤 Collected \(collectedSamples.count)/\(requiredSamples) samples...")
            }
        }

        guard collectedSamples.count >= requiredSamples else { return }
        let chunk = Array(collectedSamples.prefix(requiredSamples))
        collectedSamples.removeFirst(stride)

        if gateOpen {
            scheduleInference(on: chunk)
        }
    }

    private func scheduleInference(on samples: [Float]) {
        guard pendingInferenceCount <= maxPendingInferences else { return }
        pendingInferenceCount += 1

        inferenceQueue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.pendingInferenceCount -= 1 } }
            self?.runInference(on: samples)
        }
    }

    private func runInference(on samples: [Float]) {
        guard let model = model,
              let input = try? MLMultiArray(shape: [1, NSNumber(value: requiredSamples)], dataType: .float32) else { return }

        for (i, s) in samples.enumerated() { input[i] = NSNumber(value: s) }

        do {
            let startTime  = CFAbsoluteTimeGetCurrent()
            let prediction = try model.prediction(audio: input)
            let elapsed    = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            let vector = extractVector(from: prediction.embedding)

            DispatchQueue.main.async {
                print("⚡️ Inference: \(String(format: "%.1f", elapsed))ms")
                self.processEmbedding(vector)
            }
        } catch {
            print("❌ Inference Error: \(error)")
        }
    }

    // MARK: - The "Identity-Lock" Match Logic
    private func processEmbedding(_ vector: [Float]) {
        let normVector = normalize(vector)

        if isEnrolling {
            print("✅ User Enrolled (ID 0). Absolute Anchor Set.")
            speakerProfiles[0] = normVector
            baseAnchors[0] = normVector
            activeClusters[0] = [normVector]
            speakerNames[0] = "Me"
            isEnrolling = false
            enrollmentCompletion?(true)
            return
        }

        if speakerProfiles.isEmpty {
            let newID = createNewSpeaker(with: normVector)
            lastMatchedSpeakerID = newID
            addToHistory(vector: normVector, id: newID, score: 1.0)
            return
        }

        struct ScoredSpeaker { let id: Int; let score: Float; let raw: Float }
        var scoredSpeakers: [ScoredSpeaker] = []
        for id in speakerProfiles.keys {
            guard let dynamicProfile = speakerProfiles[id], let anchorProfile = baseAnchors[id] else { continue }

            // Score against BOTH the adaptive profile and the permanent anchor
            let dynScore = cosineSim(normVector, dynamicProfile)
            let anchorScore = cosineSim(normVector, anchorProfile)

            let raw = max(dynScore, anchorScore)
            var score = raw

            // Magnet for ID 0 (User's Voice) - Reduced to prevent merging similar voices
            if id == 0 { score += 0.05 }
            // Continuity boost
            if id == lastMatchedSpeakerID { score += 0.05 }

            score = min(score, 1.0)
            scoredSpeakers.append(ScoredSpeaker(id: id, score: score, raw: raw))
        }

        scoredSpeakers.sort { $0.score > $1.score }
        let bestMatch = scoredSpeakers[0]

        let threshold = (bestMatch.id == 0) ? userMatchThreshold : matchThreshold

        if bestMatch.score >= threshold {
            // CONFIRMED MATCH
            unknownFrameCount = 0
            lastMatchedSpeakerID = bestMatch.id
            self.confidence = String(format: "%.0f%%", bestMatch.score * 100)

            print("🎯 Match: Speaker \(bestMatch.id) (\(String(format: "%.0f%%", bestMatch.score * 100))) [Raw: \(String(format: "%.2f", bestMatch.raw))]")

            // Only update the room-adaptation cluster if the audio is exceedingly clean
            if bestMatch.raw > learningThreshold && speechGate.isActive {
                print("🧠 Clean speech detected. Updating Centroid for Speaker \(bestMatch.id).")
                updateProfile(id: bestMatch.id, vector: normVector)
            } else if bestMatch.raw > learningThreshold {
                print("🧠 Match confirmed, but gate rejected learning (VAD low).")
            }

            currentSpeakerID = bestMatch.id
            addToHistory(vector: normVector, id: bestMatch.id, score: bestMatch.score)

            // Periodically run background refinement
            if segmentHistory.count % 10 == 0 {
                performRetroactiveRefinement()
            }

        } else if bestMatch.score < deadzoneThreshold {
            // POTENTIAL NEW SPEAKER (Probation Phase)
            unknownFrameCount += 1
            currentSpeakerID = nil // Prevent bleed
            if unknownFrameCount >= probationLimit {
                print("👽 [NEW VOICE] Persistent unknown signature. Creating New Speaker!")
                let newID = createNewSpeaker(with: normVector)
                lastMatchedSpeakerID = newID
                unknownFrameCount = 0
                addToHistory(vector: normVector, id: newID, score: bestMatch.score)
            } else {
                print("🚧 Unknown voice detected. Probation: \(unknownFrameCount)/\(probationLimit) [Score: \(String(format: "%.2f", bestMatch.score))]")
                addToHistory(vector: normVector, id: -1, score: bestMatch.score)
            }
        } else {
            // THE DEADZONE
            unknownFrameCount = 0
            currentSpeakerID = nil // Prevent bleed
            print("🌫 Noisy/Transition Frame (Score \(String(format: "%.2f", bestMatch.score))). Ignored.")
            addToHistory(vector: normVector, id: -1, score: bestMatch.score)
        }
    }

    // MARK: - 60/40 Profile Centroid Engine
    private func createNewSpeaker(with vector: [Float]) -> Int {
        let newID = (speakerProfiles.keys.max() ?? 0) + 1
        speakerProfiles[newID] = vector
        baseAnchors[newID] = vector
        activeClusters[newID] = [vector]
        currentSpeakerID = newID
        print("👤 New Speaker Identified: ID \(newID)")
        return newID
    }

    private func updateProfile(id: Int, vector: [Float]) {
        guard let anchor = baseAnchors[id] else { return }

        if activeClusters[id] == nil { activeClusters[id] = [] }
        activeClusters[id]?.append(vector)

        // Keep only the most recent N clean frames
        if activeClusters[id]!.count > maxClusterSize {
            activeClusters[id]?.removeFirst()
        }

        guard let cluster = activeClusters[id], !cluster.isEmpty else { return }

        // 1. Calculate the average of the recent clean frames (The 40% Room Adapter)
        var clusterSum = [Float](repeating: 0, count: vector.count)
        for v in cluster {
            vDSP_vadd(clusterSum, 1, v, 1, &clusterSum, 1, vDSP_Length(vector.count))
        }

        var clusterAvg = [Float](repeating: 0, count: vector.count)
        let countFloat = Float(cluster.count)
        vDSP_vsdiv(clusterSum, 1, [countFloat], &clusterAvg, 1, vDSP_Length(vector.count))
        clusterAvg = normalize(clusterAvg)

        // 2. Combine with the Anchor (The 60% Permanent Identity)
        var combined = [Float](repeating: 0, count: vector.count)
        var wAnchor: Float = 0.60
        var wCluster: Float = 0.40

        vDSP_vsmul(anchor, 1, &wAnchor, &combined, 1, vDSP_Length(vector.count))
        vDSP_vsma(clusterAvg, 1, &wCluster, combined, 1, &combined, 1, vDSP_Length(vector.count))

        // 3. Save as the active scoring profile
        speakerProfiles[id] = normalize(combined)
    }

    // MARK: - Math & Audio Helpers
    private func normalizeAudioSignal(_ samples: inout [Float]) {
        var maxAmp: Float = 0
        vDSP_maxv(samples, 1, &maxAmp, vDSP_Length(samples.count))
        if maxAmp > 0 {
            var factor = 1.0 / maxAmp
            vDSP_vsmul(samples, 1, &factor, &samples, 1, vDSP_Length(samples.count))
        }
    }

    func cosineSim(_ v1: [Float], _ v2: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(v1, 1, v2, 1, &dot, vDSP_Length(v1.count))
        return dot
    }

    func normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        let mag = sqrt(norm) + 1e-9
        var res = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, [mag], &res, 1, vDSP_Length(v.count))
        return res
    }

    func extractVector(from multiArray: MLMultiArray) -> [Float] {
        let count = multiArray.count
        let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    private func getConverter(from i: AVAudioFormat, to o: AVAudioFormat) -> AVAudioConverter? {
        if audioConverter == nil || audioConverter?.inputFormat != i { audioConverter = AVAudioConverter(from: i, to: o) }
        return audioConverter
    }

    private func setupSoundAnalyzer(format: AVAudioFormat) {
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTimeMakeWithSeconds(0.5, preferredTimescale: 44100)
            request.overlapFactor = 0.75
            try analyzer.add(request, withObserver: speechGate)
            soundAnalyzer = analyzer
            print("🔊 [SoundAnalysis] Speech gate active (window=0.5s, overlap=75%)")
        } catch {
            print("⚠️ Speech gate error: \(error)")
        }
    }

    // MARK: - Time Machine
    func applyRetroactiveCorrection(forEventID eventID: UUID, newName: String) {
        guard let index = segmentHistory.firstIndex(where: { $0.id == eventID }) else { return }
        let ghostID       = segmentHistory[index].assignedSpeakerID
        let mistakeVector = segmentHistory[index].vector
        let mistakeContext = segmentHistory[index].locationTag

        print("⏳ Time Machine: User says Event \(eventID) (ID \(ghostID)) is actually '\(newName)'")

        var targetID: Int = -1

        if let existingID = speakerNames.first(where: { $0.value == newName })?.key {
            targetID = existingID
        } else {
            if ghostID != 0 {
                speakerNames[ghostID] = newName
                print("Renamed ID \(ghostID) to \(newName). No merge needed.")
                self.objectWillChange.send()
                return
            }
            let newID = (speakerProfiles.keys.max() ?? 0) + 1
            speakerProfiles[newID] = mistakeVector
            baseAnchors[newID] = mistakeVector
            activeClusters[newID] = [mistakeVector]
            speakerNames[newID] = newName
            targetID = newID
        }

        var mergeCount  = 0
        var rippleCount = 0

        updateProfile(id: targetID, vector: mistakeVector)

        guard let targetProfile = speakerProfiles[targetID] else { return }

        for i in 0..<segmentHistory.count {
            let event = segmentHistory[i]

            if event.assignedSpeakerID == ghostID && ghostID != targetID {
                segmentHistory[i].assignedSpeakerID = targetID
                segmentHistory[i].confidence        = 1.0
                updateProfile(id: targetID, vector: event.vector)
                mergeCount += 1
                continue
            }

            if event.assignedSpeakerID != 0
                && event.assignedSpeakerID != targetID
                && event.assignedSpeakerID != ghostID {

                var score = cosineSim(event.vector, targetProfile)
                if let evLoc = event.locationTag, let mistLoc = mistakeContext, evLoc == mistLoc {
                    score += 0.10
                }

                if score > 0.75 && score > (event.confidence + 0.05) {
                    print("✨ Magic: Found a missed segment at index \(i) (Score: \(score))")
                    segmentHistory[i].assignedSpeakerID = targetID
                    segmentHistory[i].confidence        = score
                    rippleCount += 1
                }
            }
        }

        if ghostID != targetID {
            speakerProfiles.removeValue(forKey: ghostID)
            baseAnchors.removeValue(forKey: ghostID)
            activeClusters.removeValue(forKey: ghostID)
            speakerNames.removeValue(forKey: ghostID)
        }

        self.objectWillChange.send()
    }

    private func addToHistory(vector: [Float], id: Int, score: Float) {
        segmentHistory.append(DiarizationEvent(timestamp: Date(), vector: vector, assignedSpeakerID: id, confidence: score, locationTag: currentLocation))
        if segmentHistory.count > 500 { segmentHistory.removeFirst() }
    }

    // MARK: - Proactive Refinement
    func performRetroactiveRefinement() {
        // Run on background thread to prevent session lag
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            var hasChanges = false
            let profiles = self.speakerProfiles

            for i in 0..<self.segmentHistory.count {
                let event = self.segmentHistory[i]
                let currentID = event.assignedSpeakerID
                let vector = event.vector

                var bestScore: Float = -1.0
                var bestID: Int = currentID

                for (id, profile) in profiles {
                    var score = self.cosineSim(vector, profile)
                    if id == 0 { score += 0.10 } // Maintain restored user bias

                    if score > bestScore {
                        bestScore = score
                        bestID = id
                    }
                }

                // If a significantly better match is found, update it
                let threshold = (bestID == 0) ? self.userMatchThreshold : self.matchThreshold
                let isUnassigned = (currentID == -1)
                let significantImprovement = bestScore > (event.confidence + 0.10)

                if bestID != currentID && bestScore >= threshold && (isUnassigned || significantImprovement) {
                    DispatchQueue.main.async {
                        self.segmentHistory[i].assignedSpeakerID = bestID
                        if isUnassigned {
                            self.segmentHistory[i].confidence = bestScore
                        }
                    }
                    hasChanges = true
                }
            }

            if hasChanges {
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                }
            }
        }
    }
}

// MARK: - SpeechActivityGate
/// Allowlist-based gate: only frames the classifier labels as human speech
/// are allowed through. Noise classes are explicitly rejected.
/// Hysteresis: once the gate opens it stays open for `holdOpen` extra frames
/// so classifier jitter mid-sentence can't flicker it shut.
private class SpeechActivityGate: NSObject, SNResultsObserving {

    // ✅ ALLOW: human vocalisation only
    private let speechLabels: Set<String> = [
        "speech", "whispering", "shout", "laughter", "singing", "humming"
    ]

    // ❌ DENY: non-speech noise classes in the Apple SoundAnalysis taxonomy.
    private let noiseLabels: Set<String> = [
        // Mechanical / HVAC
        "fan", "air_conditioning", "hvac", "mechanical_fan", "white_noise",
        "vacuum_cleaner", "blender", "hair_dryer", "lawn_mower",
        // Vehicle / transport
        "car", "vehicle", "truck", "motorcycle", "bus", "train",
        "aircraft", "airplane", "helicopter", "boat", "ship",
        "car_horn", "horn", "siren", "emergency_vehicle", "traffic",
        "engine", "vehicle_engine", "idling",
        // Environment / room
        "crowd", "background_noise", "noise", "babble", "restaurant_noise",
        "office_ambience", "classroom_ambience", "street_music",
        "rain", "thunder", "wind", "water", "waterfall", "ocean", "stream",
        "fire", "crackling",
        // Alarms & signals
        "alarm", "smoke_detector", "clock_alarm", "telephone", "door_bell",
        "beep", "buzzer",
        // Music / non-speech audio
        "music", "instrument", "piano", "guitar", "drum", "percussion",
        "electronic_music", "pop_music", "hip_hop",
        // Animal
        "dog", "cat", "bird", "animal"
    ]

    /// Minimum confidence for the #1 prediction to be treated as speech.
    /// 0.28 is calibrated for real-room speech: SoundAnalysis typically scores
    /// human voice at 0.30–0.55 in ambient conditions.
    private let speechConfidenceThreshold: Float = 0.28

    /// How many extra classifier frames to stay open after speech is detected.
    /// Each frame is ~0.5 s × (1 – 0.75 overlap) = ~0.125 s effective stride,
    /// so 2 frames ≈ 0.25 s of holdOpen — smooths over inter-word gaps.
    private let holdOpen = 2
    private var holdCounter = 0

    private var _active = false
    private let lock = NSLock()

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }; return _active
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let res = result as? SNClassificationResult,
              let top = res.classifications.first else { return }

        let topLabel = top.identifier
        let topConf  = Float(top.confidence)

        // Gate opens when the best prediction is an unambiguous speech class
        // with sufficient confidence AND is not itself a noise label.
        let isSpeech = speechLabels.contains(topLabel)
                    && topConf >= speechConfidenceThreshold
                    && !noiseLabels.contains(topLabel)

        lock.lock()
        if isSpeech {
            _active = true
            holdCounter = holdOpen          // reset hold timer on each speech frame
        } else if holdCounter > 0 {
            holdCounter -= 1               // burn down the hold — gate stays open
            // _active stays true
        } else {
            _active = false
            if topConf > 0.3 {
                print("🔇 [Gate CLOSED] \(topLabel) @ \(String(format: "%.0f%%", topConf * 100)) — noise suppressed")
            }
        }
        lock.unlock()
    }
}
