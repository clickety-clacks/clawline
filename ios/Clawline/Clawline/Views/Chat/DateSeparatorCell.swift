//
//  DateSeparatorCell.swift
//  Clawline
//

import UIKit

final class DateSeparatorCell: UICollectionViewCell {
    static let reuseIdentifier = "DateSeparatorCell"
    static let itemIdPrefix = "__date_separator__|"
    static let topPadding: CGFloat = 24
    static let bottomPadding: CGFloat = 8

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .left
        label.numberOfLines = 1
        label.font = UIFont.clawline(.uiLabel, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.topPadding),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.bottomPadding)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, isDark: Bool) {
        let palette = ChatFlowUIKitTheme.palette(isDark: isDark)
        label.textColor = palette.ink.withAlphaComponent(isDark ? 0.98 : 0.9)
        label.text = text
    }

    static func itemID(before messageID: String) -> String {
        "\(itemIdPrefix)\(messageID)"
    }

    static func isDateSeparatorItemID(_ itemID: String) -> Bool {
        itemID.hasPrefix(itemIdPrefix)
    }
}
