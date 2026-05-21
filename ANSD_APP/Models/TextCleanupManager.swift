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
    private var workItems: [Int: DispatchWorkItem] = [:]

    // REDUCED: 0.4 second delay for faster response
    private let delay: TimeInterval = 0.4

    // MARK: - API

    func scheduleCleanup(text: String, at index: Int, completion: @escaping (Int, String) -> Void) {

        workItems[index]?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            Task {
                await self.performAIProcessing(text: text, index: index, completion: completion)
            }

            DispatchQueue.main.async {
                self.workItems.removeValue(forKey: index)
            }
        }

        workItems[index] = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Private AI Logic

    private func performAIProcessing(text: String, index: Int, completion: @escaping (Int, String) -> Void) async {
        guard !text.isEmpty, text.count > 3 else {
            await MainActor.run {
                completion(index, text)
            }
            return
        }

        guard model.isAvailable else {
            print("[TextCleanup] FoundationModels not available on this device. Using original text.")
            await MainActor.run {
                completion(index, text)
            }
            return
        }

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

        do {
            let response = try await session.respond(to: prompt)
            var cleanedText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            // Safety filter: Only discard if the response matches known AI boilerplate prefixes or is suspiciously short/generic
            let boilerplatePrefixes = ["i'm sorry", "as a language model", "as an ai", "i cannot process"]
            let lowercaseResponse = cleanedText.lowercased()
            let isBoilerplate = boilerplatePrefixes.contains { prefix in
                lowercaseResponse.hasPrefix(prefix) || (lowercaseResponse.contains(prefix) && cleanedText.count < 30)
            }

            if isBoilerplate {
                cleanedText = text
            }

            await MainActor.run {
                completion(index, cleanedText)
            }
        } catch {
            print("❌ [TextCleanup] AI cleanup failed: \(error.localizedDescription)")
            // Fallback: deliver the original text so the bubble still updates.
            await MainActor.run {
                completion(index, text)
            }
        }
    }

    func cancelAllPendingTasks() {
        workItems.values.forEach { $0.cancel() }
        workItems.removeAll()
    }
}
