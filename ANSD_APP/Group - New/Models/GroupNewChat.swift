//
//  GroupNewChat.swift
//  ANSD_APP
//
//  Created by Anshul Kumaria on 25/11/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import Foundation
import FirebaseDatabaseInternal

struct GroupNewChatMessage {
    var id: String = UUID().uuidString
    var text: String
    let isIncoming: Bool
    var sender: String
    let senderID: String

    // Converts the message to a dictionary suitable for writing to Firebase Realtime Database.
    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "text": text,
            "sender": sender,
            "senderID": senderID,
            "timestamp": ServerValue.timestamp()
        ]
    }
}
