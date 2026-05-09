//
//  WebBubbleUIKitCell.swift
//  Clawline
//
//  #57: Popup bubbles that host a persistent-session WKWebView.
//

import Foundation
import UIKit
import WebKit

final class WebBubbleUIKitCell: UICollectionViewCell {
    static let reuseIdentifier = "WebBubbleUIKitCell"

    private let bubbleBackgroundView = UIView()
    private let headerStack = UIStackView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let webContainer = UIView()

    private weak var hostedWebView: WKWebView?
    private var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        bubbleBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackgroundView.layer.cornerRadius = 18
        bubbleBackgroundView.layer.cornerCurve = .continuous
        bubbleBackgroundView.clipsToBounds = true
        contentView.addSubview(bubbleBackgroundView)

        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.distribution = .fill
        headerStack.spacing = 10
        bubbleBackgroundView.addSubview(headerStack)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle
        headerStack.addArrangedSubview(titleLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "Close popup"
        closeButton.accessibilityTraits = .button
        closeButton.addTarget(self, action: #selector(handleCloseTap), for: .touchUpInside)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        headerStack.addArrangedSubview(closeButton)

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = .clear
        webContainer.clipsToBounds = true
        bubbleBackgroundView.addSubview(webContainer)

        NSLayoutConstraint.activate([
            bubbleBackgroundView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bubbleBackgroundView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bubbleBackgroundView.topAnchor.constraint(equalTo: contentView.topAnchor),
            bubbleBackgroundView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            headerStack.leadingAnchor.constraint(equalTo: bubbleBackgroundView.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: bubbleBackgroundView.trailingAnchor, constant: -6),
            headerStack.topAnchor.constraint(equalTo: bubbleBackgroundView.topAnchor, constant: 10),

            webContainer.leadingAnchor.constraint(equalTo: bubbleBackgroundView.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: bubbleBackgroundView.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            webContainer.bottomAnchor.constraint(equalTo: bubbleBackgroundView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        detachHostedWebView()
        onClose = nil
        titleLabel.text = nil
    }

    func configure(
        item: WebBubbleItem,
        coordinator: any WebBubbleCoordinating,
        isDark: Bool
    ) {
        titleLabel.text = item.title
            ?? item.initialURL?.host
            ?? (item.isPopup ? "Popup" : "Web")

        bubbleBackgroundView.backgroundColor = isDark
            ? UIColor.black.withAlphaComponent(0.20)
            : UIColor.white.withAlphaComponent(0.70)
        bubbleBackgroundView.layer.borderWidth = 1
        bubbleBackgroundView.layer.borderColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.06).cgColor

        onClose = { [weak coordinator] in
            coordinator?.dismissWebBubble(id: item.id)
        }

        if let webView = coordinator.webView(for: item.id) {
            attachHostedWebView(webView)
        } else {
            detachHostedWebView()
        }
    }

    @objc private func handleCloseTap() {
        onClose?()
    }

    private func attachHostedWebView(_ webView: WKWebView) {
        if hostedWebView === webView { return }
        detachHostedWebView()

        hostedWebView = webView
        if webView.superview != nil {
            webView.removeFromSuperview()
        }

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
    }

    private func detachHostedWebView() {
        guard let webView = hostedWebView else { return }
        hostedWebView = nil
        webView.removeFromSuperview()
    }
}

