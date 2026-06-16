//
//  SignUpTableViewCell.swift
//  ANSD_APP
//
//  Created by Daiwiik Harihar on 22/01/26.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit

protocol SignUpCellDelegate: AnyObject {
    func didUpdateInput(text: String, rowIndex: Int)
}

class SignUpTableViewCell: UITableViewCell, UITextFieldDelegate {

    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var inputTextField: UITextField!

    weak var delegate: SignUpCellDelegate?
    var rowIndex: Int = 0
    private let datePicker = UIDatePicker()

    override func awakeFromNib() {
        super.awakeFromNib()

        inputTextField.borderStyle = .none
        inputTextField.layer.cornerRadius = 10
        inputTextField.backgroundColor = .systemGray6
        inputTextField.delegate = self

        let padding = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
        inputTextField.leftView = padding
        inputTextField.leftViewMode = .always
    }

    func configure(title: String, placeholder: String, index: Int) {
        titleLabel.text = title
        inputTextField.placeholder = placeholder
        rowIndex = index

        // Reset for reuse
        inputTextField.text = ""
        inputTextField.isSecureTextEntry = false
        inputTextField.keyboardType = .default
        inputTextField.inputView = nil
        inputTextField.rightView = nil

        if title == UserKeys.dob {
            setupDatePicker()
        } else if title.contains("Password") {
            setupPassword()
        } else if title.contains("Email") {
            inputTextField.keyboardType = .emailAddress
            inputTextField.autocapitalizationType = .none
        } else if title.contains("Phone") {
            inputTextField.keyboardType = .phonePad
        }
    }

    private func setupDatePicker() {
        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .wheels
        datePicker.maximumDate = Date()
        datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.setItems([
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissDate))
        ], animated: false)

        inputTextField.inputView = datePicker
        inputTextField.inputAccessoryView = toolbar
    }

    private func setupPassword() {
        inputTextField.isSecureTextEntry = true

        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "eye.slash"), for: .normal)
        button.addTarget(self, action: #selector(togglePassword), for: .touchUpInside)

        inputTextField.rightView = button
        inputTextField.rightViewMode = .always
    }

    @objc private func dateChanged() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        inputTextField.text = formatter.string(from: datePicker.date)
        delegate?.didUpdateInput(text: inputTextField.text ?? "", rowIndex: rowIndex)
    }

    @objc private func dismissDate() {
        inputTextField.resignFirstResponder()
    }

    @objc private func togglePassword(_ sender: UIButton) {
        inputTextField.isSecureTextEntry.toggle()
        sender.setImage(
            UIImage(systemName: inputTextField.isSecureTextEntry ? "eye.slash" : "eye"),
            for: .normal
        )
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        delegate?.didUpdateInput(text: textField.text ?? "", rowIndex: rowIndex)
    }
}
