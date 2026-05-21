//
//  SignUpViewController.swift
//  ANSD_APP
//
//  Created by Daiwiik Harihar on 22/01/26.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit

// MARK: - UserDefaults Keys
struct UserKeys {
    static let profile   = "user_profile_data"
    static let firstName = "first_name"
    static let lastName  = "last_name"
    static let email     = "email"
    static let password  = "password"
    static let dob       = "dob"
    static let gender    = "gender"
    static let image     = "profile_image"
    static let impairment = "impairment_level" // Added key
}

// MARK: - Supporting Types
enum FieldType {
    case text
    case gender
    case impairment
    case date
}

struct FormFieldItem {
    let title: String
    let key: String
    let type: FieldType
}

// MARK: - SignUp View Controller
class SignUpViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, SignUpCellDelegate {

    @IBOutlet weak var tableView: UITableView!

    let formFields: [FormFieldItem] = [
        FormFieldItem(title: "First Name", key: UserKeys.firstName, type: .text),
        FormFieldItem(title: "Last Name", key: UserKeys.lastName, type: .text),
        FormFieldItem(title: "Email", key: UserKeys.email, type: .text),
        FormFieldItem(title: "Password", key: UserKeys.password, type: .text),
        FormFieldItem(title: "Date of Birth", key: UserKeys.dob, type: .date),
        FormFieldItem(title: "Gender", key: UserKeys.gender, type: .gender),
        FormFieldItem(title: "Hearing Impairment", key: UserKeys.impairment, type: .impairment)
    ]

    var userAnswers: [String: Any] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none

        // Ensure table respects storyboard heights
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100

        setupHideKeyboardOnTap()
    }

    // MARK: - Validation Helpers
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPred = NSPredicate(format: "SELF MATCHES %@", emailRegEx)
        return emailPred.evaluate(with: email)
    }

    private func showAlert(message: String) {
        let alert = UIAlertController(title: "Sign Up Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Sign Up Action
    @IBAction func didTapSignUp(_ sender: Any) {
        view.endEditing(true)

        // 1. Validation Guards
        guard let firstName = userAnswers[UserKeys.firstName] as? String, !firstName.isEmpty,
              let email = userAnswers[UserKeys.email] as? String, !email.isEmpty,
              let password = userAnswers[UserKeys.password] as? String, !password.isEmpty else {
            showAlert(message: "First Name, Email, and Password are required.")
            return
        }

        // 2. Format Validation
        if !isValidEmail(email) {
            showAlert(message: "Please enter a valid email address.")
            return
        }

        if password.count < 6 {
            showAlert(message: "Password must be at least 6 characters long.")
            return
        }

        // 3. Save and Proceed
        UserDefaults.standard.set(userAnswers, forKey: UserKeys.profile)

        print("Success: Saved profile: ", userAnswers)
        performSegue(withIdentifier: "toProfile", sender: self)
    }

    // MARK: - TableView DataSource
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return formFields.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = formFields[indexPath.row]

        switch field.type {
        case .text:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "SignUpCell", for: indexPath) as? SignUpTableViewCell else { return UITableViewCell() }
            cell.configure(title: field.title, placeholder: "Enter \(field.title)", index: indexPath.row)
            cell.delegate = self
            return cell

        case .gender:
            let cell = tableView.dequeueReusableCell(withIdentifier: "GenderCell", for: indexPath)
            cell.textLabel?.text = field.title

            if let selectedGender = userAnswers[field.key] as? String {
                cell.detailTextLabel?.text = selectedGender
                cell.detailTextLabel?.textColor = .black
            } else {
                cell.detailTextLabel?.text = "Select"
                cell.detailTextLabel?.textColor = .lightGray
            }
            return cell

        case .impairment:
            // Ensure you have a Slider in this cell connected to an action
            let cell = tableView.dequeueReusableCell(withIdentifier: "SliderCell", for: indexPath)

            // Find the slider in the cell and add a listener if not using a custom cell class
            if let slider = cell.viewWithTag(100) as? UISlider { // Assuming tag 100 in Storyboard
                slider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
            }
            return cell

        case .date:
            let cell = tableView.dequeueReusableCell(withIdentifier: "DOBCell", for: indexPath)
            // If you placed a UIDatePicker in this cell in Storyboard,
            // find it by tag (e.g., Tag 200) to save the value
            if let picker = cell.viewWithTag(200) as? UIDatePicker {
                picker.addTarget(self, action: #selector(datePickerChanged(_:)), for: .valueChanged)
            }
            return cell
        }
    }

    // MARK: - Slider Logic
    @objc func sliderValueChanged(_ sender: UISlider) {
        userAnswers[UserKeys.impairment] = sender.value
    }

    @objc func datePickerChanged(_ sender: UIDatePicker) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        userAnswers[UserKeys.dob] = formatter.string(from: sender.date)
    }

    // MARK: - TableView Delegate
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let field = formFields[indexPath.row]
        if field.type == .gender {
            showGenderPicker(key: field.key)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }

    private func showGenderPicker(key: String) {
        let alert = UIAlertController(title: "Select Gender", message: nil, preferredStyle: .actionSheet)
        let options = ["Male", "Female", "Prefer not to Say"]

        for option in options {
            alert.addAction(UIAlertAction(title: option, style: .default, handler: { _ in
                self.userAnswers[key] = option
                self.tableView.reloadData()
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - SignUpCellDelegate
    func didUpdateInput(text: String, rowIndex: Int) {
        let field = formFields[rowIndex]
        userAnswers[field.key] = text
    }

    // MARK: - Keyboard Handling
    private func setupHideKeyboardOnTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }
}
