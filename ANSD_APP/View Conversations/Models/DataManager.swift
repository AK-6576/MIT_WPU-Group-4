//
//  DataManager.swift
//  ANSD_APP
//
//  Created by Omkar Varpe on 15/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//
import Foundation
import SwiftData
import UIKit
import FirebaseAuth

class DataManager {
    static let shared = DataManager()

    private var container: ModelContainer?
    private var modelContext: ModelContext?

    var context: ModelContext? {
        return modelContext
    }

    private init() {
        // print("DEBUG: DataManager.init() STARTED")
        do {
            let container = try ModelContainer(for: Conversation.self, Message.self, Participant.self, VoiceProfile.self)
            self.container = container
            self.modelContext = container.mainContext
            print("DataManager: Successfully initialized self-contained ModelContainer.")
        } catch {
            print("DataManager ERROR: Failed to initialize ModelContainer. \(error.localizedDescription)")
        }
    }

    /// Returns the current authenticated user's UID, or empty string
    private var currentUID: String {
        let uid = Auth.auth().currentUser?.uid ?? ""
        if uid.isEmpty { print("DataManager WARNING: currentUID is empty!") }
        return uid
    }

    // 1. FETCH ALL: Gets all conversations for the current user
    func fetchConversations() -> [Conversation] {
        guard let context = context else {
            print("DataManager ERROR: ModelContext is nil in fetchConversations()")
            return []
        }
        let uid = currentUID

        // Only fetch conversations belonging to the logged-in user
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.ownerUID == uid },
            sortBy: [SortDescriptor(\.calendarDate, order: .reverse)]
        )

        do {
            let fetchedData = try context.fetch(descriptor)
            print("DataManager: Successfully fetched \(fetchedData.count) conversations for UID \(uid).")

            if fetchedData.isEmpty {
                let allItems = try? context.fetch(FetchDescriptor<Conversation>())
                // print("DataManager DEBUG: Total conversations in DB (unfiltered): \(allItems?.count ?? 0)")
                if let first = allItems?.first {
                    // print("DataManager DEBUG: Example first item has UID: '\(first.ownerUID)'")
                }
            }

            return fetchedData
        } catch {
            print("DataManager: Failed to fetch data. Error: \(error.localizedDescription)")
            return []
        }
    }

    // 2. FETCH BY ID: Finds a single specific conversation (used by HomeViewController)
    func fetchConversation(byId id: String) -> Conversation? {
        guard let context = context else { return nil }

        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })

        do {
            let results = try context.fetch(descriptor)
            return results.first
        } catch {
            print("DataManager: Failed to fetch conversation by ID. Error: \(error.localizedDescription)")
            return nil
        }
    }

    // 3. ADD: Inserts a new conversation into the database (stamps ownerUID)
    func addConversation(_ conversation: Conversation) {
        guard let context = context else {
            print("DataManager ERROR: ModelContext is nil in addConversation()")
            return
        }

        // Tag the conversation with the current user's UID
        if conversation.ownerUID.isEmpty {
            conversation.ownerUID = currentUID
        }

        context.insert(conversation)
        saveData()

        // Push the metadata to the user's Firebase history
        FirebaseManager.shared.saveConversationMetadata(conversation)
    }

    // 4. DELETE: Removes a conversation from the database
    func deleteConversation(_ conversation: Conversation) {
        guard let context = context else { return }

        // 1. Delete from Firebase History
        FirebaseManager.shared.deleteConversationMetadata(convoID: conversation.id)

        // 2. Delete from Local SwiftData
        context.delete(conversation)
        saveData()
    }

    // 5. SAVE: Commits any edits made to existing objects
    func saveData() {
        guard let context = context else {
            print("DataManager ERROR: ModelContext is nil in saveData()")
            return
        }
        do {
            try context.save()
            print("DataManager: Successfully saved changes to SwiftData.")
            // Trigger UI refresh for conversation-related views (Home Screen, View Conversations, etc.)
            NotificationCenter.default.post(name: NSNotification.Name("ConversationHistoryUpdated"), object: nil)
        } catch {
            print("DataManager: Failed to save context. Error: \(error.localizedDescription)")
        }
    }

    // 6. FETCH BY DATE: Fetches conversations for a specific day (scoped by UID)
    func fetchConversations(for date: Date) -> [Conversation] {
        guard let context = context else { return [] }
        let uid = currentUID

        // Define the start and end of the selected day
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
        let fallbackDate = Date.distantPast

        // Fetch using a Predicate to filter at the database level, scoped by UID
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                $0.ownerUID == uid &&
                ($0.calendarDate ?? fallbackDate) >= startOfDay &&
                ($0.calendarDate ?? fallbackDate) < endOfDay
            },
            sortBy: [SortDescriptor(\.calendarDate, order: .reverse)]
        )

        do {
            let fetchedData = try context.fetch(descriptor)
            print("DataManager: Successfully fetched \(fetchedData.count) conversations for date: \(date)")
            return fetchedData
        } catch {
            print("DataManager: Failed to fetch filtered data. Error: \(error.localizedDescription)")
            return []
        }
    }

    // 7. DELETE ALL FOR USER: Clears all SwiftData conversations belonging to a UID
    func deleteAllConversations(forUID uid: String) {
        guard let context = context else { return }
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.ownerUID == uid })
        if let conversations = try? context.fetch(descriptor) {
            for convo in conversations {
                context.delete(convo)
            }
            saveData()
        }
    }
}
