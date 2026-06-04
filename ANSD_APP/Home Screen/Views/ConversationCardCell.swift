//
//  ConversationCardCell.swift
//  ANSD_APP
//
//  Created by Daiwiik Harihar on 15/01/26.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//
import UIKit

// MARK: - Routine Cell (Quick Actions - Top List)
class QuickActionTableViewCell: UITableViewCell {

    // Kept as @IBOutlet so Storyboard doesn't crash, but immediately hidden
    @IBOutlet weak var iconImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var timeLabel: UILabel!

    // MARK: - Programmatic Views
    private let cardContainer      = UIView()
    var isFirstRow = false
    var isLastRow = false
    private let outlinelayer = CAShapeLayer()
    private let customIconContainer = UIView()
    private let customIconImageView = UIImageView()
    private let textStackView      = UIStackView()
    private let customTitleLabel   = UILabel()
    private let subtitleLabel      = UILabel()
    private let rightStackView     = UIStackView()
    private let customTimeLabel    = UILabel()
    private let badgeContainer     = UIView()
    private let badgeLabel         = UILabel()
    private let chevronImageView   = UIImageView()
    private let separator          = UIView()

    // MARK: - Lifecycle

    override func awakeFromNib() {
        super.awakeFromNib()
        // ✅ Hide all storyboard outlet views so they don't overlay the programmatic UI
        iconImageView?.isHidden  = true
        titleLabel?.isHidden     = true
        timeLabel?.isHidden      = true
        setupDesign()
    }

    // MARK: - Setup

    func setupDesign() {
        backgroundColor              = .clear
        contentView.backgroundColor  = .clear
        selectionStyle               = .none
        accessoryType                = .none

        // ── Card Container ──────────────────────────────
        cardContainer.backgroundColor                 = .secondarySystemGroupedBackground
        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardContainer)

        // ── Custom Icon ─────────────────────────────────
        customIconContainer.layer.cornerRadius        = 10
        customIconContainer.clipsToBounds             = true
        customIconContainer.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(customIconContainer)

        customIconImageView.contentMode               = .scaleAspectFit
        customIconImageView.translatesAutoresizingMaskIntoConstraints = false
        customIconContainer.addSubview(customIconImageView)

        // ── Text Stack ─────────────────────────────────
        customTitleLabel.font                         = .systemFont(ofSize: 17, weight: .semibold)
        customTitleLabel.textColor                    = .label

        subtitleLabel.font                            = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textColor                       = .secondaryLabel

        textStackView.axis                            = .vertical
        textStackView.spacing                         = 2
        textStackView.translatesAutoresizingMaskIntoConstraints = false
        textStackView.addArrangedSubview(customTitleLabel)
        textStackView.addArrangedSubview(subtitleLabel)
        cardContainer.addSubview(textStackView)

        // ── Chevron ────────────────────────────────────
        let chevCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevronImageView.image                        = UIImage(systemName: "chevron.right", withConfiguration: chevCfg)
        chevronImageView.tintColor                    = .systemGray3
        chevronImageView.contentMode                  = .scaleAspectFit
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(chevronImageView)

        // ── Right Stack (time + badge) ─────────────────
        customTimeLabel.font                          = .systemFont(ofSize: 13, weight: .semibold)
        customTimeLabel.textColor                     = .secondaryLabel

        badgeLabel.font                               = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.layer.cornerRadius             = 6
        badgeContainer.clipsToBounds                  = true
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)

        rightStackView.axis                           = .vertical
        rightStackView.spacing                        = 6
        rightStackView.alignment                      = .trailing
        rightStackView.translatesAutoresizingMaskIntoConstraints = false
        rightStackView.addArrangedSubview(customTimeLabel)
        rightStackView.addArrangedSubview(badgeContainer)
        cardContainer.addSubview(rightStackView)

        // ── Internal Separator ─────────────────────────
        separator.backgroundColor                     = UIColor.systemGray4
        separator.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(separator)

        // ── Constraints ────────────────────────────────
        NSLayoutConstraint.activate([
            // Card fills cell with 16pt inset
            cardContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            cardContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 76),

            // Icon
            customIconContainer.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 14),
            customIconContainer.centerYAnchor.constraint(equalTo: cardContainer.centerYAnchor),
            customIconContainer.widthAnchor.constraint(equalToConstant: 44),
            customIconContainer.heightAnchor.constraint(equalToConstant: 44),

            customIconImageView.centerXAnchor.constraint(equalTo: customIconContainer.centerXAnchor),
            customIconImageView.centerYAnchor.constraint(equalTo: customIconContainer.centerYAnchor),
            customIconImageView.widthAnchor.constraint(equalToConstant: 22),
            customIconImageView.heightAnchor.constraint(equalToConstant: 22),

            // Text stack
            textStackView.leadingAnchor.constraint(equalTo: customIconContainer.trailingAnchor, constant: 12),
            textStackView.centerYAnchor.constraint(equalTo: cardContainer.centerYAnchor),

            // Chevron (rightmost)
            chevronImageView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -14),
            chevronImageView.centerYAnchor.constraint(equalTo: cardContainer.centerYAnchor),
            chevronImageView.widthAnchor.constraint(equalToConstant: 10),
            chevronImageView.heightAnchor.constraint(equalToConstant: 14),

            // Right stack (time + badge), to the left of chevron
            rightStackView.trailingAnchor.constraint(equalTo: chevronImageView.leadingAnchor, constant: -10),
            rightStackView.centerYAnchor.constraint(equalTo: cardContainer.centerYAnchor),
            rightStackView.leadingAnchor.constraint(greaterThanOrEqualTo: textStackView.trailingAnchor, constant: 8),

            // Badge label padding
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -3),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -8),

            // Separator at bottom of card
            separator.leadingAnchor.constraint(equalTo: textStackView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    // MARK: - Corner Rounding + Border

    func applyCornerRounding(isFirst: Bool, isLast: Bool) {
        self.isFirstRow = isFirst
        self.isLastRow = isLast

        var corners: CACornerMask = []
        if isFirst { corners.insert([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if isLast { corners.insert([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }

        cardContainer.layer.cornerRadius    = (isFirst || isLast) ? 16 : 0
        cardContainer.layer.maskedCorners   = corners
        cardContainer.clipsToBounds         = true

        // Use custom shape layer instead of default border to avoid double horizontal lines
        cardContainer.layer.borderWidth     = 0

        separator.isHidden = isLast
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if outlinelayer.superlayer == nil {
            outlinelayer.fillColor = UIColor.clear.cgColor
            outlinelayer.strokeColor = UIColor.systemGray3.cgColor
            outlinelayer.lineWidth = 0.5
            cardContainer.layer.addSublayer(outlinelayer)
        }

        let path = UIBezierPath()
        let bounds = cardContainer.bounds
        let r = cardContainer.layer.cornerRadius

        // Left line
        path.move(to: CGPoint(x: 0, y: isFirstRow ? r : 0))
        path.addLine(to: CGPoint(x: 0, y: isLastRow ? bounds.height - r : bounds.height))

        // Bottom-left, bottom, bottom-right
        if isLastRow {
            path.addArc(withCenter: CGPoint(x: r, y: bounds.height - r), radius: r, startAngle: .pi, endAngle: .pi / 2, clockwise: false)
            path.addLine(to: CGPoint(x: bounds.width - r, y: bounds.height))
            path.addArc(withCenter: CGPoint(x: bounds.width - r, y: bounds.height - r), radius: r, startAngle: .pi / 2, endAngle: 0, clockwise: false)
        } else {
            path.move(to: CGPoint(x: bounds.width, y: bounds.height))
        }

        // Right line
        path.addLine(to: CGPoint(x: bounds.width, y: isFirstRow ? r : 0))

        // Top-right, top, top-left
        if isFirstRow {
            path.addArc(withCenter: CGPoint(x: bounds.width - r, y: r), radius: r, startAngle: 0, endAngle: -.pi / 2, clockwise: false)
            path.addLine(to: CGPoint(x: r, y: 0))
            path.addArc(withCenter: CGPoint(x: r, y: r), radius: r, startAngle: -.pi / 2, endAngle: -.pi, clockwise: false)
        }

        outlinelayer.path = path.cgPath
    }

    func configure(with item: RoutineConversation?, isFirst: Bool, isLast: Bool, isAddRow: Bool) {
        applyCornerRounding(isFirst: isFirst, isLast: isLast)

        let config = UIImage.SymbolConfiguration(weight: .semibold)

        if isAddRow {
            customTitleLabel.text = "Add Quick Action"
            customTitleLabel.textColor = .systemBlue
            subtitleLabel.isHidden = true
            rightStackView.isHidden = true

            customIconContainer.backgroundColor = UIColor.secondarySystemFill
            if let image = UIImage(systemName: "plus", withConfiguration: config) {
                customIconImageView.image = image.withRenderingMode(.alwaysTemplate)
            }
            customIconImageView.tintColor = .secondaryLabel
        } else if let item = item {
            customTitleLabel.text = item.conversationTopic
            customTitleLabel.textColor = .label
            subtitleLabel.isHidden = false
            rightStackView.isHidden = false

            let paxCount = item.participantNames.count
            subtitleLabel.text = "\(item.categoryTitle) • \(paxCount) participants"

            customTimeLabel.text = item.startTime

            // Determine Upcoming vs Scheduled based on time
            let df = DateFormatter()
            df.dateFormat = "h:mm a"
            df.locale = Locale(identifier: "en_US_POSIX")
            var badgeText = "Scheduled"

            if let targetDate = df.date(from: item.startTime) {
                let now = Date()
                let cal = Calendar.current
                var tComps = cal.dateComponents([.hour, .minute], from: targetDate)
                let nComps = cal.dateComponents([.year, .month, .day], from: now)
                tComps.year = nComps.year
                tComps.month = nComps.month
                tComps.day = nComps.day

                if let combinedTarget = cal.date(from: tComps) {
                    let diff = combinedTarget.timeIntervalSince(now)
                    if diff > 0 && diff <= 3600 * 4 {
                        badgeText = "Upcoming"
                    }
                }
            }
            badgeLabel.text = badgeText

            if let image = UIImage(systemName: item.iconName, withConfiguration: config) {
                customIconImageView.image = image.withRenderingMode(.alwaysTemplate)
            }

            let tintColor = getColorForCategory(item.categoryTitle)

            // Add custom distinction color for 'Upcoming' status
            badgeContainer.backgroundColor = .secondarySystemFill
            badgeLabel.textColor = .label

            customIconContainer.backgroundColor = tintColor.withAlphaComponent(0.15)
            customIconImageView.tintColor = tintColor
        }
    }
}

// MARK: - Conversation Card Cell (Detailed List - Bottom Cards)
class ConversationCardCell: UITableViewCell {

    // MARK: - Outlets
    @IBOutlet weak var cardContainer: UIView!
    @IBOutlet weak var topicLabel: UILabel!
    @IBOutlet weak var descriptionLabel: UILabel!

    @IBOutlet weak var dateLabel: UILabel!
    @IBOutlet weak var timeLabel: UILabel!
    @IBOutlet weak var categoryLabel: UILabel!
    @IBOutlet weak var categoryContainer: UIView!

    @IBOutlet weak var calendarIcon: UIImageView!
    @IBOutlet weak var clockIcon: UIImageView!

    override func awakeFromNib() {
        super.awakeFromNib()
        setupDesign()
    }

    func setupDesign() {

        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.selectionStyle = .none

        cardContainer.backgroundColor = .secondarySystemGroupedBackground
        cardContainer.layer.cornerRadius = 16
        cardContainer.layer.cornerCurve = .continuous

        // Add subtle border to make the card more distinct against the background
        cardContainer.layer.borderWidth = 1
        cardContainer.layer.borderColor = UIColor.systemGray5.cgColor

        // Shadow styling - SLIGHTLY increase opacity since it's "barely perceptible"
        cardContainer.layer.shadowColor = UIColor.black.cgColor
        cardContainer.layer.shadowOpacity = 0.08
        cardContainer.layer.shadowRadius = 8
        cardContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        cardContainer.layer.masksToBounds = false
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
            topicLabel.attributedText = fullString

            descriptionLabel.numberOfLines = 1
        } else {
            topicLabel.text = conversation.title
            descriptionLabel.numberOfLines = 2
        }
        descriptionLabel.text = conversation.details

        // Slot 1 (Left): Participants
        let paxCount = max(1, conversation.participants?.count ?? 0)
        dateLabel.text = paxCount == 1 ? "1 Person" : "\(paxCount) People"
        calendarIcon.image = UIImage(systemName: "person.2.fill")
        calendarIcon.tintColor = .secondaryLabel

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
    }
}
