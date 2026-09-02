//
//  LoginAccountViewController.swift
//  ANSD_APP
//
//  Created by Dhiraj Bodake on 19/02/26.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import FirebaseAuth

class LoginViewController: UIViewController, UITextFieldDelegate {

    // MARK: - Outlets
    @IBOutlet weak var emailTextField: UITextField!
    @IBOutlet weak var passwordTextField: UITextField!
    @IBOutlet weak var loginButton: UIButton!
    @IBOutlet weak var forgotPasswordButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Sign In"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always

        setupUI()
        setupTextFieldDelegates()
        setupKeyboardDismiss()
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Sign In button styling
        loginButton.layer.cornerRadius = 14
        loginButton.clipsToBounds = true

        // Text field styling for consistent appearance
        let fields = [emailTextField, passwordTextField]
        for field in fields {
            guard let field = field else { continue }
            field.layer.cornerRadius = 12
            field.backgroundColor = .systemGray6
            field.borderStyle = .none

            // Add left padding
            let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: field.frame.height))
            field.leftView = paddingView
            field.leftViewMode = .always
        }

        // Configure email field
        emailTextField.keyboardType = .emailAddress
        emailTextField.autocapitalizationType = .none
        emailTextField.autocorrectionType = .no
        emailTextField.returnKeyType = .next
        emailTextField.textContentType = .emailAddress
        emailTextField.placeholder = "john@example.com"

        // Configure password field
        passwordTextField.isSecureTextEntry = true
        passwordTextField.returnKeyType = .done
        passwordTextField.textContentType = .password
        passwordTextField.placeholder = "••••••••"
    }

    private func setupTextFieldDelegates() {
        emailTextField.delegate = self
        passwordTextField.delegate = self
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == emailTextField {
            passwordTextField.becomeFirstResponder()
        } else if textField == passwordTextField {
            passwordTextField.resignFirstResponder()
            loginTapped(loginButton)
        }
        return true
    }

    // MARK: - Actions

    @IBAction func loginTapped(_ sender: UIButton) {
        // Dismiss keyboard
        view.endEditing(true)

        // Validation
        guard let email = emailTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            showAlert(title: "Missing Field", message: "Please enter your email address.")
            return
        }

        guard let password = passwordTextField.text, !password.isEmpty else {
            showAlert(title: "Missing Field", message: "Please enter your password.")
            return
        }

        // Show loading state
        loginButton.isEnabled = false
        loginButton.configuration?.showsActivityIndicator = true

        let details = ["email": email, "password": password]

        // Firebase login
        FirebaseManager.shared.loginUser(details: details) { [weak self] result in
            DispatchQueue.main.async {
                self?.loginButton.isEnabled = true
                self?.loginButton.configuration?.showsActivityIndicator = false

                switch result {
                case .success(let user):
                    let uid = user.uid
                    // Fetch user profile
                    FirebaseManager.shared.fetchUserProfile(uid: uid) { profileData in
                        DispatchQueue.main.async {
                            if let data = profileData {
                                let firstName = data["firstName"] as? String ?? ""
                                let lastName = data["lastName"] as? String ?? ""
                                if !firstName.isEmpty {
                                    UserDefaults.standard.set(firstName, forKey: "user_first_name")
                                }
                                if !lastName.isEmpty {
                                    UserDefaults.standard.set(lastName, forKey: "user_last_name")
                                }
                            } else {
                                // Fallback to email prefix if profile data is not available
                                let emailPrefix = email.components(separatedBy: "@").first ?? ""
                                let firstName = emailPrefix.components(separatedBy: ".").first?.capitalized ?? emailPrefix
                                if !firstName.isEmpty {
                                    UserDefaults.standard.set(firstName, forKey: "user_first_name")
                                }
                            }

                            // Restore conversation history
                            FirebaseManager.shared.fetchConversationHistory(uid: uid) { conversations in
                                DispatchQueue.main.async {
                                    for dict in conversations {
                                        guard let id = dict["id"] as? String,
                                              let title = dict["title"] as? String else { continue }

                                        // Skip if conversation already exists locally
                                        if DataManager.shared.fetchConversation(byId: id) != nil { continue }

                                        // Fetch FULL DATA (Messages + Participants)
                                        FirebaseManager.shared.fetchFullConversation(uid: uid, conversationID: id) { fullData in
                                            DispatchQueue.main.async {
                                                let metadata = fullData?["metadata"] as? [String: Any] ?? dict
                                                let participantsDict = fullData?["participants"] as? [String: [String: Any]] ?? [:]
                                                let messagesDict = fullData?["messages"] as? [String: [String: Any]] ?? [:]

                                                // 1. Create Participants
                                                var historyParticipants: [Participant] = []
                                                for (_, pData) in participantsDict {
                                                    let p = Participant(
                                                        name: pData["name"] as? String ?? "Unknown",
                                                        summary: pData["summary"] as? String ?? "",
                                                        image: pData["image"] as? String ?? "person.circle.fill"
                                                    )
                                                    historyParticipants.append(p)
                                                }

                                                // 2. Create Messages
                                                var historyMessages: [Message] = []
                                                for (_, mData) in messagesDict {
                                                    let m = Message(
                                                        id: UUID(),
                                                        text: mData["text"] as? String ?? "",
                                                        senderId: mData["senderId"] as? String ?? "",
                                                        senderName: mData["senderName"] as? String ?? "",
                                                        isIncoming: mData["isIncoming"] as? Bool ?? false,
                                                        timestamp: Date(timeIntervalSince1970: mData["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970),
                                                        isHighlighted: mData["isHighlighted"] as? Bool ?? false,
                                                        isEdited: mData["isEdited"] as? Bool ?? false
                                                    )
                                                    historyMessages.append(m)
                                                }

                                                // 3. Create Conversation
                                                let convo = Conversation(
                                                    id: id,
                                                    title: title,
                                                    details: metadata["details"] as? String ?? "",
                                                    date: metadata["date"] as? String ?? "",
                                                    startTime: metadata["startTime"] as? String ?? "",
                                                    endTime: metadata["endTime"] as? String ?? "",
                                                    location: metadata["location"] as? String ?? "",
                                                    category: metadata["category"] as? String ?? "",
                                                    icon: metadata["icon"] as? String ?? "",
                                                    info: metadata["info"] as? Bool,
                                                    calendarDate: Date(timeIntervalSince1970: metadata["calendarDate"] as? TimeInterval ?? Date().timeIntervalSince1970),
                                                    notes: metadata["notes"] as? String,
                                                    isPinned: metadata["isPinned"] as? Bool ?? false,
                                                    ownerUID: uid,
                                                    participants: historyParticipants,
                                                    messages: historyMessages
                                                )

                                                DataManager.shared.addConversation(convo)
                                            }
                                        }
                                    }

                                    // Restore Quick Actions
                                    FirebaseManager.shared.fetchQuickActions(uid: uid) { actions in
                                        DispatchQueue.main.async {
                                            for dict in actions {
                                                guard let id = dict["id"] as? String,
                                                      let categoryTitle = dict["categoryTitle"] as? String,
                                                      let conversationTopic = dict["conversationTopic"] as? String,
                                                      let startTime = dict["startTime"] as? String,
                                                      let status = dict["status"] as? String,
                                                      let roomCode = dict["roomCode"] as? String,
                                                      let iconName = dict["iconName"] as? String,
                                                      let topicImage = dict["topicImage"] as? String,
                                                      let timeImage = dict["timeImage"] as? String else { continue }

                                                let existing = QuickActionsRepository.shared.getAllActions()
                                                if existing.contains(where: { $0.id == id }) { continue }

                                                let action = RoutineConversation(
                                                    id: id,
                                                    iconName: iconName,
                                                    categoryTitle: categoryTitle,
                                                    status: status,
                                                    conversationTopic: conversationTopic,
                                                    topicImage: topicImage,
                                                    startTime: startTime,
                                                    description: dict["description"] as? String,
                                                    date: dict["date"] as? String,
                                                    timeImage: timeImage,
                                                    roomCode: roomCode,
                                                    participantNames: dict["participantNames"] as? [String] ?? []
                                                )
                                                QuickActionsRepository.shared.addAction(action)
                                            }

                                            DispatchQueue.main.async {
                                                 // Mark onboarding tips as already shown for existing user logins
                                                 UserDefaults.standard.set(true, forKey: "home_tips_shown_v1")
                                                 UserDefaults.standard.set(false, forKey: "is_brand_new_signup")

                                                 // Navigate to Home by resetting the window root for a clean state
                                                 let storyboard = UIStoryboard(name: "Home", bundle: nil)
                                                 if let homeNav = storyboard.instantiateViewController(withIdentifier: "HomeNav") as? UINavigationController {
                                                     if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                                        let window = windowScene.windows.first {
                                                         window.rootViewController = homeNav
                                                         window.makeKeyAndVisible()
                                                         UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: nil, completion: nil)
                                                     } else {
                                                         // Fallback to segue if window lookup fails
                                                         self?.performSegue(withIdentifier: "loginToHome", sender: self)
                                                     }
                                                 }
                                             }
                                        }
                                    }
                                }
                            }
                        }
                    }

                case .failure(let error):
                    self?.showAlert(title: "Sign In Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @IBAction func forgotPasswordTapped(_ sender: UIButton) {
        performSegue(withIdentifier: "showForgotPassword", sender: self)
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Keyboard Handling
extension LoginViewController {
    private func setupKeyboardDismiss() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }
}
