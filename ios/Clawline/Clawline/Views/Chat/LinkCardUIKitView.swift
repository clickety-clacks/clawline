//
//  LinkCardUIKitView.swift
//  Clawline
//
//  Lightweight "link card" for message bubbles.
//

import UIKit
import SafariServices

final class LinkCardUIKitView: UIControl {
    private static let imageCache = NSCache<NSString, UIImage>()

    private let shadowHost = UIView()
    private let cardBackground = UIView()
    private let indicatorView = UIView()
    private let domainLabel = UILabel()
    private let titleLabel = UILabel()
    private let descLabel = UILabel()
    private let textStack = UIStackView()
    private let rootRow = UIStackView()
    private let thumbnailView = UIImageView()
    private var url: URL?
    private var metadataTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var lastMeasuredWidth: CGFloat = 0
    private var lastReportedHeight: CGFloat = 0

    // BubbleSizingV2 caches measurements; link cards update async (OpenGraph metadata, thumbnails).
    // When content changes, we need to request a re-measure so the bubble grows and avoids clipping.
    var onHeightChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        // This view is used inside UIStackView. Ensure it participates in Auto Layout sizing.
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)

        backgroundColor = .clear
        clipsToBounds = false

        // UIControl only fires `.touchUpInside` if it receives touch events. Since the card is
        // built from container subviews, disable hit-testing on them so touches resolve to `self`.
        // (Otherwise taps hit the internal stack/labels and the card appears "dead".)
        shadowHost.isUserInteractionEnabled = false
        cardBackground.isUserInteractionEnabled = false

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.backgroundColor = .clear
        shadowHost.clipsToBounds = false
        addSubview(shadowHost)

        cardBackground.translatesAutoresizingMaskIntoConstraints = false
        cardBackground.layer.cornerRadius = 16
        cardBackground.layer.cornerCurve = .continuous
        cardBackground.clipsToBounds = true
        shadowHost.addSubview(cardBackground)

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.layer.cornerRadius = 3
        indicatorView.layer.cornerCurve = .continuous

        domainLabel.translatesAutoresizingMaskIntoConstraints = false
        domainLabel.font = UIFont.clawline(.timestamp)
        domainLabel.adjustsFontForContentSizeCategory = true
        domainLabel.numberOfLines = 1
        domainLabel.lineBreakMode = .byTruncatingTail
        domainLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        domainLabel.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.clawline(.mediumMessage)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)

        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = UIFont.clawline(.secondaryLabel)
        descLabel.adjustsFontForContentSizeCategory = true
        descLabel.numberOfLines = 2
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        descLabel.setContentHuggingPriority(.required, for: .vertical)

        let domainRow = UIStackView(arrangedSubviews: [indicatorView, domainLabel])
        domainRow.translatesAutoresizingMaskIntoConstraints = false
        domainRow.axis = .horizontal
        domainRow.alignment = .center
        domainRow.spacing = 8

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 0
        textStack.setContentCompressionResistancePriority(.required, for: .vertical)
        textStack.setContentHuggingPriority(.required, for: .vertical)
        textStack.addArrangedSubview(domainRow)
        textStack.setCustomSpacing(6, after: domainRow)
        textStack.addArrangedSubview(titleLabel)
        textStack.setCustomSpacing(4, after: titleLabel)
        textStack.addArrangedSubview(descLabel)

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 12
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.isHidden = true
        thumbnailView.setContentHuggingPriority(.required, for: .horizontal)
        thumbnailView.setContentCompressionResistancePriority(.required, for: .horizontal)

        rootRow.translatesAutoresizingMaskIntoConstraints = false
        rootRow.axis = .horizontal
        rootRow.alignment = .top
        rootRow.spacing = 12
        rootRow.isLayoutMarginsRelativeArrangement = true
        rootRow.layoutMargins = UIEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        rootRow.addArrangedSubview(textStack)
        rootRow.addArrangedSubview(thumbnailView)
        cardBackground.addSubview(rootRow)

        NSLayoutConstraint.activate([
            // Keep shadow visible even though bubble content clips; reserve a small inset for blur.
            shadowHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            shadowHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            shadowHost.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            shadowHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            cardBackground.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            cardBackground.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            cardBackground.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            cardBackground.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),

            indicatorView.widthAnchor.constraint(equalToConstant: 6),
            indicatorView.heightAnchor.constraint(equalToConstant: 6),

            thumbnailView.widthAnchor.constraint(equalToConstant: 56),
            thumbnailView.heightAnchor.constraint(equalToConstant: 56),

            rootRow.leadingAnchor.constraint(equalTo: cardBackground.leadingAnchor),
            rootRow.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor),
            rootRow.topAnchor.constraint(equalTo: cardBackground.topAnchor),
            rootRow.bottomAnchor.constraint(equalTo: cardBackground.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(url: URL, palette: ChatFlowUIKitTheme.Palette) {
        self.url = url
        metadataTask?.cancel()
        imageTask?.cancel()
        lastReportedHeight = 0
        thumbnailView.image = nil
        thumbnailView.isHidden = true

        // Match design-system/chat-flow-organic: .link-preview-card
        cardBackground.backgroundColor = palette.isDark
            ? UIColor.black.withAlphaComponent(0.25)
            : UIColor.white.withAlphaComponent(0.7)

        shadowHost.layer.shadowOffset = CGSize(width: 0, height: 2)
        shadowHost.layer.shadowRadius = 4
        if palette.isDark {
            shadowHost.layer.shadowColor = UIColor.black.cgColor
            shadowHost.layer.shadowOpacity = 0.15
        } else {
            shadowHost.layer.shadowColor = UIColor(red: 60/255, green: 45/255, blue: 30/255, alpha: 1).cgColor
            shadowHost.layer.shadowOpacity = 0.06
        }

        indicatorView.backgroundColor = palette.terracotta

        let host = (url.host ?? url.absoluteString)
        let domainText = host.uppercased()
        domainLabel.attributedText = NSAttributedString(
            string: domainText,
            attributes: [
                .kern: 0.5,
                .foregroundColor: palette.warmBrown
            ]
        )

        // #54: default fallback is a sensible URL display (full URL), then replace with OpenGraph metadata.
        titleLabel.text = url.absoluteString
        descLabel.text = nil

        domainLabel.textColor = palette.warmBrown
        titleLabel.textColor = palette.ink
        descLabel.textColor = palette.warmBrown
        descLabel.isHidden = true

        accessibilityLabel = "Open link: \(host)"

        metadataTask = Task { [weak self] in
            guard let self else { return }
            let currentURL = url
            if let meta = await LinkCardMetadataFetcher.shared.metadata(for: currentURL) {
                await MainActor.run {
                    guard self.url?.absoluteString == currentURL.absoluteString else { return }
                    self.titleLabel.text = meta.title
                    if let desc = meta.description, !desc.isEmpty {
                        self.descLabel.text = desc
                        self.descLabel.isHidden = false
                    } else {
                        self.descLabel.text = nil
                        self.descLabel.isHidden = true
                    }
                    self.notifyHeightChangeIfNeeded()
                }

                if let imageURL = meta.imageURL {
                    await self.loadThumbnail(imageURL: imageURL, for: currentURL)
                }
            } else {
                await MainActor.run {
                    guard self.url?.absoluteString == currentURL.absoluteString else { return }
                    self.titleLabel.text = currentURL.absoluteString
                    self.descLabel.text = nil
                    self.descLabel.isHidden = true
                    self.notifyHeightChangeIfNeeded()
                }
            }
        }
    }

    override var isHighlighted: Bool {
        didSet {
            let alpha: CGFloat = isHighlighted ? 0.85 : 1.0
            shadowHost.alpha = alpha
        }
    }

    override var intrinsicContentSize: CGSize {
        // Avoid calling `systemLayoutSizeFitting` on `self` from intrinsic sizing; UIKit may ask for
        // `intrinsicContentSize` while computing a fitting size, which can recurse and overflow the stack.
        let width = bounds.width > 1 ? bounds.width : (lastMeasuredWidth > 1 ? lastMeasuredWidth : 320)
        let height = measuredHeight(for: width, horizontalPriority: bounds.width > 1 ? .required : .fittingSizeLevel)
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        lastMeasuredWidth = size.width
        return CGSize(width: size.width, height: measuredHeight(for: size.width, horizontalPriority: .required))
    }

    private func measuredHeight(for width: CGFloat, horizontalPriority: UILayoutPriority) -> CGFloat {
        // `rootRow` is pinned to `cardBackground`, which is pinned to `shadowHost`.
        // Shadow host is inset by 4pt on each side and 2/6pt vertically.
        let rootWidth = max(0, width - 8)
        let target = CGSize(width: rootWidth, height: UIView.layoutFittingCompressedSize.height)
        let measured = rootRow.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: .fittingSizeLevel
        )

        // `shadowHost` is inset by 2pt top and 6pt bottom (8pt total) relative to `self`.
        return ceil(measured.height + 8)
    }

    @objc private func handleTap() {
        guard let url else { return }
#if os(visionOS)
        UIApplication.shared.open(url)
#else
        // Prefer an in-app browser so the user doesn't context-switch out of Clawline.
        if let viewController = parentViewController {
            let safari = SFSafariViewController(url: url)
            viewController.present(safari, animated: true)
        } else {
            UIApplication.shared.open(url)
        }
#endif
    }

    private func loadThumbnail(imageURL: URL, for url: URL) async {
        let cacheKey = imageURL.absoluteString as NSString
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            await MainActor.run {
                guard self.url?.absoluteString == url.absoluteString else { return }
                self.thumbnailView.image = cached
                self.thumbnailView.isHidden = false
                self.notifyHeightChangeIfNeeded()
            }
            return
        }

        imageTask?.cancel()
        imageTask = Task { [weak self] in
            guard let self else { return }
            var request = URLRequest(url: imageURL)
            request.timeoutInterval = 8
            request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 8
            let session = URLSession(configuration: config)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return }
                guard let image = UIImage(data: data) else { return }
                Self.imageCache.setObject(image, forKey: cacheKey)
                await MainActor.run {
                    guard self.url?.absoluteString == url.absoluteString else { return }
                    self.thumbnailView.image = image
                    self.thumbnailView.isHidden = false
                    self.notifyHeightChangeIfNeeded()
                }
            } catch {
                return
            }
        }
        _ = await imageTask?.value
    }

    private func notifyHeightChangeIfNeeded() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let width = (self.bounds.width > 1)
                ? self.bounds.width
                : (self.lastMeasuredWidth > 1 ? self.lastMeasuredWidth : 320)
            let priority: UILayoutPriority = (self.bounds.width > 1) ? .required : .fittingSizeLevel
            let newHeight = self.measuredHeight(for: width, horizontalPriority: priority)
            let epsilon: CGFloat = 1
            guard abs(newHeight - self.lastReportedHeight) > epsilon else { return }
            self.lastReportedHeight = newHeight
            self.onHeightChange?()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Update shadow path for better performance and correct shape.
        let cornerRadius = cardBackground.layer.cornerRadius
        let path = UIBezierPath(roundedRect: shadowHost.bounds, cornerRadius: cornerRadius).cgPath
        shadowHost.layer.shadowPath = path
        if abs(bounds.width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

private extension UIView {
    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}
