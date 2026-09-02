//
//  ProfileTableViewController.swift
//  ANSD_APP
//
//  Created by Daiwiik Harihar on 12/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import FirebaseAuth

// Defines the delegate protocol for propagating profile updates to the Home Screen.
protocol ProfileUpdateDelegate: AnyObject {
    func didUpdateProfile(firstName: String, image: UIImage?)
}

class ProfileTableViewController: UITableViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    // MARK: - Properties
    weak var delegate: ProfileUpdateDelegate?

    // MARK: - Outlets (Personal Information)
    @IBOutlet weak var genderButton: UIButton!
    @IBOutlet weak var datePicker: UIDatePicker!
    @IBOutlet weak var profileImageView: UIImageView!
    @IBOutlet weak var firstNameTextField: UITextField!
    @IBOutlet weak var lastNameTextField: UITextField!
    @IBOutlet weak var languageButton: UIButton!

    // MARK: - Outlets (Vocal Profile)
    @IBOutlet weak var voiceStatusLabel: UILabel!

    var incomingName: String?
    var incomingImage: UIImage?

    // MARK: - Storage Keys
    private let firstNameKey = "user_first_name"
    private let lastNameKey = "user_last_name"
    private let genderKey = "user_gender"
    private let dobKey = "user_dob"
    private let imageKey = "profileImage"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHideKeyboardOnTap()
        setupTextFieldListeners()
        setupGenderButton()
        setupLanguageButton()
        loadPersistentData()
        setupFooterView()

        // Initial Name Setup
        if firstNameTextField.text?.isEmpty ?? true {
            firstNameTextField.text = incomingName ?? "User"
        }
        
        datePicker.maximumDate = Date()

        // Load Image
        if let data = UserDefaults.standard.data(forKey: imageKey),
           let savedImage = UIImage(data: data) {
            profileImageView.image = savedImage
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshVoiceProfileStatus()
    }

    // Applies circular styling and a border to the profile image view.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Configures the image view with aspect fill and a rounded corner radius.
        profileImageView.layer.cornerRadius = profileImageView.frame.size.width / 2
        profileImageView.layer.masksToBounds = true
        profileImageView.contentMode = .scaleAspectFill

        // Adds a subtle border around the profile photo for visual clarity.
        profileImageView.layer.borderWidth = 3
        profileImageView.layer.borderColor = UIColor.systemGray5.cgColor
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        performAutoSave()
    }

    // MARK: - Gender Menu Setup
    private func setupGenderButton() {
        let options = ["Male", "Female", "Prefer not to say"]
        var actions = [UIAction]()

        for option in options {
            let action = UIAction(title: option) { [weak self] _ in
                self?.genderButton.setTitle(option, for: .normal)
                self?.performAutoSave()
            }
            actions.append(action)
        }

        genderButton.menu = UIMenu(children: actions)
        genderButton.showsMenuAsPrimaryAction = true
    }

    // MARK: - Language Menu Setup
    private func setupLanguageButton() {
        let languages = LanguageManager.shared.supportedLanguages
        var actions = [UIAction]()

        let currentLocaleID = LanguageManager.shared.currentLocale.identifier

        for lang in languages {
            let isSelected = lang.locale.identifier == currentLocaleID
            let action = UIAction(title: lang.name, state: isSelected ? .on : .off) { [weak self] _ in
                LanguageManager.shared.currentLocale = lang.locale
                self?.updateLanguageButtonTitle()
                self?.setupLanguageButton() // Re-setup to update checkmarks
            }
            actions.append(action)
        }

        languageButton.menu = UIMenu(title: "Select Language", children: actions)
        languageButton.showsMenuAsPrimaryAction = true
        updateLanguageButtonTitle()
    }

    private func updateLanguageButtonTitle() {
        languageButton.setTitle(LanguageManager.shared.currentLanguageDisplayName, for: .normal)
    }

    // MARK: - Voice Profile Setup

    /// Check if a voice profile exists and update the status label accordingly
    private func refreshVoiceProfileStatus() {
        if let uid = Auth.auth().currentUser?.uid, let profile = VoiceProfileManager.shared.getVoiceProfile(byUID: uid) {
            voiceStatusLabel.text = "Calibrated"
            voiceStatusLabel.textColor = .systemGreen
            print("ProfileScreen: Voice profile found: \(profile.name)")
        } else {
            voiceStatusLabel.text = "Not Calibrated"
            voiceStatusLabel.textColor = .systemGray
        }
    }

    // MARK: - Voice Profile Actions

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch indexPath.section {
        case 2: // Vocal Profile
            if indexPath.row == 0 {
                handleVocalProfileTap()
            }
        case 3: // Support
            if indexPath.row == 0 {
                handleAppGuideTap()
            }
        default:
            break
        }
    }

    private func handleAppGuideTap() {
        // 1. Reset Tips
        HomeViewController.resetTips()

        // 2. Navigate back to Home and trigger tips
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
            NotificationCenter.default.post(name: NSNotification.Name("ReplayHomeTips"), object: nil)
        } else {
            dismiss(animated: true) {
                NotificationCenter.default.post(name: NSNotification.Name("ReplayHomeTips"), object: nil)
            }
        }
    }

    private func handleVocalProfileTap() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        if VoiceProfileManager.shared.getVoiceProfile(byUID: uid) != nil {
            let actionSheet = UIAlertController(title: "Voice Profile", message: "Manage your voice profile", preferredStyle: .actionSheet)

            actionSheet.addAction(UIAlertAction(title: "Update Profile", style: .default) { [weak self] _ in
                self?.navigateToVoiceCalibration()
            })

            actionSheet.addAction(UIAlertAction(title: "Delete Profile", style: .destructive) { [weak self] _ in
                VoiceProfileManager.shared.deleteVoiceProfile(byUID: uid)
                self?.refreshVoiceProfileStatus()

                let confirmation = UIAlertController(title: "Deleted", message: "Your voice profile has been removed.", preferredStyle: .alert)
                confirmation.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(confirmation, animated: true)
            })

            actionSheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            // For iPad support
            if let popoverController = actionSheet.popoverPresentationController {
                if let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 2)) {
                    popoverController.sourceView = cell
                    popoverController.sourceRect = cell.bounds
                }
            }

            present(actionSheet, animated: true)
        } else {
            navigateToVoiceCalibration()
        }
    }

    /// Navigate to Voice Calibration screen for re-recording
    private func navigateToVoiceCalibration() {
        // Try to find the VoiceCalibration storyboard or use the Onboarding storyboard
        let storyboard = UIStoryboard(name: "Onboarding", bundle: nil)
        if let calibrationVC = storyboard.instantiateViewController(withIdentifier: "VoiceCalibrationViewController") as? VoiceCalibrationViewController {
            let navController = UINavigationController(rootViewController: calibrationVC)
            navController.modalPresentationStyle = .fullScreen
            present(navController, animated: true)
        }
    }

    // MARK: - Personal Info Actions

    // Dismisses the profile screen by popping or dismissing the view controller depending on presentation context.
    @IBAction func closeButtonTapped(_ sender: Any) {
        print("DEBUG: Close button tapped")

        // Try to pop (if came from right)
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        }
        // Try to dismiss (if came from bottom)
        else {
            dismiss(animated: true, completion: nil)
        }
    }

    @IBAction func setProfilePictureTapped(_ sender: Any) {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        present(picker, animated: true)
    }

    // MARK: - Logic & Saving

    func setupTextFieldListeners() {
        firstNameTextField.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)
        lastNameTextField.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)
        datePicker.addTarget(self, action: #selector(datePickerChanged), for: .valueChanged)
    }

    @objc func textFieldDidChange() {
        performAutoSave()
    }

    @objc func datePickerChanged() {
        performAutoSave()
    }

    func performAutoSave() {
        ProfileManager.shared.firstName = firstNameTextField.text ?? "User"
        ProfileManager.shared.lastName = lastNameTextField.text ?? ""
        ProfileManager.shared.dob = datePicker.date
        ProfileManager.shared.gender = genderButton.title(for: .normal) ?? "Select"
    }

    func loadPersistentData() {
        firstNameTextField.text = ProfileManager.shared.firstName
        lastNameTextField.text = ProfileManager.shared.lastName
        genderButton.setTitle(ProfileManager.shared.gender, for: .normal)
        datePicker.date = ProfileManager.shared.dob
    }

    // MARK: - Image Picker Delegate
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        if let edited = info[.editedImage] as? UIImage {
            profileImageView.image = edited
            ProfileManager.shared.profileImage = edited
        } else if let original = info[.originalImage] as? UIImage {
            profileImageView.image = original
            ProfileManager.shared.profileImage = original
        }
        dismiss(animated: true)
    }

    // MARK: - Keyboard Handling
    func setupHideKeyboardOnTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - Sign Out & Account Deletion
    @objc private func confirmSignOut() {
        let actionSheet = UIAlertController(title: "Log Out", message: "Are you sure you want to log out of Sāmwaad?", preferredStyle: .actionSheet)

        actionSheet.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
            self?.performSignOut()
        })
        actionSheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad Popover support
        if let popover = actionSheet.popoverPresentationController, let footerView = tableView.tableFooterView {
            popover.sourceView = footerView
            popover.sourceRect = footerView.bounds
        }

        present(actionSheet, animated: true)
    }

    private func performSignOut() {
        FirebaseManager.shared.signOut { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.navigateToOnboarding()
                case .failure(let error):
                    let errorAlert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(errorAlert, animated: true)
                }
            }
        }
    }

    @objc private func confirmDeleteAccount() {
        let alert = UIAlertController(
            title: "Delete Account",
            message: "Are you sure you want to permanently delete your account? All your voice profiles, saved conversations, and cloud data will be permanently wiped. This action cannot be undone.",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Delete Account & Data", style: .destructive) { [weak self] _ in
            self?.performAccountDeletion()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad Popover support
        if let popover = alert.popoverPresentationController, let footerView = tableView.tableFooterView {
            popover.sourceView = footerView
            popover.sourceRect = footerView.bounds
        }

        present(alert, animated: true)
    }

    private func performAccountDeletion() {
        guard let currentUser = Auth.auth().currentUser else {
            let alert = UIAlertController(title: "Error", message: "No active user session found.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let uid = currentUser.uid

        // 1. Wipe local SwiftData voice calibration profile
        VoiceProfileManager.shared.deleteVoiceProfile(byUID: uid)

        // 2. Wipe local SwiftData conversations
        DataManager.shared.deleteAllConversations(forUID: uid)

        // 3. Clear user profile preferences from UserDefaults
        ProfileManager.shared.resetProfile()

        // 4. Delete user node from Firebase Realtime Database & Firebase Auth
        FirebaseManager.shared.deleteAccount { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    print("ProfileTableViewController: Account successfully deleted.")
                    self?.navigateToOnboarding()
                case .failure(let error):
                    let nsError = error as NSError
                    let errorMessage: String
                    if nsError.domain == "FIRAuthErrorDomain", nsError.code == 17014 { // Requires recent login
                        errorMessage = "For security reasons, deleting your account requires a recent sign-in. Please log in again and then retry deleting your account."
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    let errorAlert = UIAlertController(title: "Account Deletion Failed", message: errorMessage, preferredStyle: .alert)
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(errorAlert, animated: true)
                }
            }
        }
    }

    private func navigateToOnboarding() {
        let storyboard = UIStoryboard(name: "Onboarding", bundle: nil)
        if let loginNav = storyboard.instantiateInitialViewController() {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.rootViewController = loginNav
                window.makeKeyAndVisible()
                UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: nil, completion: nil)
            } else {
                loginNav.modalPresentationStyle = .fullScreen
                present(loginNav, animated: true, completion: nil)
            }
        }
    }

    // MARK: - Footer Setup
    private func setupFooterView() {
        let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 140))

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.alignment = .center
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // 1. Log Out Button
        var logoutConfig = UIButton.Configuration.filled()
        logoutConfig.title = "Log Out"
        logoutConfig.baseBackgroundColor = .systemGray5
        logoutConfig.baseForegroundColor = .label
        logoutConfig.cornerStyle = .large

        let logoutButton = UIButton(configuration: logoutConfig)
        logoutButton.translatesAutoresizingMaskIntoConstraints = false
        logoutButton.addTarget(self, action: #selector(logoutButtonTapped), for: .touchUpInside)

        // 2. Delete Account Button (Apple Guideline 5.1.1(v))
        var deleteConfig = UIButton.Configuration.plain()
        deleteConfig.title = "Delete Account"
        deleteConfig.baseForegroundColor = .systemRed

        let deleteButton = UIButton(configuration: deleteConfig)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.addTarget(self, action: #selector(deleteAccountButtonTapped), for: .touchUpInside)

        stackView.addArrangedSubview(logoutButton)
        stackView.addArrangedSubview(deleteButton)
        footerView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: footerView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            logoutButton.widthAnchor.constraint(equalToConstant: 240),
            logoutButton.heightAnchor.constraint(equalToConstant: 46),
            deleteButton.widthAnchor.constraint(equalToConstant: 240),
            deleteButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        tableView.tableFooterView = footerView
    }

    @objc private func logoutButtonTapped() {
        confirmSignOut()
    }

    @objc private func deleteAccountButtonTapped() {
        confirmDeleteAccount()
    }

    // MARK: - Custom Header Styling

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let headerView = UIView()
        headerView.backgroundColor = .clear

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 18, weight: .bold)
        label.textColor = .label

        switch section {
        case 0: label.text = "User Details"
        case 1: label.text = "Preferences"
        case 2: label.text = "Vocal Profile"
        case 3: label.text = "SUPPORT"
        default: return nil
        }

        headerView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: headerView.layoutMarginsGuide.leadingAnchor, constant: 0),
            label.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -8)
        ])

        return headerView
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 50
    }
}
