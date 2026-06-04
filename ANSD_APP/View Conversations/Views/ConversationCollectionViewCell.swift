//
//  ConversationCollectionViewCell.swift
//  ANSD_APP
//
//  Created by Omkar Varpe on 15/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit

// MARK: - Conversation Collection View Cell
// Specialized cell for displaying conversation summaries, including topic, date, time, and category icons.
class ConversationCollectionViewCell: UICollectionViewCell {

    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var descriptionLabel: UILabel!
    @IBOutlet weak var dateLabel: UILabel!
    @IBOutlet weak var timeLabel: UILabel!
    @IBOutlet weak var categoryLabel: UILabel!
    @IBOutlet weak var categoryContainer: UIView!
    @IBOutlet weak var calendarIcon: UIImageView!
    @IBOutlet weak var clockIcon: UIImageView!

    override func awakeFromNib() {
        super.awakeFromNib()

        backgroundColor = .secondarySystemGroupedBackground
        contentView.backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        layer.masksToBounds = true
        // Shadows removed per design spec
        layer.borderWidth = 0

        // HIG: Enforce strong typographic hierarchy and spacing.
        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        // Shrunk text size to '.footnote' to perfectly fit deep hierarchy requested
        descriptionLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        descriptionLabel.textColor = .secondaryLabel

        // We will unhide and creatively repurpose these perfectly-spaced icons dynamically.
        calendarIcon.isHidden = false
        clockIcon.isHidden = false
    }

    func configure(with conversation: Conversation) {
        if conversation.isPinned {
            let fullString = NSMutableAttributedString()
            let imageAttachment = NSTextAttachment()
            let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            if let image = UIImage(systemName: "pin.fill", withConfiguration: config)?.withTintColor(.systemGray, renderingMode: .alwaysOriginal) {
                imageAttachment.image = image
                imageAttachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            }
            fullString.append(NSAttributedString(attachment: imageAttachment))
            fullString.append(NSAttributedString(string: " " + conversation.title))
            titleLabel.attributedText = fullString

            // HIG: Pinned cards have 1 summary line, regular cards have 2.
            descriptionLabel.numberOfLines = 1
        } else {
            titleLabel.text = conversation.title
            descriptionLabel.numberOfLines = 2
        }
        descriptionLabel.text = conversation.details

        // HIG: Removed repetitive Date & Time. Repurposing these slots based on user priority (Participants, Duration, Category)

        // Slot 1 (Left): Participants
        let paxCount = max(1, conversation.participants?.count ?? 0)
        dateLabel.text = paxCount == 1 ? "1 Person" : "\(paxCount) People"
        calendarIcon.image = UIImage(systemName: "person.2.fill")
        calendarIcon.tintColor = .secondaryLabel // Increased emphasis slightly

        // Slot 2 (Middle): Time Range
        let timeRangeStr: String
        if !conversation.endTime.isEmpty && conversation.startTime != conversation.endTime {
            timeRangeStr = "\(conversation.startTime) - \(conversation.endTime)"
        } else {
            timeRangeStr = conversation.startTime
        }
        timeLabel.text = timeRangeStr
        clockIcon.image = UIImage(systemName: "clock")
        clockIcon.tintColor = .secondaryLabel

        // Slot 3 (Right): Category Badge
        let categoryString = conversation.category
        let capitalizedCategory = categoryString.prefix(1).uppercased() + categoryString.dropFirst()
        categoryLabel.text = capitalizedCategory

        let txtColor = conversation.categoryTintColor

        categoryContainer.backgroundColor = txtColor.withAlphaComponent(0.15)
        categoryLabel.textColor = txtColor

        calendarIcon.isAccessibilityElement = true
        let paxAccessibilityCount = max(1, conversation.participants?.count ?? 0)
        calendarIcon.accessibilityLabel = "\(paxAccessibilityCount) Participants"

        clockIcon.isAccessibilityElement = true
        clockIcon.accessibilityLabel = "Time: \(timeRangeStr)"

        categoryContainer.isAccessibilityElement = true
        categoryContainer.accessibilityLabel = "Category: \(capitalizedCategory)"
    }

    // HIG: Helper to calculate accurate duration
    private func calculateDuration(start: String, end: String) -> String {
        guard !start.isEmpty, !end.isEmpty else { return "Unknown" }

        let formatters = ["h:mm a", "HH:mm", "hh:mm a", "H:mm"]
        var sDate: Date?
        var eDate: Date?

        for format in formatters {
            let df = DateFormatter()
            df.dateFormat = format
            if sDate == nil { sDate = df.date(from: start) }
            if eDate == nil { eDate = df.date(from: end) }
            if sDate != nil && eDate != nil { break }
        }

        if let sDate = sDate, let eDate = eDate {
            var diffOptions = eDate.timeIntervalSince(sDate)
            if diffOptions < 0 { diffOptions += 24 * 3600 } // Handles crossing midnight
            let totalMins = Int(diffOptions) / 60
            if totalMins >= 60 {
                let hours = totalMins / 60
                let mins = totalMins % 60
                return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
            }
            return "\(totalMins)m"
        }
        return "\(start) - \(end)" // Fallback if format misses
    }
}
