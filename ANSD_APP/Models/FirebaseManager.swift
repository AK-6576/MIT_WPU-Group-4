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
import CryptoKit

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
        let safeConvID = CryptoHelper.hashIdentifier(conversationID.uppercased())
        
        guard !safeUID.isEmpty, !safeConvID.isEmpty else {
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
            guard let value = snapshot.value as? [String: Any] else { return }
            
            DispatchQueue.global(qos: .userInitiated).async {
                var decryptedValue = value
                
                // Decrypt PII
                if let encryptedText = value["text"] as? String {
                    decryptedValue["text"] = CryptoHelper.decryptOrOriginal(encryptedText)
                }
                if let encryptedSender = value["sender"] as? String {
                    decryptedValue["sender"] = CryptoHelper.decryptOrOriginal(encryptedSender)
                }
                
                DispatchQueue.main.async {
                    completion(decryptedValue)
                }
            }
        }
    }
    
    func send(text: String, sender: String, senderID: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let encryptedText = CryptoHelper.encrypt(text) ?? ""
            let encryptedSender = CryptoHelper.encrypt(sender) ?? ""
            
            let dict: [String: Any] = [
                "text": encryptedText,
                "sender": encryptedSender,
                "senderID": senderID,
                "timestamp": ServerValue.timestamp()
            ]
            
            // This writes to the 'messages' node of whatever room was set in setupSession()
            self?.ref?.child("messages").childByAutoId().setValue(dict)
        }
    }
    
    // MARK: - Mirroring Logic (Sync across Users)
    
    /// Saves room metadata to the joiner's personal profile so it appears in their history.
    func linkConversationToJoiner(hostUID: String, conversationID: String, conversationTitle: String) {
        guard let myUID = currentUID else { return }
        
        let linkData: [String: Any] = [
            "id": CryptoHelper.encrypt(conversationID) ?? "",
            "title": CryptoHelper.encrypt(conversationTitle) ?? "",
            "isJoined": true,
            "sourceHostUID": hostUID, // Pointer back to the host's folder
            "lastUpdated": ServerValue.timestamp()
        ]
        
        let safeMyUID = sanitizeKey(myUID)
        let safeConvID = CryptoHelper.hashIdentifier(conversationID.uppercased())
        
        // Save to the JOINER'S personal node: users/{joinerUID}/conversations/{roomID}
        databaseRef.child("users").child(safeMyUID).child("conversations").child(safeConvID).updateChildValues(linkData)
    }
    
    // MARK: - Conversation Sync (Local SwiftData to Personal Firebase)
    
    func saveConversationMetadata(_ conversation: Conversation) {
        guard let uid = currentUID else { return }
        let safeUID = sanitizeKey(uid)
        let safeConvID = CryptoHelper.hashIdentifier(conversation.id.uppercased())
        
        let metadata: [String: Any] = [
            "id": CryptoHelper.encrypt(conversation.id) ?? "",
            "title": CryptoHelper.encrypt(conversation.title) ?? "",
            "details": CryptoHelper.encrypt(conversation.details) ?? "",
            "category": CryptoHelper.encrypt(conversation.category) ?? "",
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
        let safeConvID = CryptoHelper.hashIdentifier(convoID.uppercased())
        databaseRef.child("users").child(safeUID).child("conversations").child(safeConvID).removeValue()
        // Also remove from the "history" node used for full transcripts
        databaseRef.child("users").child(safeUID).child("history").child(safeConvID).removeValue()
    }
    
    /// NEW: Deletes a Quick Action from Firebase.
    func deleteQuickAction(actionID: String) {
        guard let uid = currentUID else { return }
        let safeUID = sanitizeKey(uid)
        let safeCode = CryptoHelper.hashIdentifier(actionID.uppercased())
        
        // 1. Remove from global registry
        databaseRef.child("quick_actions").child(safeCode).removeValue()
        
        // 2. Remove from Host's Personal Folder
        databaseRef.child("users").child(safeUID).child("quick_actions").child(safeCode).removeValue()
        
        // 3. Remove from participant nodes (shared_quick_actions)
        databaseRef.child("shared_quick_actions").observeSingleEvent(of: .value) { snapshot in
            guard let allParticipants = snapshot.value as? [String: [String: Any]] else { return }
            for (participantName, actions) in allParticipants {
                if actions[safeCode] != nil {
                    self.databaseRef.child("shared_quick_actions").child(participantName).child(safeCode).removeValue()
                }
            }
        }
    }
    
    
    
    /// Saves a COMPLETE conversation including all messages and participants to history.
    func saveFullConversation(_ conversation: Conversation) {
        guard let uid = currentUID else { return }
        let safeUID = sanitizeKey(uid)
        let safeConvID = CryptoHelper.hashIdentifier(conversation.id.uppercased())
        
        // 1. Prepare Metadata
        var metadata: [String: Any] = [
            "id": CryptoHelper.encrypt(conversation.id) ?? "",
            "title": CryptoHelper.encrypt(conversation.title) ?? "",
            "details": CryptoHelper.encrypt(conversation.details) ?? "",
            "category": CryptoHelper.encrypt(conversation.category) ?? "",
            "icon": conversation.icon,
            "date": conversation.date,
            "startTime": conversation.startTime,
            "endTime": conversation.endTime,
            "location": CryptoHelper.encrypt(conversation.location ?? "") ?? "",
            "isPinned": conversation.isPinned,
            "lastUpdated": ServerValue.timestamp()
        ]
        
        if let calendarDate = conversation.calendarDate {
            metadata["calendarDate"] = calendarDate.timeIntervalSince1970
        }
        
        if let notes = conversation.notes {
            metadata["notes"] = CryptoHelper.encrypt(notes) ?? ""
        }
        
        // 2. Prepare Participants
        var participantsDict: [String: Any] = [:]
        if let participants = conversation.participants {
            for participant in participants {
                participantsDict[participant.id.uuidString] = [
                    "name": CryptoHelper.encrypt(participant.name) ?? "",
                    "summary": CryptoHelper.encrypt(participant.summary) ?? "",
                    "image": participant.image
                ]
            }
        }
        
        // 3. Prepare Messages
        var messagesDict: [String: Any] = [:]
        if let messages = conversation.messages {
            for message in messages {
                messagesDict[message.id.uuidString] = [
                    "text": CryptoHelper.encrypt(message.text) ?? "",
                    "senderName": CryptoHelper.encrypt(message.senderName) ?? "",
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
        let safeConvID = CryptoHelper.hashIdentifier(conversationID.uppercased())
        databaseRef.child("users").child(safeUID).child("history").child(safeConvID).observeSingleEvent(of: .value) { snapshot in
            guard var data = snapshot.value as? [String: Any] else {
                completion(nil)
                return
            }
            
            if var metadata = data["metadata"] as? [String: Any] {
                if let id = metadata["id"] as? String { metadata["id"] = CryptoHelper.decrypt(id) ?? "" }
                if let t = metadata["title"] as? String { metadata["title"] = CryptoHelper.decrypt(t) ?? "" }
                if let d = metadata["details"] as? String { metadata["details"] = CryptoHelper.decrypt(d) ?? "" }
                if let c = metadata["category"] as? String { metadata["category"] = CryptoHelper.decrypt(c) ?? "" }
                if let l = metadata["location"] as? String { metadata["location"] = CryptoHelper.decrypt(l) ?? "" }
                if let n = metadata["notes"] as? String { metadata["notes"] = CryptoHelper.decrypt(n) ?? "" }
                data["metadata"] = metadata
            }
            
            if var participants = data["participants"] as? [String: [String: Any]] {
                for (key, var p) in participants {
                    if let n = p["name"] as? String { p["name"] = CryptoHelper.decrypt(n) ?? "" }
                    if let s = p["summary"] as? String { p["summary"] = CryptoHelper.decrypt(s) ?? "" }
                    participants[key] = p
                }
                data["participants"] = participants
            }
            
            if var messages = data["messages"] as? [String: [String: Any]] {
                for (key, var m) in messages {
                    if let t = m["text"] as? String { m["text"] = CryptoHelper.decrypt(t) ?? "" }
                    if let sn = m["senderName"] as? String { m["senderName"] = CryptoHelper.decrypt(sn) ?? "" }
                    messages[key] = m
                }
                data["messages"] = messages
            }
            
            completion(data)
        }
    }
    
    func stop() {
        ref?.removeAllObservers()
        ref = nil
    }
    
    // MARK: - Quick Action Sync Integration
    func saveQuickActionMetadata(_ action: RoutineConversation, hostUID: String) {        let safeHost = sanitizeKey(hostUID)
        guard let code = action.roomCode else { return }
        let safeCode = CryptoHelper.hashIdentifier(code.uppercased())
        
        let metadata: [String: Any] = [
            "id": CryptoHelper.encrypt(action.id) ?? "",
            "categoryTitle": CryptoHelper.encrypt(action.categoryTitle) ?? "",
            "conversationTopic": CryptoHelper.encrypt(action.conversationTopic) ?? "",
            "startTime": action.startTime,
            "status": action.status,
            "roomCode": CryptoHelper.encrypt(code) ?? "",
            "hostUID": safeHost, // Host UID is hashed so this doesn't expose PII,
            "iconName": action.iconName,
            "topicImage": action.topicImage,
            "timeImage": action.timeImage,
            "date": action.date ?? "",
            "description": CryptoHelper.encrypt(action.description ?? "") ?? "",
            "participantNames": action.participantNames.compactMap { CryptoHelper.encrypt($0) },
            "participantEmails": (action.participantEmails ?? []).compactMap { CryptoHelper.encrypt($0) },
            "participantPhones": (action.participantPhones ?? []).compactMap { CryptoHelper.encrypt($0) },
            "lastUpdated": ServerValue.timestamp()
        ]
        
        // 1. Save to global Quick Actions registry so Joiners can look it up by code
        databaseRef.child("quick_actions").child(safeCode).setValue(metadata)
        
        // 2. Save to Host's Personal Folder
        databaseRef.child("users").child(safeHost).child("quick_actions").child(safeCode).setValue(metadata)
        
        // 3. Save to Participants' nodes so they can observe it (by name)
        for participant in action.participantNames {
            let safeParticipant = CryptoHelper.hashIdentifier(participant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            if !safeParticipant.isEmpty {
                databaseRef.child("shared_quick_actions").child(safeParticipant).child(safeCode).setValue(metadata)
            }
        }
        
        // 4. SYNC TO PARTICIPANTS' PERSONAL NODES (Multi-Index Lookup)
        
        // Helper to perform the actual write to a discovered UID
        let syncToActionPersonalNode: (String?) -> Void = { [weak self] uid in
            guard let self = self, let discoveredUID = uid else { return }
            let safeParticipantUID = sanitizeKey(discoveredUID)
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
        let safeName = CryptoHelper.hashIdentifier(userName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !safeName.isEmpty else { return }
        
        let decryptAction: ([String: Any]) -> [String: Any] = { value in
            var action = value
            if let id = action["id"] as? String { action["id"] = CryptoHelper.decrypt(id) ?? "" }
            if let rc = action["roomCode"] as? String { action["roomCode"] = CryptoHelper.decrypt(rc) ?? "" }
            if let ct = action["categoryTitle"] as? String { action["categoryTitle"] = CryptoHelper.decrypt(ct) ?? "" }
            if let convT = action["conversationTopic"] as? String { action["conversationTopic"] = CryptoHelper.decrypt(convT) ?? "" }
            if let desc = action["description"] as? String { action["description"] = CryptoHelper.decrypt(desc) ?? "" }
            if let pNames = action["participantNames"] as? [String] { action["participantNames"] = pNames.compactMap { CryptoHelper.decrypt($0) } }
            if let pEmails = action["participantEmails"] as? [String] { action["participantEmails"] = pEmails.compactMap { CryptoHelper.decrypt($0) } }
            if let pPhones = action["participantPhones"] as? [String] { action["participantPhones"] = pPhones.compactMap { CryptoHelper.decrypt($0) } }
            return action
        }
        
        databaseRef.child("shared_quick_actions").child(safeName).observe(.childAdded) { snapshot in
            if let value = snapshot.value as? [String: Any] {
                onAddedOrChanged(decryptAction(value))
            }
        }
        
        databaseRef.child("shared_quick_actions").child(safeName).observe(.childChanged) { snapshot in
            if let value = snapshot.value as? [String: Any] {
                onAddedOrChanged(decryptAction(value))
            }
        }
        
        databaseRef.child("shared_quick_actions").child(safeName).observe(.childRemoved) { snapshot in
            onRemoved(snapshot.key)
        }
    }
    
    // MARK: - Quick Action Presence Tracking
    
    /// Mark a user as "online" in a Quick Action room
    func setPresence(roomCode: String, userName: String) {
        let safeCode = CryptoHelper.hashIdentifier(roomCode.uppercased())
        let safeNameHash = CryptoHelper.hashIdentifier(userName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let encryptedName = CryptoHelper.encrypt(userName) ?? ""
        databaseRef.child("quick_actions").child(safeCode).child("presence").child(safeNameHash).setValue(encryptedName)
    }
    
    /// Remove a user's presence when they leave the session
    func removePresence(roomCode: String, userName: String) {
        let safeCode = CryptoHelper.hashIdentifier(roomCode.uppercased())
        let safeNameHash = CryptoHelper.hashIdentifier(userName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        databaseRef.child("quick_actions").child(safeCode).child("presence").child(safeNameHash).removeValue()
    }
    
    /// Observe presence in real time — returns a Set of online decrypted user names
    func observePresence(roomCode: String, completion: @escaping (Set<String>) -> Void) {
        let safeCode = CryptoHelper.hashIdentifier(roomCode.uppercased())
        databaseRef.child("quick_actions").child(safeCode).child("presence").observe(.value) { snapshot in
            var onlineNames = Set<String>()
            if let dict = snapshot.value as? [String: Any] {
                for (_, value) in dict {
                    if let encryptedName = value as? String, let decryptedName = CryptoHelper.decrypt(encryptedName) {
                        onlineNames.insert(decryptedName)
                    }
                }
            }
            completion(onlineNames)
        }
    }
    
    /// Stop observing presence for a room
    func stopObservingPresence(roomCode: String) {
        let safeCode = CryptoHelper.hashIdentifier(roomCode.uppercased())
        databaseRef.child("quick_actions").child(safeCode).child("presence").removeAllObservers()
    }
    
    // MARK: - Authentication
    func registerRoom(code: String, hostUID: String) {
        let safeCode = CryptoHelper.hashIdentifier(code.uppercased())
        databaseRef.child("room_registry").child(safeCode).setValue(["hostUID": CryptoHelper.encrypt(hostUID) ?? ""])
    }
    
    /// Guest calls this to find the hostUID using only the Room Code
    func findHostID(for code: String, completion: @escaping (String?) -> Void) {
        let safeCode = CryptoHelper.hashIdentifier(code.uppercased())
        databaseRef.child("room_registry").child(safeCode).child("hostUID").observeSingleEvent(of: .value) { snapshot in
            if let encryptedUID = snapshot.value as? String {
                completion(CryptoHelper.decrypt(encryptedUID) ?? encryptedUID)
            } else {
                let legacyCode = self.sanitizeKey(code)
                self.databaseRef.child("room_registry").child(legacyCode).child("hostUID").observeSingleEvent(of: .value) { legacySnapshot in
                    if let legacyUID = legacySnapshot.value as? String {
                        completion(CryptoHelper.decrypt(legacyUID) ?? legacyUID)
                    } else {
                        completion(nil)
                    }
                }
            }
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
                        "firstName": CryptoHelper.encrypt(firstName) ?? "",
                        "lastName": CryptoHelper.encrypt(lastName) ?? "",
                        "email": CryptoHelper.encrypt(email) ?? "",
                        "phoneNumber": CryptoHelper.encrypt(firebaseUser.phoneNumber ?? "") ?? "",
                        "createdAt": ServerValue.timestamp()
                    ]
                    
                    let safeUID = self.sanitizeKey(firebaseUser.uid)
                    let safeEmail = CryptoHelper.hashIdentifier(email.lowercased())
                    let safeFullName = CryptoHelper.hashIdentifier(fullName.lowercased())
                    let safePhone = CryptoHelper.hashIdentifier(firebaseUser.phoneNumber ?? "")
                    
                    // 1. Save standard profile
                    self.databaseRef.child("users").child(safeUID).child("profile").setValue(userProfile)
                    
                    // 2. Update all lookup indices
                    if !email.isEmpty {
                        self.databaseRef.child("users_by_email").child(safeEmail).setValue(CryptoHelper.encrypt(firebaseUser.uid) ?? "")
                    }
                    if !fullName.isEmpty {
                        self.databaseRef.child("users_by_fullname").child(safeFullName).setValue(CryptoHelper.encrypt(firebaseUser.uid) ?? "")
                    }
                    if !(firebaseUser.phoneNumber ?? "").isEmpty {
                        self.databaseRef.child("users_by_phone").child(safePhone).setValue(CryptoHelper.encrypt(firebaseUser.uid) ?? "")
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
                "firstName": CryptoHelper.encrypt(firstName) ?? "",
                "lastName": CryptoHelper.encrypt(lastName) ?? "",
                "email": CryptoHelper.encrypt(email) ?? "",
                "phoneNumber": CryptoHelper.encrypt(phoneNumber) ?? "",
                "createdAt": ServerValue.timestamp()
            ]
            
            let safeUID = self.sanitizeKey(user.uid)
            let safeEmail = CryptoHelper.hashIdentifier(email.lowercased())
            let safeFullName = CryptoHelper.hashIdentifier(fullName.lowercased())
            let safePhone = CryptoHelper.hashIdentifier(phoneNumber)
            
            // 1. Save standard profile
            self.databaseRef.child("users").child(safeUID).child("profile").setValue(userProfile)
            
            // 2. Update lookup indices (Email is key for Account, but we index all for sync)
            if !email.isEmpty { self.databaseRef.child("users_by_email").child(safeEmail).setValue(CryptoHelper.encrypt(user.uid) ?? "") }
            if !fullName.isEmpty { self.databaseRef.child("users_by_fullname").child(safeFullName).setValue(CryptoHelper.encrypt(user.uid) ?? "") }
            if !phoneNumber.isEmpty { self.databaseRef.child("users_by_phone").child(safePhone).setValue(CryptoHelper.encrypt(user.uid) ?? "") }
            
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
            if var profileData = snapshot.value as? [String: Any] {
                if let f = profileData["firstName"] as? String { profileData["firstName"] = CryptoHelper.decrypt(f) ?? "" }
                if let l = profileData["lastName"] as? String { profileData["lastName"] = CryptoHelper.decrypt(l) ?? "" }
                if let e = profileData["email"] as? String { profileData["email"] = CryptoHelper.decrypt(e) ?? "" }
                if let p = profileData["phoneNumber"] as? String { profileData["phoneNumber"] = CryptoHelper.decrypt(p) ?? "" }
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
                    if var convo = value as? [String: Any] {
                        if let id = convo["id"] as? String { convo["id"] = CryptoHelper.decrypt(id) ?? "" }
                        if let t = convo["title"] as? String { convo["title"] = CryptoHelper.decrypt(t) ?? "" }
                        if let d = convo["details"] as? String { convo["details"] = CryptoHelper.decrypt(d) ?? "" }
                        if let c = convo["category"] as? String { convo["category"] = CryptoHelper.decrypt(c) ?? "" }
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
                    if var action = value as? [String: Any] {
                        if let id = action["id"] as? String { action["id"] = CryptoHelper.decrypt(id) ?? "" }
                        if let rc = action["roomCode"] as? String { action["roomCode"] = CryptoHelper.decrypt(rc) ?? "" }
                        if let ct = action["categoryTitle"] as? String { action["categoryTitle"] = CryptoHelper.decrypt(ct) ?? "" }
                        if let convT = action["conversationTopic"] as? String { action["conversationTopic"] = CryptoHelper.decrypt(convT) ?? "" }
                        if let desc = action["description"] as? String { action["description"] = CryptoHelper.decrypt(desc) ?? "" }
                        if let pNames = action["participantNames"] as? [String] { action["participantNames"] = pNames.compactMap { CryptoHelper.decrypt($0) } }
                        if let pEmails = action["participantEmails"] as? [String] { action["participantEmails"] = pEmails.compactMap { CryptoHelper.decrypt($0) } }
                        if let pPhones = action["participantPhones"] as? [String] { action["participantPhones"] = pPhones.compactMap { CryptoHelper.decrypt($0) } }
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
        let safeEmail = CryptoHelper.hashIdentifier(email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        databaseRef.child("users_by_email").child(safeEmail).observeSingleEvent(of: .value) { snapshot in
            if let encryptedUID = snapshot.value as? String {
                completion(CryptoHelper.decrypt(encryptedUID))
            } else {
                completion(nil)
            }
        }
    }
    
    func lookupUID(byPhone phone: String, completion: @escaping (String?) -> Void) {
        let safePhone = CryptoHelper.hashIdentifier(phone.trimmingCharacters(in: .whitespacesAndNewlines))
        databaseRef.child("users_by_phone").child(safePhone).observeSingleEvent(of: .value) { snapshot in
            if let encryptedUID = snapshot.value as? String {
                completion(CryptoHelper.decrypt(encryptedUID))
            } else {
                completion(nil)
            }
        }
    }
    
    func lookupUID(byFullName name: String, completion: @escaping (String?) -> Void) {
        let safeName = CryptoHelper.hashIdentifier(name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        databaseRef.child("users_by_fullname").child(safeName).observeSingleEvent(of: .value) { snapshot in
            if let encryptedUID = snapshot.value as? String {
                completion(CryptoHelper.decrypt(encryptedUID))
            } else {
                completion(nil)
            }
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

// MARK: - CryptoHelper for Client-Side Encryption (CSE)
struct CryptoHelper {
    
    /// Returns the shared symmetric key.
    /// It attempts to read the key from a `.env` file in the app bundle.
    private static let sharedKey: SymmetricKey = {
        let defaultKey = "f8a73b2a0c6495123d4e9f78ad5b22b10a9c8f6e7d4a3b2c1f9e8d7a6b5c4d3e"
        var keyString = defaultKey
        
        // Attempt to read from .env file
        if let path = Bundle.main.path(forResource: ".env", ofType: nil) ?? Bundle.main.path(forResource: "env", ofType: "txt") {
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                for line in content.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "SYMMETRIC_KEY" {
                        keyString = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                        break
                    }
                }
            } catch {
                print("CryptoHelper: Could not read .env file.")
            }
        }
        
        let keyData = Data(hexString: keyString)!
        return SymmetricKey(data: keyData)
    }()
    
    // MARK: - Encryption & Decryption
    
    static func encrypt(_ plainText: String?) -> String? {
        guard let plainText = plainText, let data = plainText.data(using: .utf8) else { return nil }
        do {
            let sealedBox = try AES.GCM.seal(data, using: sharedKey)
            return sealedBox.combined?.base64EncodedString()
        } catch {
            print("CryptoHelper: Encryption failed - \(error.localizedDescription)")
            return nil
        }
    }
    
    static func decrypt(_ base64String: String?) -> String? {
        guard let base64String = base64String, let data = Data(base64Encoded: base64String) else { return nil }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: sharedKey)
            return String(data: decryptedData, encoding: .utf8)
        } catch {
            print("CryptoHelper: Decryption failed - \(error.localizedDescription)")
            return nil
        }
    }
    
    static func decryptOrOriginal(_ value: String) -> String {
        return decrypt(value) ?? value
    }
    
    // MARK: - Hashing (One-way)
    
    static func hashIdentifier(_ identifier: String) -> String {
        let data = Data(identifier.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

fileprivate extension Data {
    init?(hexString: String) {
        let length = hexString.count / 2
        var data = Data(capacity: length)
        var index = hexString.startIndex
        for _ in 0..<length {
            let nextIndex = hexString.index(index, offsetBy: 2)
            let bytes = hexString[index..<nextIndex]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            index = nextIndex
        }
        self = data
    }
}
