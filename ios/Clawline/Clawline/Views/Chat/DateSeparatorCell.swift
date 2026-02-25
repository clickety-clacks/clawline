//
//  DateSeparatorCell.swift
//  Clawline
//

import UIKit

final class DateSeparatorCell: UICollectionViewCell {
    static let reuseIdentifier = "DateSeparatorCell"
    static let itemIdPrefix = "__date_separator__|"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.numberOfLines = 1
        label.font = UIFont.clawline(.senderName)
        label.adjustsFontForContentSizeCategory = true
        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, isDark: Bool) {
        let palette = ChatFlowUIKitTheme.palette(isDark: isDark)
        label.textColor = palette.textMuted.withAlphaComponent(0.7)
        label.text = text
    }

    static func itemID(before messageID: String) -> String {
        "\(itemIdPrefix)\(messageID)"
    }

    static func isDateSeparatorItemID(_ itemID: String) -> Bool {
        itemID.hasPrefix(itemIdPrefix)
    }
}
