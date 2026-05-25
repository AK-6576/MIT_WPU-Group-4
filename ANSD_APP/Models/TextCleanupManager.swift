//
//  TextCleanupManager.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 15/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import Foundation
import FoundationModels // Apple Intelligence Framework

class TextCleanupManager {

    // MARK: - Properties
    private let model = SystemLanguageModel.default

    // Active cleanup tasks keyed by bubble index. Stored so we can cancel
    // a stale in-flight task if a newer one arrives for the same index.
    private var activeTasks: [Int: Task<Void, Never>] = [:]

    // MARK: - API

    /// Schedules an AI cleanup pass for the given text at the given bubble index.
    /// Any previously scheduled (but not yet completed) task for the same index
    /// is cancelled first so we always process the latest text.
    func scheduleCleanup(text: String, at index: Int, completion: @escaping (Int, String) -> Void) {
        // Cancel any in-flight task for this index so we don't deliver stale results.
        activeTasks[index]?.cancel()

        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.performAIProcessing(text: text, index: index, completion: completion)
        }

        activeTasks[index] = task
    }

    // MARK: - Private AI Logic

    private func performAIProcessing(text: String, index: Int, completion: @escaping (Int, String) -> Void) async {
        // Clean up the task entry once we start running.
        await MainActor.run { self.activeTasks.removeValue(forKey: index) }

        // Don't process empty strings.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await MainActor.run { completion(index, text) }
            return
        }

        // Skip obvious placeholder strings.
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "listening..." || lower == "..." || lower == "identifying…" || lower == "identifying..." {
            await MainActor.run { completion(index, text) }
            return
        }

        guard model.isAvailable else {
            print("[TextCleanup] Apple Intelligence not available on this device. Using original text.")
            await MainActor.run { completion(index, text) }
            return
        }

        // Strong, example-driven system prompt so the on-device model knows
        // exactly what punctuation and capitalisation to apply.
        let instructions = """
        You are a punctuation and grammar correction engine for a real-time speech-to-text captioning app used by people with hearing loss.

        YOUR ONLY JOB: Take raw speech-to-text output and return it with correct punctuation, capitalisation, and minimal grammar fixes. Do not change the meaning, do not add or remove words, do not summarise.

        RULES:
        1. Add a period, question mark, or exclamation mark at the end of every sentence.
        2. Add commas where natural pauses or list items occur.
        3. Capitalise the first word of every sentence and proper nouns.
        4. Fix obvious run-on sentences by inserting punctuation — do NOT split into separate lines.
        5. Keep contractions as-is (don't → don't, it's → it's).
        6. If the input is a single word or very short phrase, still capitalise and add a period.
        7. Return ONLY the corrected text. No explanations, no quotes, no extra lines.
        8. Respond in the SAME language as the input.
        9. Never fabricate, add, or remove any words.

        EXAMPLES:
        Input:  hello how are you doing today
        Output: Hello, how are you doing today?

        Input:  i went to the store and i bought milk eggs and bread
        Output: I went to the store and I bought milk, eggs, and bread.

        Input:  what time is the meeting tomorrow
        Output: What time is the meeting tomorrow?

        Input:  yes that sounds good to me
        Output: Yes, that sounds good to me.

        Input:  my name is anshul i am from pune i work in technology
        Output: My name is Anshul. I am from Pune. I work in technology.

        Input:  two thousand and thirty hello
        Output: Two thousand and thirty, hello.

        Input:  nine thousand nine hundred ninety nine
        Output: Nine thousand, nine hundred ninety-nine.
        """

        let prompt = "Input: \(text)\nOutput:"

        do {
            // Check for cancellation before starting the expensive AI call.
            try Task.checkCancellation()

            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: prompt)

            // Check for cancellation again before delivering the result.
            try Task.checkCancellation()

            var cleanedText = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip any accidental surrounding quotes the model may add.
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            // Safety: if the model returned something wildly different in length
            // (more than 3× the original), it hallucinated — fall back to original.
            if cleanedText.count > text.count * 3 || cleanedText.isEmpty {
                cleanedText = text
            }

            // Safety: reject known AI boilerplate responses.
            let boilerplatePrefixes = ["i'm sorry", "as a language model", "as an ai", "i cannot", "i don't"]
            let lowerCleaned = cleanedText.lowercased()
            let isBoilerplate = boilerplatePrefixes.contains { lowerCleaned.hasPrefix($0) }
            if isBoilerplate {
                cleanedText = text
            }

            print("[TextCleanup] ✅ '\(text)' → '\(cleanedText)'")

            await MainActor.run { completion(index, cleanedText) }

        } catch is CancellationError {
            // Task was cancelled because a newer one arrived — silently discard.
            print("[TextCleanup] ⚠️ Task cancelled for index \(index).")
        } catch {
            print("[TextCleanup] ❌ AI cleanup failed: \(error.localizedDescription). Using original text.")
            await MainActor.run { completion(index, text) }
        }
    }

    func cancelAllPendingTasks() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
    }
}
