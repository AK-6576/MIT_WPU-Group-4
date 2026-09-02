//
//  CreateAccountViewController.swift
//  ANSD_APP
//
//  Created by Dhiraj Bodake on 19/02/26.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import FirebaseAuth

class CreateAccountViewController: UIViewController, UITextFieldDelegate {

    // MARK: - Outlets
    @IBOutlet weak var scrollView: UIScrollView!

    @IBOutlet weak var firstNameTextField: UITextField!
    @IBOutlet weak var lastNameTextField: UITextField!
    @IBOutlet weak var emailTextField: UITextField!
    @IBOutlet weak var passwordTextField: UITextField!
    @IBOutlet weak var confirmPasswordTextField: UITextField!

    @IBOutlet weak var continueButton: UIButton!

    /// Ordered list of text fields for Return-key navigation
    private var orderedTextFields: [UITextField] = []

    /// Track the currently active text field for keyboard scroll
    private weak var activeTextField: UITextField?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Sign Up"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always

        orderedTextFields = [
            firstNameTextField,
            lastNameTextField,
            emailTextField,
            passwordTextField,
            confirmPasswordTextField
        ]

        setupUI()
        setupTextFieldDelegates()
        setupKeyboardDismiss()
        registerKeyboardNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Continue button styling
        continueButton.layer.cornerRadius = 28
        continueButton.clipsToBounds = true
        continueButton.setTitle("Sign Up", for: .normal)

        // Text field styling
        for field in orderedTextFields {
            field.layer.cornerRadius = 12
            field.backgroundColor = .systemGray6
            field.borderStyle = .none

            // Add horizontal padding
            let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: field.frame.height))
            field.leftView = paddingView
            field.leftViewMode = .always
        }

        // Capitalize first letter of each word for name fields
        firstNameTextField.autocapitalizationType = .words
        lastNameTextField.autocapitalizationType = .words
        // Never auto-capitalize passwords
        passwordTextField.autocapitalizationType = .none
        confirmPasswordTextField.autocapitalizationType = .none

        // Set return key types: Next for all except last field which gets Done
        for (index, field) in orderedTextFields.enumerated() {
            field.returnKeyType = (index < orderedTextFields.count - 1) ? .next : .done
        }
    }

    private func setupTextFieldDelegates() {
        for field in orderedTextFields {
            field.delegate = self
        }
    }

    // MARK: - UITextFieldDelegate

    func textFieldDidBeginEditing(_ textField: UITextField) {
        activeTextField = textField
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        activeTextField = nil
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Find the current field's index and move to the next one
        if let currentIndex = orderedTextFields.firstIndex(of: textField) {
            let nextIndex = currentIndex + 1
            if nextIndex < orderedTextFields.count {
                // Move focus to next field
                orderedTextFields[nextIndex].becomeFirstResponder()
            } else {
                // Last field — dismiss keyboard
                textField.resignFirstResponder()
            }
        }
        return true
    }

    // MARK: - Keyboard Avoidance

    private func registerKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }

        let keyboardHeight = keyboardFrame.height
        let contentInset = UIEdgeInsets(top: 0, left: 0, bottom: keyboardHeight + 20, right: 0)

        UIView.animate(withDuration: duration) {
            self.scrollView.contentInset = contentInset
            self.scrollView.scrollIndicatorInsets = contentInset
        }

        // Scroll the active text field into view
        if let activeField = activeTextField {
            let fieldFrame = activeField.convert(activeField.bounds, to: scrollView)
            let visibleRect = fieldFrame.insetBy(dx: 0, dy: -20)
            scrollView.scrollRectToVisible(visibleRect, animated: true)
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }

        UIView.animate(withDuration: duration) {
            self.scrollView.contentInset = .zero
            self.scrollView.scrollIndicatorInsets = .zero
        }
    }

    // MARK: - Actions

    @IBAction func continueTapped(_ sender: UIButton) {
        // Dismiss keyboard first
        view.endEditing(true)
        // Validate password match
        guard let password = passwordTextField.text,
              let confirmPassword = confirmPasswordTextField.text,
              password == confirmPassword else {
            let alert = UIAlertController(title: "Error", message: "Passwords do not match.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
            return
        }

        // Prepare user details for registration
        let firstName = firstNameTextField.text ?? ""
        let lastName = lastNameTextField.text ?? ""
        let userDetails = [
            "firstName": firstName,
            "lastName": lastName,
            "email": emailTextField.text ?? "",
            "password": password
        ]

        // Register with Firebase Auth
        continueButton.isEnabled = false
        FirebaseManager.shared.createAccount(details: userDetails) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.continueButton.isEnabled = true

                switch result {
                case .success:
                    // Store user names locally for profile display
                    UserDefaults.standard.set(firstName, forKey: "user_first_name")
                    UserDefaults.standard.set(lastName, forKey: "user_last_name")
                    UserDefaults.standard.set(true, forKey: "is_brand_new_signup")
                    UserDefaults.standard.set(false, forKey: "home_tips_shown_v1")
                    self.performSegue(withIdentifier: "showCalibration", sender: self)

                case .failure(let error):
                    let alert = UIAlertController(
                        title: "Registration Failed",
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }
}

// MARK: - Keyboard Handling
extension CreateAccountViewController {
    private func setupKeyboardDismiss() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false  // Allow buttons/fields to still receive taps
        view.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }
}
