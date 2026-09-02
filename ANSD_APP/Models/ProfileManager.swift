//
//  ProfileManager.swift
//  ANSD_APP
//
//  Created by Daiwiik Harihar on 18/03/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import Foundation
import UIKit

class ProfileManager {
    static let shared = ProfileManager()

    private let firstNameKey = "user_first_name"
    private let lastNameKey = "user_last_name"
    private let genderKey = "user_gender"
    private let dobKey = "user_dob"
    private let imageKey = "profileImage"

    private init() {}

    var firstName: String {
        get { UserDefaults.standard.string(forKey: firstNameKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: firstNameKey)
            NotificationCenter.default.post(name: NSNotification.Name("ProfileNameUpdated"),
                                          object: nil,
                                          userInfo: ["name": newValue])
        }
    }

    var lastName: String {
        get { UserDefaults.standard.string(forKey: lastNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastNameKey) }
    }

    var gender: String {
        get { UserDefaults.standard.string(forKey: genderKey) ?? "Select" }
        set { UserDefaults.standard.set(newValue, forKey: genderKey) }
    }

    var dob: Date {
        get { UserDefaults.standard.object(forKey: dobKey) as? Date ?? Date() }
        set { UserDefaults.standard.set(newValue, forKey: dobKey) }
    }

    var profileImage: UIImage? {
        get {
            if let data = UserDefaults.standard.data(forKey: imageKey) {
                return UIImage(data: data)
            }
            return nil
        }
        set {
            if let data = newValue?.jpegData(compressionQuality: 0.8) {
                UserDefaults.standard.set(data, forKey: imageKey)
                NotificationCenter.default.post(name: NSNotification.Name("ProfileImageUpdated"), object: newValue)
            } else {
                UserDefaults.standard.removeObject(forKey: imageKey)
                NotificationCenter.default.post(name: NSNotification.Name("ProfileImageUpdated"), object: nil)
            }
        }
    }

    /// Clears all local user profile preferences upon account deletion
    func resetProfile() {
        UserDefaults.standard.removeObject(forKey: firstNameKey)
        UserDefaults.standard.removeObject(forKey: lastNameKey)
        UserDefaults.standard.removeObject(forKey: genderKey)
        UserDefaults.standard.removeObject(forKey: dobKey)
        UserDefaults.standard.removeObject(forKey: imageKey)
    }
}
