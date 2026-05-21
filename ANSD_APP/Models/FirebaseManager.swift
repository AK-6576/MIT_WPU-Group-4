//
//  FirebaseManager.swift
//  ANSD_APP
//
//  Created by Daiwiik Harihar on 20/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import Foundation
import FirebaseCore
import FirebaseDatabase
import FirebaseAuth
import GoogleSignIn

class FirebaseManager {

    static let shared = FirebaseManager()
    private let baseURL = "https://ansd-f90fc-default-rtdb.asia-southeast1.firebasedatabase.app"
    private var ref: DatabaseReference?
    private let databaseRef = Database.database(url: "https://ansd-f90fc-default-rtdb.asia-southeast1.firebasedatabase.app").reference()

    private init() {}

    // Helper to get current authenticated user's ID
    private var currentUID: String? {
        return Auth.auth().currentUser?.uid
    }

    // MARK: - Safety Helper
    /// Firebase keys cannot contain . # $ [ ]
    /// This replaces those characters with underscores to prevent app crashes.
    func sanitizeKey(_ key: String) -> String {
        return key.components(separatedBy: CharacterSet(charactersIn: ".#$[]"))
            .joined(separator: "_")
    }
    // MARK: - Session Management

    /// Sets up the database reference for a specific room.
    /// - Parameters:
    ///   - hostUID: The UID of the room creator (Host).
    ///   - conversationID: The Room Code/ID.
    ///   - isHost: Boolean to determine if current user is starting the session.
    func setupSession(hostUID: String, conversationID: String, isHost: Bool) {
        let safeUID = sanitizeKey(hostUID)
        let safeConvID = sanitizeKey(conversationID)

        guard !safeUID.isEmpty, !safeConvID.isEmpty else {
            // print("DEBUG: Firebase - Cannot setup session with empty IDs")
            return
        }

        // CRITICAL: Both Host and Joiner point to the HOST'S path to share messages
        // Path: users -> {hostUID} -> conversations -> {conversationID}
        self.ref = databaseRef.child("users").child(safeUID).child("conversations").child(safeConvID)

        if isHost {
            ref?.child("status").setValue("active")
            // print("DEBUG: Firebase - Host created room at users/\(safeUID)/conversations/\(safeConvID)")
        } else {
            // print("DEBUG: Firebase - Joiner connected to room at users/\(safeUID)/conversations/\(safeConvID)")
        }
    }

    func endSession() {
        // Only the host usually triggers this, but it updates the shared 'status' node
        ref?.child("status").setValue("ended")
    }

    func observeSessionStatus(completion: @escaping (String) -> Void) {
        ref?.child("status").observe(.value) { snapshot in
            if let status = snapshot.value as? String {
                completion(status)
            }
        }
    }

    // MARK: - Message Handling

    func observeMessages(completion: @escaping ([String: Any]) -> Void) {
        guard let sessionRef = ref?.child("messages") else {
            // print("DEBUG: Firebase - Observer failed. Call setupSession first.")
            return
        }

        // .childAdded pulls all previous history immediately AND stays active for new messages.
        sessionRef.observe(.childAdded) { snapshot, _ in
            if let value = snapshot.value as? [String: Any] {
                completion(value)
            }
        }
    }

    func send(text: String, sender: String, senderID: String) {
        let dict: [String: Any] = [
            "text": text,
            "sender": sender,
            "senderID": senderID,
            "timestamp": ServerValue.timestamp()
        ]
        // This writes to the 'messages' node of whatever room was set in setupSession()
        ref?.child("messages").childByAutoId().setValue(dict)
    }

    // MARK: - Mirroring Logic (Sync across Users)

    /// Saves room metadata to the joiner's personal profile so it appears in their history.
    func linkConversationToJoiner(hostUID: String, conversationID: String, conversationTitle: String) {
        guard let myUID = currentUID else { return }

        let linkData: [String: Any] = [
            "id": conversationID,
            "title": conversationTitle,
            "isJoined": true,
            "sourceHostUID": hostUID, // Pointer back to the host's folder
            "lastUpdated": ServerValue.timestamp()
        ]

        let safeMyUID = sanitizeKey(myUID)
        let safeConvID = sanitizeKey(conversationID)

        // Save to the JOINER'S personal node: users/{joinerUID}/conversations/{roomID}
        databaseRef.child("users").child(safeMyUID).child("conversations").child(safeConvID).updateChildValues(linkData)
    }

    // MARK: - Conversation Sync (Local SwiftData to Personal Firebase)

    func saveConversationMetadata(_ conversation: Conversation) {
        guard let uid = currentUID else { return }
        let safeUID = sanitizeKey(uid)
        let safeConvID = sanitizeKey(conversation.id)

        let metadata: [String: Any] = [
            "id": conversation.id,
            "title": conversation.title,
            "details": conversation.details,
            "category": conversation.category,
            "icon": conversation.icon,
            "date": conversation.date,
            "startTime": conversation.startTime,
            "endTime": conversation.endTime,
            "isPinned": conversation.isPinned,
            "lastUpdated": ServerValue.timestamp()
        ]

        // This backups metadata to the logged-in user's own conversations folder
        databaseRef.child("users").child(safeUID).child("conversations").child(safeConvID).updateChildValues(metadata)
    }

    /// NEW: Deletes conversation metadata from Firebase to ensure permanent deletion.
    func deleteConversationMetadata(convoID: String) {
        guard let uid = currentUID else { return }
        let safeUID = sanitizeKey(uid)
        let safeConvID = sanitizeKey(convoID)
        databaseRef.child("users").child(safeUID).child("conversations").child(safeConvID).removeValue()
        // Also remove from the "history" node used for full transcripts
        databaseRef.child("users").child(safeUID).child("history").child(safeConvID).removeValue()
    }

    /// NEW: Deletes a Quick Action from Firebase.
    func deleteQuickAction(actionID: String) {
        guard let uid = currentUID else { return }
        let safeUID = sanitizeKey(uid)
        let safeCode = sanitizeKey(actionID)

        // 1. Remove from global registry
        databaseRef.child("quick_actions").child(safeCode).removeValue()

        // 2. Remove from Host's Personal Folder
        databaseRef.child("users").child(safeUID).child("quick_actions").child(safeCode).removeValue()

        // 3. Remove from participant nodes (shared_quick_actions)
        databaseRef.child("shared_quick_actions").observeSingleEvent(of: .value) { snapshot in
            guard let allParticipants = snapshot.value as? [String: [String: Any]] else { return }
            for (participantName, actions) in allParticipants where actions[safeCode] != nil {
                self.databaseRef.child("shared_quick_actions").child(participantName).child(safeCode).removeValue()
            }
        }
    }

    /// Saves a COMPLETE conversation including all messages and participants to history.
    func saveFullConversation(_ conversation: Conversation) {
        guard let uid = currentUID else { return }
        let safeUID = sanitizeKey(uid)
        let safeConvID = sanitizeKey(conversation.id)

        // 1. Prepare Metadata
        var metadata: [String: Any] = [
            "id": conversation.id,
            "title": conversation.title,
            "details": conversation.details,
            "category": conversation.category,
            "icon": conversation.icon,
            "date": conversation.date,
            "startTime": conversation.startTime,
            "endTime": conversation.endTime,
            "location": conversation.location,
            "isPinned": conversation.isPinned,
            "lastUpdated": ServerValue.timestamp()
        ]

        if let calendarDate = conversation.calendarDate {
            metadata["calendarDate"] = calendarDate.timeIntervalSince1970
        }

        if let notes = conversation.notes {
            metadata["notes"] = notes
        }

        // 2. Prepare Participants
        var participantsDict: [String: Any] = [:]
        if let participants = conversation.participants {
            for participant in participants {
                participantsDict[participant.id.uuidString] = [
                    "name": participant.name,
                    "summary": participant.summary,
                    "image": participant.image
                ]
            }
        }

        // 3. Prepare Messages
        var messagesDict: [String: Any] = [:]
        if let messages = conversation.messages {
            for message in messages {
                messagesDict[message.id.uuidString] = [
                    "text": message.text,
                    "senderName": message.senderName,
                    "senderId": message.senderId,
                    "isIncoming": message.isIncoming,
                    "isHighlighted": message.isHighlighted,
                    "isEdited": message.isEdited,
                    "timestamp": message.timestamp.timeIntervalSince1970
                ]
            }
        }

        let fullData: [String: Any] = [
            "metadata": metadata,
            "participants": participantsDict,
            "messages": messagesDict
        ]

        databaseRef.child("users").child(safeUID).child("history").child(safeConvID).setValue(fullData) { error, _ in
            if let error = error {
                print("Firebase: Failed to save full conversation: \(error.localizedDescription)")
            } else {
                print("Firebase: Successfully synced full transcript for: \(conversation.title)")
            }
        }

        // Also update the simple metadata list for quick fetching
        saveConversationMetadata(conversation)
    }

    /// Restores full conversation history (messages + participants) for a given ID
    func fetchFullConversation(uid: String, conversationID: String, completion: @escaping ([String: Any]?) -> Void) {
        let safeUID = sanitizeKey(uid)
        let safeConvID = sanitizeKey(conversationID)
        databaseRef.child("users").child(safeUID).child("history").child(safeConvID).observeSingleEvent(of: .value) { snapshot in
            completion(snapshot.value as? [String: Any])
        }
    }

    func stop() {
        ref?.removeAllObservers()
        ref = nil
    }

    // MARK: - Quick Action Sync Integration
    func saveQuickActionMetadata(_ action: RoutineConversation, hostUID: String) {
        let safeHost = sanitizeKey(hostUID)
        guard let code = action.roomCode else { return }
        let safeCode = sanitizeKey(code)

        let metadata: [String: Any] = [
            "id": action.id,
            "categoryTitle": action.categoryTitle,
            "conversationTopic": action.conversationTopic,
            "startTime": action.startTime,
            "status": action.status,
            "roomCode": code,
            "hostUID": safeHost,
            "iconName": action.iconName,
            "topicImage": action.topicImage,
            "timeImage": action.timeImage,
            "date": action.date ?? "",
            "description": action.description ?? "",
            "participantNames": action.participantNames,
            "participantEmails": action.participantEmails ?? [],
            "participantPhones": action.participantPhones ?? [],
            "lastUpdated": ServerValue.timestamp()
        ]

        // 1. Save to global Quick Actions registry so Joiners can look it up by code
        databaseRef.child("quick_actions").child(safeCode).setValue(metadata)

        // 2. Save to Host's Personal Folder
        databaseRef.child("users").child(safeHost).child("quick_actions").child(safeCode).setValue(metadata)

        // 3. Save to Participants' nodes so they can observe it (by name)
        for participant in action.participantNames {
            let safeParticipant = sanitizeKey(participant.trimmingCharacters(in: .whitespacesAndNewlines))
            if !safeParticipant.isEmpty {
                databaseRef.child("shared_quick_actions").child(safeParticipant).child(safeCode).setValue(metadata)
            }
        }

        // 4. SYNC TO PARTICIPANTS' PERSONAL NODES (Multi-Index Lookup)

        // Helper to perform the actual write to a discovered UID
        let syncToActionPersonalNode: (String?) -> Void = { [weak self] uid in
            guard let self = self, let discoveredUID = uid else { return }
            let safeParticipantUID = self.sanitizeKey(discoveredUID)
            self.databaseRef.child("users").child(safeParticipantUID).child("quick_actions").child(safeCode).setValue(metadata)
        }

        // 4a. Sync by Email
        for email in action.participantEmails ?? [] {
            lookupUID(byEmail: email, completion: syncToActionPersonalNode)
        }

        // 4b. Sync by Phone
        for phone in action.participantPhones ?? [] {
            lookupUID(byPhone: phone, completion: syncToActionPersonalNode)
        }

        // 4c. Sync by Full Name (Fallback for dummy emails)
        for name in action.participantNames {
            lookupUID(byFullName: name, completion: syncToActionPersonalNode)
        }
    }

    // MARK: - Generic Observers

    // Observes Quick Actions assigned specifically to the user (by checking their name against the shared node).
    func observeSharedQuickActions(forUserName userName: String, onAddedOrChanged: @escaping ([String: Any]) -> Void, onRemoved: @escaping (String) -> Void) {
        let safeName = sanitizeKey(userName.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !safeName.isEmpty else { return }

        databaseRef.child("shared_quick_actions").child(safeName).observe(.childAdded) { snapshot in
            if let value = snapshot.value as? [String: Any] {
                onAddedOrChanged(value)
            }
        }

        databaseRef.child("shared_quick_actions").child(safeName).observe(.childChanged) { snapshot in
            if let value = snapshot.value as? [String: Any] {
                onAddedOrChanged(value)
            }
        }

        databaseRef.child("shared_quick_actions").child(safeName).observe(.childRemoved) { snapshot in
            onRemoved(snapshot.key)
        }
    }

    // MARK: - Quick Action Presence Tracking

    /// Mark a user as "online" in a Quick Action room
    func setPresence(roomCode: String, userName: String) {
        let safeCode = sanitizeKey(roomCode)
        let safeName = sanitizeKey(userName)
        databaseRef.child("quick_actions").child(safeCode).child("presence").child(safeName).setValue(true)
    }

    /// Remove a user's presence when they leave the session
    func removePresence(roomCode: String, userName: String) {
        let safeCode = sanitizeKey(roomCode)
        let safeName = sanitizeKey(userName)
        databaseRef.child("quick_actions").child(safeCode).child("presence").child(safeName).removeValue()
    }

    /// Observe presence in real time — returns a Set of online sanitized user names
    func observePresence(roomCode: String, completion: @escaping (Set<String>) -> Void) {
        let safeCode = sanitizeKey(roomCode)
        databaseRef.child("quick_actions").child(safeCode).child("presence").observe(.value) { snapshot in
            var onlineNames = Set<String>()
            if let dict = snapshot.value as? [String: Any] {
                for key in dict.keys {
                    onlineNames.insert(key)
                }
            }
            completion(onlineNames)
        }
    }

    /// Stop observing presence for a room
    func stopObservingPresence(roomCode: String) {
        let safeCode = sanitizeKey(roomCode)
        databaseRef.child("quick_actions").child(safeCode).child("presence").removeAllObservers()
    }

    // MARK: - Authentication
    func registerRoom(code: String, hostUID: String) {
        let safeCode = sanitizeKey(code)
        databaseRef.child("room_registry").child(safeCode).setValue(["hostUID": hostUID])
    }

    /// Guest calls this to find the hostUID using only the Room Code
    func findHostID(for code: String, completion: @escaping (String?) -> Void) {
        let safeCode = sanitizeKey(code)
        databaseRef.child("room_registry").child(safeCode).child("hostUID").observeSingleEvent(of: .value) { snapshot in
            completion(snapshot.value as? String)
        }
    }

    // MARK: - Google Sign-In

    func signInWithGoogle(presenting: UIViewController, completion: @escaping (Result<(User, Bool), Error>) -> Void) {
        // 1. Get Client ID from Firebase options
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            completion(.failure(NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Firebase Client ID not found"])))
            return
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        // 2. Start Google Sign-In Flow
        GIDSignIn.sharedInstance.signIn(withPresenting: presenting) { [weak self] signInResult, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let user = signInResult?.user,
                  let idToken = user.idToken?.tokenString else {
                completion(.failure(NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Google Sign-In failed to return tokens"])))
                return
            }

            // 3. Create Firebase Credential
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: user.accessToken.tokenString)

            // 4. Authenticate with Firebase
            Auth.auth().signIn(with: credential) { authResult, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let firebaseUser = authResult?.user else {
                    completion(.failure(NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Firebase Sign-In failed"])))
                    return
                }

                // 5. If new user, save initial profile to RTDB
                let isNewUser = authResult?.additionalUserInfo?.isNewUser ?? false
                if isNewUser {
                    let firstName = user.profile?.givenName ?? ""
                    let lastName = user.profile?.familyName ?? ""
                    let fullName = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
                    let email = firebaseUser.email ?? ""

                    let userProfile: [String: Any] = [
                        "firstName": firstName,
                        "lastName": lastName,
                        "email": email,
                        "phoneNumber": firebaseUser.phoneNumber ?? "",
                        "createdAt": ServerValue.timestamp()
                    ]

                    let safeUID = self.sanitizeKey(firebaseUser.uid)
                    let safeEmail = self.sanitizeKey(email.lowercased())
                    let safeFullName = self.sanitizeKey(fullName.lowercased())
                    let safePhone = self.sanitizeKey(firebaseUser.phoneNumber ?? "")

                    // 1. Save standard profile
                    self.databaseRef.child("users").child(safeUID).child("profile").setValue(userProfile)

                    // 2. Update all lookup indices
                    if !safeEmail.isEmpty {
                        self.databaseRef.child("users_by_email").child(safeEmail).setValue(firebaseUser.uid)
                    }
                    if !safeFullName.isEmpty {
                        self.databaseRef.child("users_by_fullname").child(safeFullName).setValue(firebaseUser.uid)
                    }
                    if !safePhone.isEmpty {
                        self.databaseRef.child("users_by_phone").child(safePhone).setValue(firebaseUser.uid)
                    }
                }

                completion(.success((firebaseUser, isNewUser)))
            }
        }
    }

    func createAccount(details: [String: String], completion: @escaping (Result<User, Error>) -> Void) {
        guard let email = details["email"], let password = details["password"] else {
            completion(.failure(NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Email and password are required"])))
            return
        }

        Auth.auth().createUser(withEmail: email, password: password) { authResult, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let user = authResult?.user else {
                completion(.failure(NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve user after creation"])))
                return
            }

            let firstName = details["firstName"] ?? ""
            let lastName = details["lastName"] ?? ""
            let fullName = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
            let phoneNumber = details["phoneNumber"] ?? ""

            let userProfile: [String: Any] = [
                "firstName": firstName,
                "lastName": lastName,
                "email": email,
                "phoneNumber": phoneNumber,
                "createdAt": ServerValue.timestamp()
            ]

            let safeUID = self.sanitizeKey(user.uid)
            let safeEmail = self.sanitizeKey(email.lowercased())
            let safeFullName = self.sanitizeKey(fullName.lowercased())
            let safePhone = self.sanitizeKey(phoneNumber)

            // 1. Save standard profile
            self.databaseRef.child("users").child(safeUID).child("profile").setValue(userProfile)

            // 2. Update lookup indices (Email is key for Account, but we index all for sync)
            if !safeEmail.isEmpty { self.databaseRef.child("users_by_email").child(safeEmail).setValue(user.uid) }
            if !safeFullName.isEmpty { self.databaseRef.child("users_by_fullname").child(safeFullName).setValue(user.uid) }
            if !safePhone.isEmpty { self.databaseRef.child("users_by_phone").child(safePhone).setValue(user.uid) }

            completion(.success(user))
        }
    }

    func loginUser(details: [String: String], completion: @escaping (Result<User, Error>) -> Void) {
        guard let email = details["email"], let password = details["password"] else {
            completion(.failure(NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Email and password are required"])))
            return
        }

        Auth.auth().signIn(withEmail: email, password: password) { authResult, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            if let user = authResult?.user {
                completion(.success(user))
            } else {
                completion(.failure(NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve user after sign-in"])))
            }
        }
    }

    // MARK: - User Profile Fetching
    func fetchUserProfile(uid: String, completion: @escaping ([String: Any]?) -> Void) {
        let safeUID = sanitizeKey(uid)
        databaseRef.child("users").child(safeUID).child("profile").observeSingleEvent(of: .value) { snapshot in
            if let profileData = snapshot.value as? [String: Any] {
                completion(profileData)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - Conversation History Fetch (Login Restore)
    func fetchConversationHistory(uid: String, completion: @escaping ([[String: Any]]) -> Void) {
        let safeUID = sanitizeKey(uid)
        databaseRef.child("users").child(safeUID).child("conversations").observeSingleEvent(of: .value) { snapshot in
            var conversations: [[String: Any]] = []
            if let dict = snapshot.value as? [String: Any] {
                for (_, value) in dict {
                    if let convo = value as? [String: Any] {
                        conversations.append(convo)
                    }
                }
            }
            completion(conversations)
        }
    }

    // MARK: - Quick Actions Fetch (Login Restore)
    func fetchQuickActions(uid: String, completion: @escaping ([[String: Any]]) -> Void) {
        let safeUID = sanitizeKey(uid)
        databaseRef.child("users").child(safeUID).child("quick_actions").observeSingleEvent(of: .value) { snapshot in
            var actions: [[String: Any]] = []
            if let dict = snapshot.value as? [String: Any] {
                for (_, value) in dict {
                    if let action = value as? [String: Any] {
                        actions.append(action)
                    }
                }
            }
            completion(actions)
        }
    }

    // MARK: - UID Lookup (SECURE)

    /// NEW: Search by Email (Precise) instead of First Name (Ambiguous)
    func lookupUID(byEmail email: String, completion: @escaping (String?) -> Void) {
        let safeEmail = sanitizeKey(email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        databaseRef.child("users_by_email").child(safeEmail).observeSingleEvent(of: .value) { snapshot in
            completion(snapshot.value as? String)
        }
    }

    func lookupUID(byPhone phone: String, completion: @escaping (String?) -> Void) {
        let safePhone = sanitizeKey(phone.trimmingCharacters(in: .whitespacesAndNewlines))
        databaseRef.child("users_by_phone").child(safePhone).observeSingleEvent(of: .value) { snapshot in
            completion(snapshot.value as? String)
        }
    }

    func lookupUID(byFullName name: String, completion: @escaping (String?) -> Void) {
        let safeName = sanitizeKey(name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        databaseRef.child("users_by_fullname").child(safeName).observeSingleEvent(of: .value) { snapshot in
            completion(snapshot.value as? String)
        }
    }

    /// DEPRECATED: Use lookupUID(byEmail:) for security
    func lookupUID(byFirstName name: String, completion: @escaping (String?) -> Void) {
        databaseRef.child("users").observeSingleEvent(of: .value) { snapshot in
            if let users = snapshot.value as? [String: Any] {
                for (uid, userData) in users {
                    if let userDict = userData as? [String: Any],
                       let profile = userDict["profile"] as? [String: Any],
                       let firstName = profile["firstName"] as? String,
                       firstName.lowercased() == name.lowercased() {
                        completion(uid)
                        return
                    }
                }
            }
            completion(nil)
        }
    }

    // MARK: - Sign Out & Data Purge
    func signOut(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try Auth.auth().signOut()
            print("Successfully signed out")
            completion(.success(()))
        } catch let signOutError {
            print("Error signing out: \(signOutError)")
            completion(.failure(signOutError))
        }
    }

}
