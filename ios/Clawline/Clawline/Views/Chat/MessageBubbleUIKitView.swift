//
//  MessageBubbleUIKitView.swift
//  Clawline
//
//  UIKit-only bubble view for layout debugging.
//

import Foundation
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MessageBubbleShadowStyle {
    static let radius: CGFloat = 12
    static let offset = CGSize(width: 0, height: 5)

    static func opacity(isDark: Bool) -> Float {
        isDark ? 0.25 : 0.24
    }
}

struct MessageBubbleMetadataDebugState {
    let senderText: String?
    let senderLineBreakMode: NSLineBreakMode
    let senderCompressionResistance: UILayoutPriority
    let timestampCompressionResistance: UILayoutPriority
    let timestampHidden: Bool
    let timestampAlpha: CGFloat
    let headerWidth: CGFloat
    let metadataNeededWidth: CGFloat
}

private final class BubbleSafeAreaNeutralScrollView: UIScrollView {
    override var safeAreaInsets: UIEdgeInsets { .zero }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        stabilizeInsetBehavior()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stabilizeInsetBehavior()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stabilizeInsetBehavior()
    }

    private func stabilizeInsetBehavior() {
        if contentInsetAdjustmentBehavior != .never {
            contentInsetAdjustmentBehavior = .never
        }
        if #available(iOS 13.0, visionOS 1.0, *), automaticallyAdjustsScrollIndicatorInsets {
            automaticallyAdjustsScrollIndicatorInsets = false
        }
        insetsLayoutMarginsFromSafeArea = false
    }
}

enum RemoteMessageImagePolicy {
    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    static func image(from data: Data, response: URLResponse?) -> UIImage? {
        if let http = response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            return nil
        }
        return UIImage(data: data)
    }
}

enum ImagePopupViewerLayout {
    static func initialZoomScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return 1
        }

        let fitScale = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        return min(1, fitScale)
    }

    static func centeredContentInset(contentSize: CGSize, viewportSize: CGSize) -> UIEdgeInsets {
        let horizontal = max(0, (viewportSize.width - contentSize.width) / 2)
        let vertical = max(0, (viewportSize.height - contentSize.height) / 2)
        return UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

private class MessageImageThumbnailView: UIImageView {
    var onImageTap: ((UIImage) -> Void)?

    init() {
        super.init(frame: .zero)
        configureTap()
    }

    override init(image: UIImage?) {
        super.init(image: image)
        configureTap()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTap()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTap()
    }

    private func configureTap() {
        isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = true
        addGestureRecognizer(tap)
        accessibilityTraits.insert(.button)
    }

    @objc private func handleTap() {
        guard let image else { return }
        onImageTap?(image)
    }
}

private final class ImagePopupViewerController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let image: UIImage
    private let popupView = UIView()
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var didSetInitialZoomScale = false
    private weak var indirectZoomRecognizer: UIPanGestureRecognizer?

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.black.withAlphaComponent(0.55)

        popupView.translatesAutoresizingMaskIntoConstraints = false
        popupView.backgroundColor = .systemBackground
        popupView.layer.cornerRadius = 18
        popupView.layer.cornerCurve = .continuous
        popupView.clipsToBounds = true
        view.addSubview(popupView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        popupView.addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(origin: .zero, size: image.size)
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .label
        closeButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        closeButton.layer.cornerRadius = 18
        closeButton.layer.cornerCurve = .continuous
        closeButton.accessibilityLabel = "Close image viewer"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        popupView.addSubview(closeButton)

        let indirectZoom = UIPanGestureRecognizer(target: self, action: #selector(handleIndirectScrollZoom))
        indirectZoom.allowedScrollTypesMask = .all
        indirectZoom.delegate = self
        scrollView.addGestureRecognizer(indirectZoom)
        scrollView.panGestureRecognizer.require(toFail: indirectZoom)
        indirectZoomRecognizer = indirectZoom

        NSLayoutConstraint.activate([
            popupView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            popupView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            popupView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            popupView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),

            scrollView.leadingAnchor.constraint(equalTo: popupView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: popupView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: popupView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: popupView.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: popupView.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: popupView.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalTo: closeButton.widthAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configureZoomScale()
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== indirectZoomRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.numberOfTouches == 0
    }

    private func configureZoomScale() {
        let initialScale = ImagePopupViewerLayout.initialZoomScale(
            imageSize: image.size,
            viewportSize: scrollView.bounds.size
        )
        scrollView.minimumZoomScale = initialScale
        scrollView.maximumZoomScale = max(8, initialScale * 8)
        if !didSetInitialZoomScale {
            scrollView.zoomScale = initialScale
            didSetInitialZoomScale = true
        } else if scrollView.zoomScale < initialScale {
            scrollView.zoomScale = initialScale
        }
        scrollView.contentSize = image.size
    }

    private func centerImage() {
        let contentSize = CGSize(
            width: image.size.width * scrollView.zoomScale,
            height: image.size.height * scrollView.zoomScale
        )
        scrollView.contentInset = ImagePopupViewerLayout.centeredContentInset(
            contentSize: contentSize,
            viewportSize: scrollView.bounds.size
        )
    }

    @objc private func handleIndirectScrollZoom(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else {
            recognizer.setTranslation(.zero, in: scrollView)
            return
        }

        let translation = recognizer.translation(in: scrollView)
        let multiplier = max(0.5, min(1.5, 1 - (translation.y / 300)))
        let targetScale = min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, scrollView.zoomScale * multiplier))
        scrollView.setZoomScale(targetScale, animated: false)
        recognizer.setTranslation(.zero, in: scrollView)
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

private final class RemoteMessageImageView: MessageImageThumbnailView {
    private var task: URLSessionDataTask?
    private var configuredURL: URL?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var maxWidth: CGFloat = 0
    private var maxHeight: CGFloat = 0
    private var onLoad: (() -> Void)?

    @MainActor deinit {
        task?.cancel()
    }

    func configure(
        url: URL,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        cornerRadius: CGFloat,
        onTap: @escaping (UIImage) -> Void,
        onLoad: @escaping () -> Void
    ) {
        task?.cancel()
        task = nil
        configuredURL = url
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.onLoad = onLoad
        onImageTap = onTap
        image = nil
        backgroundColor = UIColor.secondarySystemFill
        contentMode = .scaleAspectFit
        clipsToBounds = true
        layer.cornerRadius = cornerRadius
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityLabel = "Image"

        if widthConstraint == nil {
            let constraint = widthAnchor.constraint(equalToConstant: maxWidth)
            constraint.isActive = true
            widthConstraint = constraint
        } else {
            widthConstraint?.constant = maxWidth
        }

        if heightConstraint == nil {
            let constraint = heightAnchor.constraint(equalToConstant: preferredPlaceholderHeight())
            constraint.isActive = true
            heightConstraint = constraint
        } else {
            heightConstraint?.constant = preferredPlaceholderHeight()
        }

        let request = RemoteMessageImagePolicy.request(for: url)
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let data,
                  let image = RemoteMessageImagePolicy.image(from: data, response: response) else {
                return
            }
            DispatchQueue.main.async {
                guard let self, self.configuredURL == url else { return }
                self.backgroundColor = .clear
                self.image = image
                self.heightConstraint?.constant = self.preferredHeight(for: image)
                self.invalidateIntrinsicContentSize()
                self.onLoad?()
            }
        }
        task?.resume()
    }

    private func preferredPlaceholderHeight() -> CGFloat {
        min(maxHeight, max(120, maxWidth * 9 / 16))
    }

    private func preferredHeight(for image: UIImage) -> CGFloat {
        let aspectRatio = image.size.height / max(image.size.width, 1)
        return min(maxHeight, maxWidth * aspectRatio)
    }
}

final class MessageBubbleUIKitContainerView: UIView {
    private let bubbleView: MessageBubbleUIKitView
    private let badgeView = MessageFailureBadgeView()
    private var bubbleBottomConstraint: NSLayoutConstraint!
    private var badgeBottomConstraint: NSLayoutConstraint!
    private var badgeTrailingConstraint: NSLayoutConstraint!
    private var onResend: (() -> Void)?
    private var onRequestLayout: ((String) -> Void)?

    override init(frame: CGRect) {
        self.bubbleView = MessageBubbleUIKitView()
        super.init(frame: frame)
        backgroundColor = .clear

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubbleView)

        bubbleBottomConstraint = bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubbleView.topAnchor.constraint(equalTo: topAnchor),
            bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubbleBottomConstraint
        ])

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeView)
        badgeTrailingConstraint = badgeView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -6)
        badgeBottomConstraint = badgeView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor)
        NSLayoutConstraint.activate([
            badgeTrailingConstraint,
            badgeBottomConstraint
        ])
        badgeView.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   failureReason: String?,
                   isCompact: Bool,
                   maxWidth: CGFloat,
                   bubbleHeightPolicy: BubbleSizingV2.BubbleHeightPolicy? = nil,
                   truncationHeightOverride: CGFloat? = nil,
                   bubbleSizingV2: BubbleSizingV2.LayoutState? = nil,
                   showsHeader: Bool = true,
                   paddingScale: CGFloat = 1,
                   minWidthOverride: CGFloat? = nil,
                   maxWidthOverride: CGFloat? = nil,
                   useContinuousCorners: Bool = true,
                   isDark: Bool? = nil,
                   terminalConnectionPool: TerminalSessionConnectionPool? = nil,
                   webBubbleCoordinator: (any WebBubbleCoordinating)? = nil,
                   salientHighlightService: (any SalientHighlightServicing)? = nil,
                   onRequestExpand: (() -> Void)?,
                   onRequestLayout: ((String) -> Void)?,
                   onInteractiveCallback: ((String, String, JSONValue?) -> Void)?,
                   onResend: (() -> Void)?) {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        bubbleView.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth,
            bubbleHeightPolicy: bubbleHeightPolicy,
            truncationHeightOverride: truncationHeightOverride,
            bubbleSizingV2: bubbleSizingV2,
            showsHeader: showsHeader,
            paddingScale: paddingScale,
            minWidthOverride: minWidthOverride,
            maxWidthOverride: maxWidthOverride,
            useContinuousCorners: useContinuousCorners,
            isDark: isDark,
            terminalConnectionPool: terminalConnectionPool,
            webBubbleCoordinator: webBubbleCoordinator,
            onRequestExpand: onRequestExpand,
            onRequestLayout: onRequestLayout,
            onInteractiveCallback: onInteractiveCallback,
            salientHighlightService: salientHighlightService





        )
        self.onResend = onResend
        self.onRequestLayout = onRequestLayout

        if failureReason != nil {
            badgeView.isHidden = false
            badgeView.configure(onResend: { [weak self] in
                self?.onResend?()
            })
            bubbleBottomConstraint.constant = 0
            badgeBottomConstraint.constant = -6
            badgeTrailingConstraint.constant = -6
        } else {
            badgeView.isHidden = true
            bubbleBottomConstraint.constant = 0
            badgeBottomConstraint.constant = 0
            badgeTrailingConstraint.constant = 0
        }
    }

    func prepareForReuse() {
        // Truncated bubbles use an inner vertical scroll view. Resetting the bubble prevents
        // reused cells from inheriting a non-zero contentOffset (GitHub #56).
        bubbleView.prepareForReuse()
        badgeView.isHidden = true
        onResend = nil
        onRequestLayout = nil
        bubbleBottomConstraint.constant = 0
        badgeBottomConstraint.constant = 0
        badgeTrailingConstraint.constant = 0
    }

    func setCenteredOverlayView(_ view: UIView?) {
        bubbleView.setCenteredOverlayView(view)
    }

    func bubbleFrameInContainer() -> CGRect {
        bubbleView.frame
    }
}

final class MessageBubbleUIKitView: UIView, UITextViewDelegate {
    private static let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "BubbleTheme")
    static func timestampTextAlpha(isDark: Bool) -> CGFloat {
        isDark ? 0.76 : 0.68
    }

    override var safeAreaInsets: UIEdgeInsets { .zero }
    private let enableDataDetectors: Bool
    private var terminalConnectionPool: TerminalSessionConnectionPool?
    private let shadowContainerView = UIView()  // Separate view for shadow (masks clip shadows)
    private let bubbleBackgroundView = UIView()
    private let contentStack = UIStackView()
    private let headerStack = UIStackView()
    private let dynamicContentWrapper = UIView()  // Clips for truncation
    private let dynamicContentScrollView = BubbleSafeAreaNeutralScrollView()
    private let dynamicContentStack = UIStackView()  // Holds text + code blocks
    private let avatarView = AvatarCircleView()
    private let senderLabel = UILabel()
    private let senderTimestampSpacer = UIView()
    private let timestampLabel = UILabel()
    private let bodyLabel = UITextView()
    private let bodyTextContainer = UIView()
    private let fadeView = TruncationFadeView()
    private static let bubbleScrollFadeHeight: CGFloat = 25
    private static let mediaMaxHeight: CGFloat = 300
    private static let mediaCornerRadius: CGFloat = 12
    // Keep large-screen bubble sizing aligned to iPad mini reference geometry.
    private static let bubbleReferenceSize = CGSize(width: 744, height: 1133)

    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private let borderGradientLayer = CAGradientLayer()
    private let borderMaskLayer = CAShapeLayer()
    private let topHighlightLayer = CAGradientLayer()
    private let topHighlightMask = CAShapeLayer()

    private var maxWidthConstraint: NSLayoutConstraint!
    private var minWidthConstraint: NSLayoutConstraint!
    private var fixedWidthConstraint: NSLayoutConstraint?
    private var bodyMaxWidthConstraint: NSLayoutConstraint?
    private var dynamicContentHeightConstraint: NSLayoutConstraint?
    private var fileTapHandlers: [ObjectIdentifier: () -> Void] = [:]
    private var onRequestExpand: (() -> Void)?
    private var onRequestLayout: ((String) -> Void)?
    private var onInteractiveCallback: ((String, String, JSONValue?) -> Void)?

    // Salient highlights are applied asynchronously and must be cancelable on cell reuse.
    private var salientTask: Task<Void, Never>?
    private var salientToken: Int = 0
    private var salientMessageId: String?
    private var salientBaseAttributedText: NSAttributedString?
    private var currentSalientHighlights: SalientHighlights?
    private var currentMetrics = ChatFlowTheme.Metrics(isCompact: true)
    private var currentMessageRole: Message.Role = .assistant
    private var currentStream: ChatStream = .personal
    private var currentSizeClass: MessageSizeClass = .short
    private var explicitIsDarkOverride: Bool?
    private var currentContentPaddingHorizontal: CGFloat = 16
    private var currentContentPaddingVertical: CGFloat = 14
    private var contentLeadingConstraint: NSLayoutConstraint!
    private var contentTrailingConstraint: NSLayoutConstraint!
    private var contentTopConstraint: NSLayoutConstraint!
    private var contentBottomConstraint: NSLayoutConstraint!
    private var wrapperPrefersContentHeightConstraint: NSLayoutConstraint?
    private var dynamicContentViews: [UIView] = []
    private var isChromeless = false
    private var hasTerminalSessionsForLayout = false
    private var showsHeader = true
    private var contentPaddingScale: CGFloat = 1
    private var useContinuousCorners = true
    private weak var centeredOverlayView: UIView?
    private var currentMessageId: String?
    private var wasOverflowingOnLastLayout = false
    private var suppressExpandTapForLinkCards = false
    private var allowSwipeUpExpandForSingleLink = false
    private var timestampDate: Date?
    private var timestampRefreshTimer: Timer?

    private var traitObservation: (any NSObjectProtocol)?

    private static func gradientBottomColor(for role: Message.Role, palette: ChatFlowUIKitTheme.Palette) -> UIColor {
        let gradient = role == .user ? palette.bubbleSelfGradient : palette.bubbleOtherGradient
        if let bottom = gradient.last ?? gradient.first {
            return bottom
        }
        return role == .user ? palette.sage : palette.cream
    }

    override init(frame: CGRect) {
        self.enableDataDetectors = false
        super.init(frame: frame)
        configureViewHierarchy()
    }

    init(frame: CGRect = .zero,
         enableDataDetectors: Bool,
         terminalConnectionPool: TerminalSessionConnectionPool? = nil) {
        self.enableDataDetectors = enableDataDetectors
        self.terminalConnectionPool = terminalConnectionPool
        super.init(frame: frame)
        configureViewHierarchy()
    }

    private func configureViewHierarchy() {
        backgroundColor = .clear
        insetsLayoutMarginsFromSafeArea = false
        preservesSuperviewLayoutMargins = false

        // Register for trait changes (modern API, replaces deprecated traitCollectionDidChange)
        traitObservation = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (view: MessageBubbleUIKitView, previousTraitCollection: UITraitCollection) in
            self?.updateAppearanceColors()
        }

        // Shadow container (behind bubble, clear background with shadowPath)
        shadowContainerView.translatesAutoresizingMaskIntoConstraints = false
        shadowContainerView.backgroundColor = .clear
        addSubview(shadowContainerView)

        bubbleBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackgroundView.isUserInteractionEnabled = true
        bubbleBackgroundView.insetsLayoutMarginsFromSafeArea = false
        bubbleBackgroundView.preservesSuperviewLayoutMargins = false
        let bubbleTap = UITapGestureRecognizer(target: self, action: #selector(handleBubbleTap))
        bubbleTap.cancelsTouchesInView = false
        bubbleTap.delaysTouchesBegan = false
        bubbleTap.delaysTouchesEnded = false
        bubbleBackgroundView.addGestureRecognizer(bubbleTap)
        let bubbleSwipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleBubbleSwipeUp))
        bubbleSwipeUp.direction = .up
        bubbleSwipeUp.cancelsTouchesInView = false
        bubbleSwipeUp.delaysTouchesBegan = false
        bubbleSwipeUp.delaysTouchesEnded = false
        bubbleBackgroundView.addGestureRecognizer(bubbleSwipeUp)
        addSubview(bubbleBackgroundView)
        maxWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        minWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        NSLayoutConstraint.activate([
            bubbleBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubbleBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            // Fill the allocated cell width. The flow layout decides the cell width; the bubble background
            // should match it so "wide" bubbles don't render with a right-side gap.
            bubbleBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubbleBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            maxWidthConstraint,
            minWidthConstraint,
            // Shadow container matches bubble frame (clear background, no inset needed)
            shadowContainerView.leadingAnchor.constraint(equalTo: bubbleBackgroundView.leadingAnchor),
            shadowContainerView.topAnchor.constraint(equalTo: bubbleBackgroundView.topAnchor),
            shadowContainerView.trailingAnchor.constraint(equalTo: bubbleBackgroundView.trailingAnchor),
            shadowContainerView.bottomAnchor.constraint(equalTo: bubbleBackgroundView.bottomAnchor)
        ])
        bubbleBackgroundView.setContentHuggingPriority(.required, for: .horizontal)
        bubbleBackgroundView.setContentCompressionResistancePriority(.required, for: .horizontal)

        bubbleBackgroundView.layer.insertSublayer(gradientLayer, at: 0)
        bubbleBackgroundView.layer.mask = maskLayer

        // 3D border rim - subtle highlight at top
        borderGradientLayer.colors = [
            UIColor.white.withAlphaComponent(0.14).cgColor,
            UIColor.white.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor
        ]
        borderGradientLayer.locations = [0.0, 0.25, 0.55, 1.0]
        borderGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        borderGradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        borderMaskLayer.fillColor = nil
        borderMaskLayer.strokeColor = UIColor.white.cgColor
        borderMaskLayer.lineWidth = 1.0
        borderGradientLayer.mask = borderMaskLayer
        layer.addSublayer(borderGradientLayer)

        // 1pt inner highlight at top edge
        topHighlightLayer.colors = [
            UIColor.white.withAlphaComponent(0.12).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor
        ]
        topHighlightLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        topHighlightLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        topHighlightMask.fillColor = UIColor.white.cgColor
        topHighlightLayer.mask = topHighlightMask
        layer.addSublayer(topHighlightLayer)

        contentStack.axis = .vertical
        contentStack.spacing = 10
        contentStack.alignment = .fill
        contentStack.insetsLayoutMarginsFromSafeArea = false
        contentStack.preservesSuperviewLayoutMargins = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleBackgroundView.addSubview(contentStack)

        headerStack.axis = .horizontal
        headerStack.spacing = 10
        headerStack.alignment = .center
        headerStack.isLayoutMarginsRelativeArrangement = true
        headerStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4)
        headerStack.insetsLayoutMarginsFromSafeArea = false
        headerStack.preservesSuperviewLayoutMargins = false
        headerStack.setContentHuggingPriority(.required, for: .vertical)
        headerStack.setContentCompressionResistancePriority(.required, for: .vertical)

        senderLabel.numberOfLines = 1
        senderLabel.lineBreakMode = .byClipping
        senderLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        senderLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        senderTimestampSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        senderTimestampSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timestampLabel.numberOfLines = 1
        timestampLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timestampLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        headerStack.addArrangedSubview(avatarView)
        headerStack.addArrangedSubview(senderLabel)
        headerStack.addArrangedSubview(senderTimestampSpacer)
        headerStack.addArrangedSubview(timestampLabel)
        senderLabel.firstBaselineAnchor.constraint(equalTo: timestampLabel.firstBaselineAnchor).isActive = true

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        UnifiedMarkdownRenderer.configureTextView(
            bodyLabel,
            delegate: self,
            enableDataDetectors: enableDataDetectors
        )
        let bodyTap = UITapGestureRecognizer(target: self, action: #selector(handleBubbleTap))
        bodyTap.cancelsTouchesInView = false
        bodyTap.delaysTouchesBegan = false
        bodyTap.delaysTouchesEnded = false
        bodyLabel.addGestureRecognizer(bodyTap)
        if let longPress = bodyLabel.gestureRecognizers?.first(where: { $0 is UILongPressGestureRecognizer }) {
            bubbleTap.require(toFail: longPress)
            bodyTap.require(toFail: longPress)
        }

        bodyTextContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyTextContainer.backgroundColor = .clear
        bodyTextContainer.addSubview(bodyLabel)
        // Keep text left-aligned and allow OTW caps without forcing non-text content to narrow.
        let bodyPrefersFillWidth = bodyLabel.widthAnchor.constraint(equalTo: bodyTextContainer.widthAnchor)
        bodyPrefersFillWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            bodyLabel.topAnchor.constraint(equalTo: bodyTextContainer.topAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: bodyTextContainer.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(lessThanOrEqualTo: bodyTextContainer.trailingAnchor),
            bodyLabel.bottomAnchor.constraint(equalTo: bodyTextContainer.bottomAnchor),
            bodyPrefersFillWidth
        ])

        contentStack.addArrangedSubview(headerStack)

        // Dynamic content wrapper clips content for truncation
        dynamicContentWrapper.clipsToBounds = true
        // Every bubble uses an outer scroll container; cap bubble content height.
        let maxHeight = dynamicContentWrapper.heightAnchor.constraint(lessThanOrEqualToConstant: 2000)
        maxHeight.priority = .required
        maxHeight.isActive = true
        dynamicContentHeightConstraint = maxHeight
        dynamicContentScrollView.translatesAutoresizingMaskIntoConstraints = false
        dynamicContentScrollView.contentInsetAdjustmentBehavior = .never
        dynamicContentScrollView.showsVerticalScrollIndicator = false
        dynamicContentScrollView.showsHorizontalScrollIndicator = false
        dynamicContentScrollView.alwaysBounceVertical = false
        dynamicContentScrollView.alwaysBounceHorizontal = false
        // Outer bubble scroll view is vertical-only. Horizontal scrolling belongs to inner views
        // (code blocks, tables, link previews) so the bubble itself never pans sideways.
        dynamicContentScrollView.isDirectionalLockEnabled = true
        dynamicContentScrollView.isScrollEnabled = false
        dynamicContentStack.axis = .vertical
        dynamicContentStack.spacing = 10
        dynamicContentStack.translatesAutoresizingMaskIntoConstraints = false
        dynamicContentStack.isLayoutMarginsRelativeArrangement = true
        dynamicContentStack.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        dynamicContentScrollView.addSubview(dynamicContentStack)
        dynamicContentWrapper.addSubview(dynamicContentScrollView)
        NSLayoutConstraint.activate([
            dynamicContentScrollView.topAnchor.constraint(equalTo: dynamicContentWrapper.topAnchor),
            dynamicContentScrollView.leadingAnchor.constraint(equalTo: dynamicContentWrapper.leadingAnchor),
            dynamicContentScrollView.trailingAnchor.constraint(equalTo: dynamicContentWrapper.trailingAnchor),
            dynamicContentScrollView.bottomAnchor.constraint(equalTo: dynamicContentWrapper.bottomAnchor),

            dynamicContentStack.topAnchor.constraint(equalTo: dynamicContentScrollView.contentLayoutGuide.topAnchor),
            dynamicContentStack.leadingAnchor.constraint(equalTo: dynamicContentScrollView.contentLayoutGuide.leadingAnchor),
            dynamicContentStack.trailingAnchor.constraint(equalTo: dynamicContentScrollView.contentLayoutGuide.trailingAnchor),
            dynamicContentStack.bottomAnchor.constraint(equalTo: dynamicContentScrollView.contentLayoutGuide.bottomAnchor),
            dynamicContentStack.widthAnchor.constraint(equalTo: dynamicContentScrollView.frameLayoutGuide.widthAnchor)
        ])
        // Prefer growing the wrapper to the content height (so the scroll view stays inert when
        // content fits), but allow the required max-height cap to win when content overflows.
        //
        // Important: this must be low priority. If it competes with intrinsic content heights at
        // `.defaultHigh`, Auto Layout may satisfy it by vertically compressing arranged subviews,
        // which produces clipped content with no outer scroll overflow detected.
        let wrapperHeightConstraint = dynamicContentWrapper.heightAnchor.constraint(
            equalTo: dynamicContentScrollView.contentLayoutGuide.heightAnchor
        )
        wrapperHeightConstraint.priority = .defaultLow
        wrapperHeightConstraint.isActive = true
        wrapperPrefersContentHeightConstraint = wrapperHeightConstraint
        contentStack.addArrangedSubview(dynamicContentWrapper)
        

        fadeView.translatesAutoresizingMaskIntoConstraints = false
        fadeView.isUserInteractionEnabled = false
        bubbleBackgroundView.addSubview(fadeView)
        fadeView.isHidden = true
        NSLayoutConstraint.activate([
            fadeView.leadingAnchor.constraint(equalTo: dynamicContentWrapper.leadingAnchor),
            fadeView.trailingAnchor.constraint(equalTo: dynamicContentWrapper.trailingAnchor),
            fadeView.bottomAnchor.constraint(equalTo: dynamicContentWrapper.bottomAnchor),
            fadeView.heightAnchor.constraint(equalToConstant: Self.bubbleScrollFadeHeight)
        ])

        contentLeadingConstraint = contentStack.leadingAnchor.constraint(equalTo: bubbleBackgroundView.leadingAnchor, constant: 16)
        contentTrailingConstraint = contentStack.trailingAnchor.constraint(equalTo: bubbleBackgroundView.trailingAnchor, constant: -16)
        contentTopConstraint = contentStack.topAnchor.constraint(equalTo: bubbleBackgroundView.topAnchor, constant: 14)
        contentBottomConstraint = contentStack.bottomAnchor.constraint(equalTo: bubbleBackgroundView.bottomAnchor, constant: -14)
        NSLayoutConstraint.activate([
            contentLeadingConstraint,
            contentTrailingConstraint,
            contentTopConstraint,
            contentBottomConstraint
        ])
    }

    private static func linkPreviewWidthCap(metrics: ChatFlowTheme.Metrics) -> CGFloat {
        max(120, bubbleReferenceSize.width - (metrics.containerPadding * 2))
    }

    private static func linkPreviewViewportMaxHeight(heightCap: CGFloat, metrics: ChatFlowTheme.Metrics) -> CGFloat {
        let standardVerticalPadding = max(0, metrics.bubblePaddingVertical * 2)
        return max(44, heightCap - standardVerticalPadding)
    }

    private static func presentationHasLinkPreview(_ presentation: MessagePresentation) -> Bool {
        presentation.parts.contains { part in
            if case .linkPreview = part { return true }
            return false
        }
    }

    private static func presentationIsSingleLinkPreview(_ presentation: MessagePresentation) -> Bool {
        presentation.hasSingleURL && presentationHasLinkPreview(presentation)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timestampRefreshTimer?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bubbleBackgroundView.layoutIfNeeded()
        contentStack.layoutIfNeeded()
        headerStack.layoutIfNeeded()

        // Hide timestamp if it would compress the sender name
        if !headerStack.isHidden, let timestampText = timestampLabel.attributedText, !timestampText.string.isEmpty {
            let avatarWidth = avatarView.bounds.width + headerStack.spacing
            let senderSize = senderLabel.intrinsicContentSize.width
            let spacerMin: CGFloat = 8
            let timestampSize = timestampLabel.intrinsicContentSize.width
            let availableWidth = headerStack.bounds.width
            let needed = avatarWidth + senderSize + spacerMin + timestampSize
            if needed > availableWidth {
                timestampLabel.isHidden = true
            } else {
                timestampLabel.isHidden = false
            }
        }
        gradientLayer.frame = bubbleBackgroundView.bounds
        maskLayer.frame = bubbleBackgroundView.bounds
        let path: UIBezierPath
        if hasTerminalSessionsForLayout {
            // Terminal bubbles render without message bubble chrome; don't clip their content to the
            // standard bubble shape (tail/rounded corners).
            path = UIBezierPath(rect: bubbleBackgroundView.bounds)
            bubbleBackgroundView.layer.cornerRadius = 0
            bubbleBackgroundView.layer.cornerCurve = .circular
        } else if useContinuousCorners {
            let radii = bubbleCornerRadii(messageId: messageIdForCorners())
            path = superellipseRoundedRectPath(
                rect: bubbleBackgroundView.bounds,
                topLeft: radii.topLeft,
                topRight: radii.topRight,
                bottomRight: radii.bottomRight,
                bottomLeft: radii.bottomLeft,
                exponent: 5.0
            )
            bubbleBackgroundView.layer.cornerRadius = 0
            bubbleBackgroundView.layer.cornerCurve = .continuous
        } else {
            path = bubblePath(in: bubbleBackgroundView.bounds)
            bubbleBackgroundView.layer.cornerRadius = 0
            bubbleBackgroundView.layer.cornerCurve = .circular
        }
        maskLayer.path = path.cgPath

        // Shadow container: use bubble path for accurate shadow shape
        shadowContainerView.layer.shadowPath = path.cgPath

        // Update border to match bubble shape
        borderGradientLayer.frame = bubbleBackgroundView.frame
        borderMaskLayer.frame = bubbleBackgroundView.bounds
        borderMaskLayer.path = path.cgPath

        // Top highlight - 1pt band at top, clipped to bubble shape
        let highlightHeight: CGFloat = 1.5
        topHighlightLayer.frame = CGRect(
            x: bubbleBackgroundView.frame.minX,
            y: bubbleBackgroundView.frame.minY,
            width: bubbleBackgroundView.bounds.width,
            height: highlightHeight
        )
        // Mask to bubble shape (offset to align with highlight frame)
        let highlightMaskPath = bubblePath(in: CGRect(
            x: 0,
            y: 0,
            width: bubbleBackgroundView.bounds.width,
            height: bubbleBackgroundView.bounds.height
        ))
        topHighlightMask.frame = CGRect(x: 0, y: 0, width: bubbleBackgroundView.bounds.width, height: highlightHeight)
        topHighlightMask.path = (hasTerminalSessionsForLayout || useContinuousCorners) ? path.cgPath : highlightMaskPath.cgPath

        updateTimestampVisibilityIfNeeded()
        updateOuterScrollState()
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   sizeClass: MessageSizeClass,
                   metrics: ChatFlowTheme.Metrics,
                   maxWidth: CGFloat,
                   bubbleHeightPolicy: BubbleSizingV2.BubbleHeightPolicy? = nil,
                   truncationHeightOverride: CGFloat? = nil,
                   bubbleSizingV2: BubbleSizingV2.LayoutState? = nil,
                   showsHeader: Bool = true,
                   paddingScale: CGFloat = 1,
                   minWidthOverride: CGFloat? = nil,
                   maxWidthOverride: CGFloat? = nil,
                   useContinuousCorners: Bool = true,
                   isDark: Bool? = nil,
                   terminalConnectionPool: TerminalSessionConnectionPool? = nil,
                   webBubbleCoordinator: (any WebBubbleCoordinating)? = nil,
                   onRequestExpand: (() -> Void)?,
                   onRequestLayout: ((String) -> Void)?,
                   onInteractiveCallback: ((String, String, JSONValue?) -> Void)?,
                   salientHighlightService: (any SalientHighlightServicing)? = nil) {
        assert(Thread.isMainThread)
        self.terminalConnectionPool = terminalConnectionPool
        let isMessageReuse = (currentMessageId != nil && currentMessageId != message.id)
        currentMessageId = message.id
        // Store for trait collection updates
        currentMessageRole = message.role
        currentStream = message.stream
        explicitIsDarkOverride = isDark
        currentSizeClass = sizeClass
        self.showsHeader = showsHeader
        contentPaddingScale = paddingScale
        self.useContinuousCorners = useContinuousCorners

        salientTask?.cancel()
        salientTask = nil
        salientToken &+= 1
        salientMessageId = message.id
        salientBaseAttributedText = nil
        currentSalientHighlights = nil

        let hasLinkPreview = Self.presentationHasLinkPreview(presentation)
        let isSingleLinkPreview = Self.presentationIsSingleLinkPreview(presentation)
        let rawMaxWidth = maxWidthOverride ?? maxWidth
        let effectiveMaxWidth = hasLinkPreview
            ? min(rawMaxWidth, Self.linkPreviewWidthCap(metrics: metrics))
            : rawMaxWidth
        let rawTruncationHeight = bubbleHeightPolicy?.v1TruncationHeightOverride
            ?? truncationHeightOverride
            ?? metrics.truncationHeight
        let effectiveTruncationHeight = (hasLinkPreview && !isSingleLinkPreview)
            ? min(rawTruncationHeight, metrics.truncationHeight)
            : rawTruncationHeight
        // Reset width constraints per size class.
        currentMetrics = metrics
        minWidthConstraint.constant = minWidthOverride ?? 120
        maxWidthConstraint.constant = effectiveMaxWidth
        fixedWidthConstraint?.isActive = false
        fixedWidthConstraint = nil
        self.onRequestExpand = onRequestExpand
        self.onRequestLayout = onRequestLayout
        self.onInteractiveCallback = onInteractiveCallback

        // Use explicit isDark if provided, otherwise fall back to trait collection
        let effectiveIsDark = isDark ?? (traitCollection.userInterfaceStyle == .dark)
        Self.logger.debug("configure: isDark=\(isDark.map { String($0) } ?? "nil", privacy: .public) effectiveIsDark=\(effectiveIsDark, privacy: .public) role=\(String(describing: message.role), privacy: .public)")
        let palette = ChatFlowUIKitTheme.palette(isDark: effectiveIsDark)
        let senderColor = (message.stream == .admin) ? palette.adminAccent : palette.warmBrown
        senderLabel.font = UIFont.clawline(.senderName)
        senderLabel.adjustsFontForContentSizeCategory = true
        senderLabel.textColor = senderColor.withAlphaComponent(message.stream == .admin ? 1.0 : 0.7)
        senderLabel.text = message.displayName
        timestampLabel.font = UIFont.clawline(.timestamp)
        timestampLabel.adjustsFontForContentSizeCategory = true
        timestampLabel.textColor = palette.textMuted.withAlphaComponent(Self.timestampTextAlpha(isDark: palette.isDark))
        timestampLabel.textAlignment = message.role == .user ? .right : .left
        timestampDate = message.timestamp
        refreshTimestampDisplay()
        headerStack.isHidden = !showsHeader
        bodyLabel.linkTextAttributes = [
            .foregroundColor: palette.ink,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        avatarView.configure(role: message.role, isDark: palette.isDark)

        // Remove old dynamic content views
        for view in dynamicContentViews {
            if let previewView = view as? LinkPreviewView {
                previewView.prepareForReuse()
            }
            if let terminalView = view as? TerminalBubbleUIKitView {
                terminalView.prepareForReuse()
            }
            if let htmlView = view as? InteractiveHTMLBubbleUIKitView {
                htmlView.prepareForReuse()
            }
            dynamicContentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        dynamicContentViews.removeAll()
        fileTapHandlers.removeAll()

        let markdownStyle = Self.markdownStyle(for: sizeClass, metrics: metrics)
        let markdownContent = UnifiedMarkdownRenderer.makeContent(
            presentation: presentation,
            baseFont: markdownStyle.baseFont,
            inkColor: palette.ink,
            lineSpacing: markdownStyle.lineSpacing,
            stripDetectedURLs: false,
            role: message.role,
            isDark: effectiveIsDark
        )

        // Check for chromeless emoji mode (1-3 emojis only, centered with double font)
        let isChromelessEmoji = presentation.chromelessStyle == .emoji

        // Reset text state before rebuilding content views.
        bodyLabel.attributedText = nil
        salientBaseAttributedText = nil

        if isChromelessEmoji, let value = markdownContent.joinedInlineEmojiValues {
            let baseEmojiFont = UIFont.clawline(.shortMessage)
            let emojiFont = UIFont(descriptor: baseEmojiFont.fontDescriptor, size: baseEmojiFont.pointSize * 2)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            bodyLabel.attributedText = NSAttributedString(
                string: value,
                attributes: [
                    .font: emojiFont,
                    .paragraphStyle: paragraph
                ]
            )
            dynamicContentStack.addArrangedSubview(bodyTextContainer)
            dynamicContentViews.append(bodyTextContainer)
            salientBaseAttributedText = bodyLabel.attributedText
        }

        // File attachments first so previews stay visible even with long text
        let fileParts = presentation.parts.compactMap { part -> Attachment? in
            if case .file(let attachment) = part { return attachment }
            return nil
        }
        if !fileParts.isEmpty {
            for attachment in fileParts {
                if let fileView = makeFilePreviewView(
                    attachment: attachment,
                    maxWidth: maxWidth - (metrics.bubblePaddingHorizontal * 2),
                    palette: palette,
                    metrics: metrics,
                    onTap: { [weak self] in
                        self?.onRequestExpand?()
                    }
                ) {
                    dynamicContentStack.addArrangedSubview(fileView)
                    dynamicContentViews.append(fileView)
                }
            }
        }

        if !isChromelessEmoji && markdownContent.hasRenderableMarkdownContent {
            addRenderedMarkdownBlocks(
                markdownContent.renderedBlocks,
                role: message.role,
                metrics: metrics,
                isDark: effectiveIsDark
            )
        }

        // Cache/render salient highlights only for the visible primary text block.
        applySalientHighlightsIfNeeded(
            message: message,
            isChromelessEmoji: isChromelessEmoji,
            isDark: effectiveIsDark,
            salientHighlightService: salientHighlightService
        )

        let linkPreviewURL = presentation.parts.compactMap({ part -> URL? in
            if case .linkPreview(let url) = part { return url }
            return nil
        }).first
        let shouldShowInlineReloadButton = isSingleLinkPreview && linkPreviewURL != nil
        allowSwipeUpExpandForSingleLink = isSingleLinkPreview

        // Flynn: URLs should render as tappable cards per the design-system, independent of embedded preview success.
        // For multi-URL messages, cards render for each unique URL; for single-URL messages, card renders above preview.
        var cardURLs = presentation.detectedURLs
        if let previewURL = presentation.parts.compactMap({ part -> URL? in
            if case .linkPreview(let url) = part { return url }
            return nil
        }).first {
            if !cardURLs.contains(where: { $0.absoluteString == previewURL.absoluteString }) {
                cardURLs.append(previewURL)
            }
        }
        suppressExpandTapForLinkCards = !cardURLs.isEmpty
        if !cardURLs.isEmpty {
            if shouldShowInlineReloadButton, let url = cardURLs.first {
                let row = UIStackView()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.axis = .horizontal
                row.alignment = .center
                row.distribution = .fill
                row.spacing = 10

                let card = LinkCardUIKitView()
                card.onHeightChange = { [weak self] in
                    self?.onRequestLayout?(message.id)
                }
                card.configure(url: url, palette: palette)
                card.setContentHuggingPriority(.defaultLow, for: .horizontal)

                let reload = UIButton(type: .system)
                reload.translatesAutoresizingMaskIntoConstraints = false
                reload.tintColor = palette.ink
                reload.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
                reload.backgroundColor = palette.isDark
                    ? UIColor.black.withAlphaComponent(0.20)
                    : UIColor.white.withAlphaComponent(0.75)
                reload.layer.cornerRadius = 16
                reload.layer.cornerCurve = .continuous
                reload.clipsToBounds = true
                reload.accessibilityLabel = "Reload preview"
                reload.accessibilityTraits = .button
                reload.setContentHuggingPriority(.required, for: .horizontal)
                reload.setContentCompressionResistancePriority(.required, for: .horizontal)
                NSLayoutConstraint.activate([
                    reload.widthAnchor.constraint(equalToConstant: 32),
                    reload.heightAnchor.constraint(equalToConstant: 32)
                ])

                row.addArrangedSubview(card)
                row.addArrangedSubview(reload)

                dynamicContentStack.addArrangedSubview(row)
                dynamicContentViews.append(row)

                if let linkPreviewURL {
                    let previewView = LinkPreviewView()
                    let previewChromeBase = Self.gradientBottomColor(for: message.role, palette: palette)
                    let rawPreviewMaxHeight: CGFloat = bubbleSizingV2?.linkPreviewMaxHeight
                        ?? bubbleHeightPolicy?.linkPreviewViewportMaxHeight
                        ?? Self.linkPreviewViewportMaxHeight(heightCap: effectiveTruncationHeight, metrics: metrics)
                    let previewMaxHeight = isSingleLinkPreview
                        ? rawPreviewMaxHeight
                        : min(rawPreviewMaxHeight, metrics.truncationHeight)
                    let directMediaInitialHeight: CGFloat? = {
                        guard isSingleLinkPreview, LinkPreviewView.isDirectMediaPreviewURL(linkPreviewURL) else { return nil }
                        let paddingHorizontal = round((presentation.hasMediaOnly ? 8 : metrics.bubblePaddingHorizontal) * paddingScale)
                        let contentWidth = max(1, maxWidth - (paddingHorizontal * 2))
                        return LinkPreviewView.preferredDirectMediaHeight(for: contentWidth, maxHeight: previewMaxHeight)
                    }()
                    if let bubbleSizingV2, let cacheKey = bubbleSizingV2.linkPreviewCacheKey {
                        previewView.configure(
                            url: linkPreviewURL,
                            maxHeight: previewMaxHeight,
                            minHeight: bubbleSizingV2.linkPreviewMinHeight,
                            cacheKey: cacheKey,
                            initialHeight: bubbleSizingV2.linkPreviewEstimatedHeight,
                            ownerItemId: message.id,
                            webBubbleCoordinator: webBubbleCoordinator
                        )
                    } else if let directMediaInitialHeight {
                        previewView.configure(
                            url: linkPreviewURL,
                            maxHeight: previewMaxHeight,
                            minHeight: directMediaInitialHeight,
                            initialHeight: directMediaInitialHeight,
                            ownerItemId: message.id,
                            webBubbleCoordinator: webBubbleCoordinator
                        )
                    } else if isSingleLinkPreview {
                        previewView.configure(
                            url: linkPreviewURL,
                            maxHeight: previewMaxHeight,
                            minHeight: previewMaxHeight,
                            initialHeight: previewMaxHeight,
                            ownerItemId: message.id,
                            webBubbleCoordinator: webBubbleCoordinator
                        )
                    } else {
                        previewView.configure(
                            url: linkPreviewURL,
                            maxHeight: previewMaxHeight,
                            ownerItemId: message.id,
                            webBubbleCoordinator: webBubbleCoordinator
                        )
                    }
                    previewView.setBubbleChrome(baseColor: previewChromeBase, isDark: palette.isDark)
                    previewView.onHeightChange = { [weak self] in
                        self?.onRequestLayout?(message.id)
                    }
                    reload.addAction(UIAction { [weak previewView] _ in
                        previewView?.reloadPreview()
                    }, for: .touchUpInside)
                    dynamicContentStack.addArrangedSubview(previewView)
                    dynamicContentViews.append(previewView)
                }
            } else {
                for url in cardURLs {
                    let card = LinkCardUIKitView()
                    card.onHeightChange = { [weak self] in
                        self?.onRequestLayout?(message.id)
                    }
                    card.configure(url: url, palette: palette)
                    dynamicContentStack.addArrangedSubview(card)
                    dynamicContentViews.append(card)
                }
            }
        }

        if let linkPreviewURL, !shouldShowInlineReloadButton {
            let previewView = LinkPreviewView()
            let previewChromeBase = Self.gradientBottomColor(for: message.role, palette: palette)
            let rawPreviewMaxHeight: CGFloat = bubbleSizingV2?.linkPreviewMaxHeight
                ?? bubbleHeightPolicy?.linkPreviewViewportMaxHeight
                ?? Self.linkPreviewViewportMaxHeight(heightCap: effectiveTruncationHeight, metrics: metrics)
            let previewMaxHeight = isSingleLinkPreview
                ? rawPreviewMaxHeight
                : min(rawPreviewMaxHeight, metrics.truncationHeight)
            let directMediaInitialHeight: CGFloat? = {
                guard isSingleLinkPreview, LinkPreviewView.isDirectMediaPreviewURL(linkPreviewURL) else { return nil }
                let paddingHorizontal = round((presentation.hasMediaOnly ? 8 : metrics.bubblePaddingHorizontal) * paddingScale)
                let contentWidth = max(1, maxWidth - (paddingHorizontal * 2))
                return LinkPreviewView.preferredDirectMediaHeight(for: contentWidth, maxHeight: previewMaxHeight)
            }()
            if let bubbleSizingV2, let cacheKey = bubbleSizingV2.linkPreviewCacheKey {
                previewView.configure(
                    url: linkPreviewURL,
                    maxHeight: previewMaxHeight,
                    minHeight: bubbleSizingV2.linkPreviewMinHeight,
                    cacheKey: cacheKey,
                    initialHeight: bubbleSizingV2.linkPreviewEstimatedHeight,
                    ownerItemId: message.id,
                    webBubbleCoordinator: webBubbleCoordinator
                )
            } else if let directMediaInitialHeight {
                previewView.configure(
                    url: linkPreviewURL,
                    maxHeight: previewMaxHeight,
                    minHeight: directMediaInitialHeight,
                    initialHeight: directMediaInitialHeight,
                    ownerItemId: message.id,
                    webBubbleCoordinator: webBubbleCoordinator
                )
            } else if isSingleLinkPreview {
                previewView.configure(
                    url: linkPreviewURL,
                    maxHeight: previewMaxHeight,
                    minHeight: previewMaxHeight,
                    initialHeight: previewMaxHeight,
                    ownerItemId: message.id,
                    webBubbleCoordinator: webBubbleCoordinator
                )
            } else {
                previewView.configure(
                    url: linkPreviewURL,
                    maxHeight: previewMaxHeight,
                    ownerItemId: message.id,
                    webBubbleCoordinator: webBubbleCoordinator
                )
            }
            previewView.setBubbleChrome(baseColor: previewChromeBase, isDark: palette.isDark)
            previewView.onHeightChange = { [weak self] in
                self?.onRequestLayout?(message.id)
            }
            dynamicContentStack.addArrangedSubview(previewView)
            dynamicContentViews.append(previewView)
        }

        let hasTerminalSessions = presentation.parts.contains(where: { if case .terminalSession = $0 { return true }; return false })
        hasTerminalSessionsForLayout = hasTerminalSessions
        setNeedsLayout()

        // Add embedded terminal session bubbles.
        let terminalSessions = presentation.parts.compactMap { part -> TerminalSessionDescriptor? in
            if case .terminalSession(let descriptor) = part { return descriptor }
            return nil
        }
        for (index, descriptor) in terminalSessions.enumerated() {
            let terminalBubble = TerminalBubbleUIKitView(connectionPool: terminalConnectionPool)
            terminalBubble.onRequestExpand = { [weak self] in self?.onRequestExpand?() }
            // Flynn: sizing matches HTML previews (wide content uses truncation cap, internal scroll).
            let heightCap = effectiveTruncationHeight
            terminalBubble.configure(
                descriptor: descriptor,
                style: .bubble(height: heightCap),
                context: .init(messageId: message.id, slotIndex: index, source: .bubble)
            )
            dynamicContentStack.addArrangedSubview(terminalBubble)
            dynamicContentViews.append(terminalBubble)
        }

        // Add embedded interactive HTML bubbles (T031).
        let interactiveDescriptors = presentation.parts.compactMap { part -> InteractiveHTMLDescriptor? in
            if case .interactiveHTML(let descriptor) = part { return descriptor }
            return nil
        }
        for descriptor in interactiveDescriptors {
            let htmlView = InteractiveHTMLBubbleUIKitView()
            htmlView.onHeightChange = { [weak self] in
                self?.onRequestLayout?(message.id)
            }
            htmlView.onCallback = { [weak self] action, data in
                self?.onInteractiveCallback?(message.id, action, data)
            }
            htmlView.configure(descriptor: descriptor, messageId: message.id, isDark: palette.isDark)
            dynamicContentStack.addArrangedSubview(htmlView)
            dynamicContentViews.append(htmlView)
        }

        // Flynn: terminal bubbles render without bubble chrome and without standard padding.
        let basePaddingHorizontal = (hasTerminalSessions || presentation.hasMediaOnly) ? 0 : metrics.bubblePaddingHorizontal
        let basePaddingVertical = (hasTerminalSessions || presentation.hasMediaOnly) ? 0 : metrics.bubblePaddingVertical
        currentContentPaddingHorizontal = round(basePaddingHorizontal * contentPaddingScale)
        currentContentPaddingVertical = round(basePaddingVertical * contentPaddingScale)
        contentLeadingConstraint.constant = currentContentPaddingHorizontal
        contentTrailingConstraint.constant = -currentContentPaddingHorizontal
        contentTopConstraint.constant = currentContentPaddingVertical
        contentBottomConstraint.constant = -currentContentPaddingVertical

        let isSingleImageOnly: Bool = {
            guard presentation.hasMediaOnly, presentation.parts.count == 1 else { return false }
            switch presentation.parts[0] {
            case .remoteImage, .image, .gallery:
                return true
            default:
                return false
            }
        }()

        // Add image/gallery views to dynamicContentStack (inline data only)
        let maxImageWidth = effectiveMaxWidth - (metrics.bubblePaddingHorizontal * 2)
        let maxImageHeight: CGFloat = {
            guard isSingleImageOnly else { return Self.mediaMaxHeight }
            if let bubbleSizingV2 {
                return max(120, bubbleSizingV2.measurement.outerScrollViewportHeight)
            } else {
                let headerHeight: CGFloat = showsHeader ? 32 : 0
                let headerSpacing: CGFloat = showsHeader ? contentStack.spacing : 0
                let padding = currentContentPaddingVertical * 2
                return max(120, effectiveTruncationHeight - (headerHeight + headerSpacing + padding))
            }
        }()
        var didRenderAttachments = !fileParts.isEmpty
        for part in presentation.parts {
            switch part {
            case .remoteImage(let url):
                let imageView = RemoteMessageImageView()
                imageView.configure(
                    url: url,
                    maxWidth: maxImageWidth,
                    maxHeight: maxImageHeight,
                    cornerRadius: Self.mediaCornerRadius,
                    onTap: { [weak self] image in
                        self?.presentImageViewer(image: image)
                    }
                ) { [weak self] in
                    self?.onRequestLayout?(message.id)
                }
                dynamicContentStack.addArrangedSubview(imageView)
                dynamicContentViews.append(imageView)
                didRenderAttachments = true
            case .image(let attachment):
                if let imageView = Self.makeImageView(
                    attachment: attachment,
                    maxWidth: maxImageWidth,
                    maxHeight: maxImageHeight,
                    cornerRadius: Self.mediaCornerRadius,
                    onTap: { [weak self] image in
                        self?.presentImageViewer(image: image)
                    }
                ) {
                    dynamicContentStack.addArrangedSubview(imageView)
                    dynamicContentViews.append(imageView)
                    didRenderAttachments = true
                }
            case .gallery(let attachments):
                for attachment in attachments {
                    if let imageView = Self.makeImageView(
                        attachment: attachment,
                        maxWidth: maxImageWidth,
                        maxHeight: maxImageHeight,
                        cornerRadius: Self.mediaCornerRadius,
                        onTap: { [weak self] image in
                            self?.presentImageViewer(image: image)
                        }
                    ) {
                        dynamicContentStack.addArrangedSubview(imageView)
                        dynamicContentViews.append(imageView)
                        didRenderAttachments = true
                    }
                }
            case .file:
                continue
            default:
                continue
            }
        }

        if didRenderAttachments {
            stripAttachmentSummaryIfNeeded()
        }

        // Flynn: terminal sessions render without sender header.
        if hasTerminalSessions {
            headerStack.isHidden = true
        }

        switch sizeClass {
        case .short:
            bodyMaxWidthConstraint?.isActive = false
            // Set fixed width to match measured preferredWidth for consistent sizing
            fixedWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(equalToConstant: effectiveMaxWidth)
            fixedWidthConstraint?.isActive = true
        case .medium:
            bodyMaxWidthConstraint?.isActive = false
            fixedWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(equalToConstant: effectiveMaxWidth)
            fixedWidthConstraint?.isActive = true
        case .long:
            let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
            bodyMaxWidthConstraint?.isActive = false
            let constraint = bodyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: maxLineWidth)
            constraint.isActive = true
            bodyMaxWidthConstraint = constraint
            fixedWidthConstraint = bubbleBackgroundView.widthAnchor.constraint(equalToConstant: effectiveMaxWidth)
            fixedWidthConstraint?.isActive = true
        }

        // Every bubble uses an outer scroll container. Bubble height is capped; if content overflows,
        // scrolling is enabled (inert when content fits).
        prepareOuterScrollStateForConfigure(isMessageReuse: isMessageReuse)

        if let bubbleSizingV2 {
            applyBubbleSizingV2(bubbleSizingV2)
        } else {
            dynamicContentHeightConstraint?.constant = max(44, effectiveTruncationHeight)
        }

        let gradientColors = message.role == .user ? palette.bubbleSelfGradient : palette.bubbleOtherGradient
        gradientLayer.colors = gradientColors.map { $0.cgColor }
        gradientLayer.startPoint = message.role == .user ? CGPoint(x: 0.0, y: 0.0) : CGPoint(x: 0.5, y: 0.0)
        gradientLayer.endPoint = message.role == .user ? CGPoint(x: 1.0, y: 1.0) : CGPoint(x: 0.5, y: 1.0)

        // Fade mask matches the bubble bottom color when the outer scroll view overflows.
        let bottomColor = gradientColors.last ?? Self.gradientBottomColor(for: message.role, palette: palette)
        fadeView.updateColors(
            top: bottomColor.withAlphaComponent(0),
            bottom: bottomColor
        )
#if os(visionOS)
        fadeView.setFadeStartLocation(0.95)
#else
        fadeView.setFadeStartLocation(nil)
#endif

        // Soft shadow
        shadowContainerView.layer.shadowColor = UIColor.black.cgColor
        shadowContainerView.layer.shadowRadius = MessageBubbleShadowStyle.radius
        shadowContainerView.layer.shadowOffset = MessageBubbleShadowStyle.offset
        let shadowOpacity = MessageBubbleShadowStyle.opacity(isDark: palette.isDark)
        shadowContainerView.layer.shadowOpacity = shadowOpacity

        // Chromeless mode: hide bubble chrome but keep padding
        isChromeless = hasTerminalSessions || isSingleImageOnly || presentation.isChromeless
        gradientLayer.isHidden = isChromeless
        borderGradientLayer.isHidden = isChromeless
        topHighlightLayer.isHidden = isChromeless
        shadowContainerView.isHidden = isChromeless
        shadowContainerView.layer.shadowOpacity = isChromeless ? 0 : shadowOpacity

        // Update border colors for light/dark mode
        updateBorderColors(isDark: palette.isDark)
        setNeedsLayout()
    }

    func prepareForReuse() {
        currentMessageId = nil
        suppressExpandTapForLinkCards = false
        allowSwipeUpExpandForSingleLink = false
        timestampDate = nil
        timestampRefreshTimer?.invalidate()
        timestampRefreshTimer = nil
        timestampLabel.isHidden = true
        timestampLabel.attributedText = nil
        resetOuterScrollState(resetOffset: true)
        wasOverflowingOnLastLayout = false
        salientTask?.cancel()
        salientTask = nil
        salientBaseAttributedText = nil
        salientMessageId = nil
        currentSalientHighlights = nil
    }

    private func applySalientHighlightsIfNeeded(
        message: Message,
        isChromelessEmoji: Bool,
        isDark: Bool,
        salientHighlightService: (any SalientHighlightServicing)?
    ) {
        guard message.role == .user else { return }
        guard !isChromelessEmoji else { return }
        guard let salientHighlightService else { return }
        guard let base = salientBaseAttributedText else { return }
        let renderedText = base.string
        guard !renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Apply memory-cached highlights immediately (no async churn on fast scroll).
        if let cached = salientHighlightService.cachedHighlights(messageId: message.id, renderedText: renderedText),
           !cached.spans.isEmpty {
            currentSalientHighlights = cached
            bodyLabel.attributedText = SalientHighlightApplier.apply(cached, to: base, isDark: isDark)
            return
        }

        let token = salientToken
        let messageId = message.id
        salientTask = Task { [weak self] in
            guard let self else { return }
            let highlights = await salientHighlightService.highlights(messageId: messageId, renderedText: renderedText)
            guard !Task.isCancelled else { return }
            guard let highlights, !highlights.spans.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.salientToken == token else { return }
                guard self.salientMessageId == messageId else { return }
                guard let base = self.salientBaseAttributedText else { return }
                self.currentSalientHighlights = highlights
                let highlighted = SalientHighlightApplier.apply(highlights, to: base, isDark: isDark)
                if self.bodyLabel.attributedText?.isEqual(to: highlighted) == true {
                    return
                }
                let width = self.bodyLabel.bounds.width
                let previousHeight: CGFloat? = width > 1
                    ? self.bodyLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
                    : nil
                self.bodyLabel.attributedText = highlighted
                if let previousHeight, width > 1 {
                    let newHeight = self.bodyLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
                    if abs(newHeight - previousHeight) > 0.5 {
                        self.onRequestLayout?(messageId)
                    }
                } else {
                    self.onRequestLayout?(messageId)
                }
            }
        }
    }

    private func applyBubbleSizingV2(_ state: BubbleSizingV2.LayoutState) {
        dynamicContentHeightConstraint?.constant = max(44, state.measurement.outerScrollViewportHeight)
    }

    private func updateOuterScrollState() {
        // Design-system: only large (.long) bubbles can scroll/truncate. Short/medium bubbles never
        // show outer scroll chrome (fade mask / "squircle bar"), even under Dynamic Type.
        //
        // Terminal bubbles have their own scroll/interaction model; never enable outer bubble scrolling.
        guard currentSizeClass == .long, !hasTerminalSessionsForLayout else {
            applyOuterScrollState(isOverflowing: false, forceResetOffset: true)
            return
        }

        dynamicContentScrollView.layoutIfNeeded()
        dynamicContentStack.layoutIfNeeded()
        let overflow = isOuterScrollOverflowing()
        applyOuterScrollState(isOverflowing: overflow, forceResetOffset: !overflow)
    }

    private func prepareOuterScrollStateForConfigure(isMessageReuse: Bool) {
        dynamicContentScrollView.isScrollEnabled = false
        dynamicContentScrollView.showsVerticalScrollIndicator = false
        dynamicContentScrollView.showsHorizontalScrollIndicator = false
        dynamicContentScrollView.alwaysBounceVertical = false
        dynamicContentScrollView.alwaysBounceHorizontal = false
        fadeView.isHidden = true

        // Cell reuse should always reset stale offsets. For same-message reconfigures
        // (link preview/highlight updates), defer to overflow transition logic to avoid
        // forcing the user back to top.
        if isMessageReuse {
            resetOuterScrollState(resetOffset: true)
        }
    }

    private func resetOuterScrollState(resetOffset: Bool) {
        dynamicContentScrollView.isScrollEnabled = false
        dynamicContentScrollView.showsVerticalScrollIndicator = false
        dynamicContentScrollView.alwaysBounceVertical = false
        dynamicContentScrollView.contentInset = .zero
        dynamicContentScrollView.scrollIndicatorInsets = .zero
        if resetOffset {
            dynamicContentScrollView.setContentOffset(.zero, animated: false)
        }
        fadeView.isHidden = true
    }

    private func applyOuterScrollState(isOverflowing: Bool, forceResetOffset: Bool) {
        let overflowChanged = (wasOverflowingOnLastLayout != isOverflowing)
        wasOverflowingOnLastLayout = isOverflowing

        dynamicContentScrollView.isScrollEnabled = isOverflowing
        dynamicContentScrollView.showsVerticalScrollIndicator = isOverflowing
        dynamicContentScrollView.alwaysBounceVertical = isOverflowing
        dynamicContentScrollView.contentInset.bottom = isOverflowing ? Self.bubbleScrollFadeHeight : 0
#if !os(visionOS)
        var indicatorInsets = dynamicContentScrollView.verticalScrollIndicatorInsets
        indicatorInsets.bottom = isOverflowing ? Self.bubbleScrollFadeHeight : 0
        dynamicContentScrollView.verticalScrollIndicatorInsets = indicatorInsets
#endif
        fadeView.isHidden = !isOverflowing

        guard !dynamicContentScrollView.isDragging,
              !dynamicContentScrollView.isTracking,
              !dynamicContentScrollView.isDecelerating else {
            return
        }

        if !isOverflowing && (forceResetOffset || overflowChanged || abs(dynamicContentScrollView.contentOffset.y) > 0.5) {
            dynamicContentScrollView.setContentOffset(.zero, animated: false)
            return
        }

        clampOuterScrollOffsetIfNeeded()
    }

    private func isOuterScrollOverflowing() -> Bool {
        let viewportHeight = dynamicContentScrollView.bounds.height
        guard viewportHeight > 1 else { return false }

        let contentHeight = max(
            dynamicContentScrollView.contentSize.height,
            dynamicContentScrollView.contentLayoutGuide.layoutFrame.height,
            dynamicContentStack.bounds.height
        )
        let scale = max(1, traitCollection.displayScale)
        let epsilon = max(1.5, 2.0 / scale)
        return contentHeight > (viewportHeight + epsilon)
    }

    private func clampOuterScrollOffsetIfNeeded() {
        // Use only explicit insets we own. adjustedContentInset can vary with screen-edge safe areas
        // as cells move, which makes inner bubble content appear to jump while scrolling (#70 / T050).
        let inset = dynamicContentScrollView.contentInset
        let minY = -inset.top
        let maxY = max(minY, dynamicContentScrollView.contentSize.height - dynamicContentScrollView.bounds.height + inset.bottom)
        let currentY = dynamicContentScrollView.contentOffset.y
        let clampedY = min(max(currentY, minY), maxY)
        guard abs(clampedY - currentY) > 0.5 else { return }
        dynamicContentScrollView.setContentOffset(CGPoint(x: dynamicContentScrollView.contentOffset.x, y: clampedY), animated: false)
    }

    func setCenteredOverlayView(_ view: UIView?) {
        if centeredOverlayView === view { return }
        centeredOverlayView?.removeFromSuperview()
        centeredOverlayView = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        bubbleBackgroundView.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: bubbleBackgroundView.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: bubbleBackgroundView.centerYAnchor)
        ])
    }

    private func updateAppearanceColors() {
        let isDark = explicitIsDarkOverride ?? (traitCollection.userInterfaceStyle == .dark)
        Self.logger.debug("updateAppearanceColors: isDark=\(isDark, privacy: .public) role=\(String(describing: self.currentMessageRole), privacy: .public)")
        let palette = ChatFlowUIKitTheme.palette(isDark: isDark)

        // Update sender label color
        let senderColor = (currentStream == .admin) ? palette.adminAccent : palette.warmBrown
        senderLabel.textColor = senderColor.withAlphaComponent(currentStream == .admin ? 1.0 : 0.7)
        timestampLabel.textColor = palette.textMuted.withAlphaComponent(Self.timestampTextAlpha(isDark: palette.isDark))

        // Update body text color - must update attributed string since textColor is ignored for attributed text
        if let attributedText = bodyLabel.attributedText, attributedText.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: attributedText)
            mutable.addAttribute(.foregroundColor, value: palette.ink, range: NSRange(location: 0, length: mutable.length))
            if let highlights = currentSalientHighlights {
                SalientHighlightApplier.apply(highlights, to: mutable, isDark: isDark)
            }
            bodyLabel.attributedText = mutable
        }

        // Update avatar
        avatarView.configure(role: currentMessageRole, isDark: palette.isDark)

        // Update gradient colors - force immediate update without animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let gradientColors = currentMessageRole == .user ? palette.bubbleSelfGradient : palette.bubbleOtherGradient
        gradientLayer.colors = gradientColors.map { $0.cgColor }
        CATransaction.commit()

        // Update shadow (on separate shadow container view)
        shadowContainerView.layer.shadowColor = UIColor.black.cgColor
        shadowContainerView.layer.shadowRadius = MessageBubbleShadowStyle.radius
        shadowContainerView.layer.shadowOffset = MessageBubbleShadowStyle.offset
        let shadowOpacity = MessageBubbleShadowStyle.opacity(isDark: palette.isDark)
        shadowContainerView.layer.shadowOpacity = isChromeless ? 0 : shadowOpacity
        shadowContainerView.isHidden = isChromeless

        // Update border colors for light/dark mode
        updateBorderColors(isDark: palette.isDark)

        // Update fade view - use bubble gradient end colors
        // Top color must match bottom color (just transparent) to avoid haze
        let bottomColor = Self.gradientBottomColor(for: currentMessageRole, palette: palette)
        fadeView.updateColors(
            top: bottomColor.withAlphaComponent(0),
            bottom: bottomColor
        )

        // Force layer redraw to ensure gradient is visible
        gradientLayer.setNeedsDisplay()
        for view in dynamicContentViews {
            if let codeView = view as? CodeBlockUIKitView {
                codeView.setAppearanceOverride(isDark: isDark)
            }
        }
        setNeedsLayout()
    }

    private func updateBorderColors(isDark: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isDark {
            // Dark mode: white highlight at top fading down
            borderGradientLayer.colors = [
                UIColor.white.withAlphaComponent(0.14).cgColor,
                UIColor.white.withAlphaComponent(0.05).cgColor,
                UIColor.clear.cgColor,
                UIColor.clear.cgColor
            ]
            topHighlightLayer.colors = [
                UIColor.white.withAlphaComponent(0.12).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor
            ]
        } else {
            // Light mode: use neutral highlight to avoid dark shoulder on rounded corners.
            borderGradientLayer.colors = [
                UIColor.white.withAlphaComponent(0.16).cgColor,
                UIColor.white.withAlphaComponent(0.06).cgColor,
                UIColor.white.withAlphaComponent(0.03).cgColor,
                UIColor.clear.cgColor
            ]
            topHighlightLayer.colors = [
                UIColor.white.withAlphaComponent(0.28).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor
            ]
        }
        CATransaction.commit()
        borderGradientLayer.setNeedsDisplay()
        topHighlightLayer.setNeedsDisplay()
    }

    func preferredWidth(maxWidth: CGFloat) -> CGFloat {
        let headerWidth: CGFloat = showsHeader
            ? (32 + headerStack.spacing + senderLabel.intrinsicContentSize.width)
            : 0
        let contentWidth = maxWidth - (currentContentPaddingHorizontal * 2)
        let bodySize = bodyLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let contentMax = max(headerWidth, bodySize.width)
        return min(maxWidth, max(120, contentMax + (currentContentPaddingHorizontal * 2)))
    }

    // Used by the V2 measurer to compute content vs chrome height without duplicating view-specific logic.
    func measuredDynamicContentHeight(fittingWidth width: CGFloat) -> CGFloat {
        layoutIfNeeded()
        let target = CGSize(width: max(1, width), height: UIView.layoutFittingCompressedSize.height)
        let measured = dynamicContentStack.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return max(0, measured.height)
    }

    @objc private func handleBubbleTap() {
        if suppressExpandTapForLinkCards {
            return
        }
        // If the bubble overflows the max height cap, allow tap-to-expand (signals "truncated").
        if dynamicContentScrollView.contentSize.height > dynamicContentScrollView.bounds.height + 1 {
            onRequestExpand?()
        }
    }

    @objc private func handleBubbleSwipeUp() {
        guard allowSwipeUpExpandForSingleLink else {
            return
        }
        onRequestExpand?()
    }

    private func stripAttachmentSummaryIfNeeded() {
        guard let text = bodyLabel.attributedText?.string else { return }
        let lines = text.components(separatedBy: .newlines)
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonSummary = trimmed.filter { line in
            guard !line.isEmpty else { return false }
            let lower = line.lowercased()
            return !(lower.hasPrefix("attachments:") || lower.hasPrefix("attachment:"))
        }
        guard nonSummary.isEmpty else { return }
        removeBodyLabelFromStack()
    }

    private func removeBodyLabelFromStack() {
        guard dynamicContentStack.arrangedSubviews.contains(bodyLabel) else { return }
        dynamicContentStack.removeArrangedSubview(bodyLabel)
        bodyLabel.removeFromSuperview()
        dynamicContentViews.removeAll { $0 == bodyLabel }
    }

    @objc private func handleFileAttachmentTap(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view else { return }
        fileTapHandlers[ObjectIdentifier(view)]?()
    }

    @available(iOS 17.0, macCatalyst 17.0, visionOS 1.0, *)
    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        UnifiedMarkdownRenderer.primaryActionForTextItem(textItem, defaultAction: defaultAction) { tappedURL in
            UIApplication.shared.open(tappedURL)
        }
    }

    private static func markdownStyle(
        for sizeClass: MessageSizeClass,
        metrics: ChatFlowTheme.Metrics
    ) -> (baseFont: UIFont, lineSpacing: CGFloat) {
        _ = metrics
        switch sizeClass {
        case .short:
            return (UIFont.clawline(.shortMessage), 0)
        case .medium:
            return (UIFont.clawline(.mediumMessage), 4)
        case .long:
            return (UIFont.clawline(.bodyText), 4)
        }
    }

    private func refreshTimestampDisplay(now: Date = Date()) {
        guard let timestamp = timestampDate else {
            timestampLabel.attributedText = nil
            timestampRefreshTimer?.invalidate()
            timestampRefreshTimer = nil
            return
        }
        let formatted = Self.formattedBubbleTimestamp(timestamp, now: now)
        timestampLabel.attributedText = NSAttributedString(
            string: formatted,
            attributes: [.kern: 0.2]
        )
        updateTimestampVisibilityIfNeeded()
        scheduleTimestampRefreshIfNeeded(now: now)
    }

    private func updateTimestampVisibilityIfNeeded() {
        guard let timestampText = timestampLabel.attributedText, !timestampText.string.isEmpty else {
            timestampLabel.isHidden = true
            return
        }
        if !headerStack.isHidden, headerStack.bounds.width > 0 {
            if metadataNeededWidth() > headerStack.bounds.width {
                timestampLabel.isHidden = true
                return
            }
        }
        timestampLabel.isHidden = false
    }

    func debugMetadataStateForTests() -> MessageBubbleMetadataDebugState {
        MessageBubbleMetadataDebugState(
            senderText: senderLabel.text,
            senderLineBreakMode: senderLabel.lineBreakMode,
            senderCompressionResistance: senderLabel.contentCompressionResistancePriority(for: .horizontal),
            timestampCompressionResistance: timestampLabel.contentCompressionResistancePriority(for: .horizontal),
            timestampHidden: timestampLabel.isHidden,
            timestampAlpha: timestampLabel.textColor.cgColor.alpha,
            headerWidth: headerStack.bounds.width,
            metadataNeededWidth: metadataNeededWidth()
        )
    }

    private func metadataNeededWidth() -> CGFloat {
        avatarView.bounds.width
            + headerStack.spacing
            + senderLabel.intrinsicContentSize.width
            + 8
            + timestampLabel.intrinsicContentSize.width
    }

    private func scheduleTimestampRefreshIfNeeded(now: Date) {
        timestampRefreshTimer?.invalidate()
        timestampRefreshTimer = nil
        guard let timestamp = timestampDate else { return }

        let elapsed = max(0, now.timeIntervalSince(timestamp))
        let calendar = Calendar.autoupdatingCurrent
        let nextInterval: TimeInterval?
        if elapsed < 3_600 || calendar.isDate(timestamp, inSameDayAs: now) {
            let nextMinute = calendar.nextDate(
                after: now,
                matching: DateComponents(second: 0),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(60)
            nextInterval = max(1, nextMinute.timeIntervalSince(now))
        } else {
            let sameYear = calendar.component(.year, from: timestamp) == calendar.component(.year, from: now)
            if !sameYear {
                nextInterval = nil
            } else if calendar.isDateInYesterday(timestamp) || calendar.isDate(timestamp, equalTo: now, toGranularity: .weekOfYear) {
                let startOfTomorrow = calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: calendar.startOfDay(for: now)
                ) ?? now.addingTimeInterval(86_400)
                nextInterval = max(60, startOfTomorrow.timeIntervalSince(now))
            } else {
                let currentYear = calendar.component(.year, from: now)
                let startOfNextYear = calendar.date(
                    from: DateComponents(year: currentYear + 1, month: 1, day: 1)
                ) ?? now.addingTimeInterval(31_536_000)
                nextInterval = max(60, startOfNextYear.timeIntervalSince(now))
            }
        }

        guard let nextInterval else { return }

        timestampRefreshTimer = Timer.scheduledTimer(withTimeInterval: nextInterval, repeats: false) { [weak self] _ in
            self?.refreshTimestampDisplay()
        }
    }

    private static func formattedBubbleTimestamp(_ timestamp: Date, now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(timestamp))
        if interval < 60 {
            return "just now"
        }
        if interval < 3_600 {
            return "\(Int(interval / 60))m ago"
        }
        if interval < 86_400 {
            let calendar = Calendar.autoupdatingCurrent
            if calendar.isDate(timestamp, inSameDayAs: now) {
                return timeFormatter.string(from: timestamp)
            }
        }
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInYesterday(timestamp) {
            return "\(relativeDayFormatter.string(from: timestamp)), \(timeFormatter.string(from: timestamp))"
        }
        if calendar.component(.year, from: timestamp) != calendar.component(.year, from: now) {
            return differentYearFormatter.string(from: timestamp)
        }
        if calendar.isDate(timestamp, equalTo: now, toGranularity: .weekOfYear) {
            return "\(weekdayFormatter.string(from: timestamp)), \(timeFormatter.string(from: timestamp))"
        }
        return "\(monthDayFormatter.string(from: timestamp)), \(timeFormatter.string(from: timestamp))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let differentYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM d, y")
        return formatter
    }()

    private static let relativeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeStyle = .none
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private func addRenderedMarkdownBlocks(
        _ blocks: [RenderedMarkdownBlock],
        role: Message.Role,
        metrics: ChatFlowTheme.Metrics,
        isDark: Bool
    ) {
        var usedPrimaryTextContainer = false

        for block in blocks {
            switch block {
            case .attributedText(let attributed):
                let trimmed = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if !usedPrimaryTextContainer {
                    bodyLabel.attributedText = attributed
                    salientBaseAttributedText = attributed
                    dynamicContentStack.addArrangedSubview(bodyTextContainer)
                    dynamicContentViews.append(bodyTextContainer)
                    usedPrimaryTextContainer = true
                } else {
                    let supplemental = makeSupplementalTextContainer(attributed: attributed)
                    dynamicContentStack.addArrangedSubview(supplemental)
                    dynamicContentViews.append(supplemental)
                }
            case .code(let language, let code):
                let codeView = CodeBlockUIKitView()
                codeView.configure(language: language, code: code, isDark: isDark)
                dynamicContentStack.addArrangedSubview(codeView)
                dynamicContentViews.append(codeView)
            case .table(let model):
                let tableView = TableUIKitWrapperView()
                tableView.configure(
                    model: model,
                    role: role,
                    metrics: metrics,
                    maxLineWidth: ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize),
                    isDark: isDark,
                    onExpand: { [weak self] in self?.onRequestExpand?() }
                )
                dynamicContentStack.addArrangedSubview(tableView)
                dynamicContentViews.append(tableView)
            }
        }
    }

    private func makeSupplementalTextContainer(attributed: NSAttributedString) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .clear

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        UnifiedMarkdownRenderer.configureTextView(
            textView,
            delegate: self,
            linkTextAttributes: bodyLabel.linkTextAttributes ?? [:],
            enableDataDetectors: false
        )
        textView.attributedText = attributed

        container.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private static func textContent(from presentation: MessagePresentation) -> String {
        let parts = presentation.parts.filter { $0.isTextual }
        return parts.map { part in
            switch part {
            case .text(let value):
                return value
            case .markdown(let value):
                return value
            case .inlineEmoji(let value):
                return value
            case .code(_, let value):
                return value
            case .table(let model):
                return "Table (\(model.rows.count) rows)"
            case .linkPreview:
                return ""
            case .remoteImage, .image, .gallery, .file, .terminalSession, .interactiveHTML:
                return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func makeImageView(attachment: Attachment,
                                      maxWidth: CGFloat,
                                      maxHeight: CGFloat,
                                      cornerRadius: CGFloat,
                                      onTap: @escaping (UIImage) -> Void) -> UIImageView? {
        guard let data = attachment.data,
              let image = UIImage(data: data) else {
            return nil
        }

        let imageView = MessageImageThumbnailView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = cornerRadius
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.onImageTap = onTap
        imageView.accessibilityLabel = "Image attachment"

        let aspectRatio = image.size.height / max(image.size.width, 1)
        let height = min(maxHeight, maxWidth * aspectRatio)
        imageView.heightAnchor.constraint(equalToConstant: height).isActive = true
        imageView.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        return imageView
    }

    private func presentImageViewer(image: UIImage) {
        guard let presenter = nearestViewController() else { return }
        presenter.present(ImagePopupViewerController(image: image), animated: true)
    }

    private func makeFilePreviewView(attachment: Attachment,
                                     maxWidth: CGFloat,
                                     palette: ChatFlowUIKitTheme.Palette,
                                     metrics: ChatFlowTheme.Metrics,
                                     onTap: (() -> Void)? = nil) -> UIView? {
        let name = attachment.filename ?? attachment.assetId ?? attachment.mimeType ?? "Attachment"
        let sizeValue = attachment.size ?? attachment.data?.count

        let iconName = Self.fileIconName(filename: attachment.filename, mimeType: attachment.mimeType)
        let icon = UIImageView(image: UIImage(systemName: iconName))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = palette.ink.withAlphaComponent(0.7)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 26)
        ])

        let nameLabel = UILabel()
        _ = metrics
        nameLabel.font = UIFont.clawline(.uiLabel, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = palette.ink
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.text = name

        let sizeLabel = UILabel()
        sizeLabel.font = UIFont.clawline(.secondaryLabel)
        sizeLabel.adjustsFontForContentSizeCategory = true
        sizeLabel.textColor = palette.ink.withAlphaComponent(0.7)
        sizeLabel.numberOfLines = 1
        sizeLabel.text = sizeValue.map(Self.formatFileSize)
        sizeLabel.isHidden = sizeLabel.text?.isEmpty ?? true

        let textStack = UIStackView(arrangedSubviews: [nameLabel, sizeLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let container = UIStackView(arrangedSubviews: [icon, textStack])
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = palette.borderSubtle
        container.layer.cornerRadius = 12
        container.axis = .horizontal
        container.spacing = 10
        container.alignment = .center
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        if let onTap {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleFileAttachmentTap))
            container.addGestureRecognizer(tap)
            container.isUserInteractionEnabled = true
            fileTapHandlers[ObjectIdentifier(container)] = onTap
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth)
        ])

        container.accessibilityLabel = sizeLabel.text.map { "\(name), \($0)" } ?? name
        return container
    }

    nonisolated private static func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func fileIconName(filename: String?, mimeType: String?) -> String {
        if let filename, !filename.isEmpty {
            let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return fileIconName(for: type)
            }
        }

        if let mimeType, let type = UTType(mimeType: mimeType) {
            return fileIconName(for: type)
        }

        return "doc.fill"
    }

    private static func fileIconName(for type: UTType) -> String {
        if type.conforms(to: .pdf) { return "doc.richtext.fill" }
        if type.conforms(to: .image) { return "photo.fill" }
        if type.conforms(to: .movie) { return "film.fill" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) || type.conforms(to: .zip) { return "archivebox.fill" }
        if type.conforms(to: .spreadsheet) { return "tablecells.fill" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .sourceCode) { return "chevron.left.slash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text.fill" }
        return "doc.fill"
    }

    // MARK: - UIKit-Native Text Measurement

    /// Measure the natural single-line width of text content (no wrapping).
    /// Used for line balancing to determine minimum width needed.
    static func measureSingleLineWidth(
        for presentation: MessagePresentation,
        metrics: ChatFlowTheme.Metrics
    ) -> CGFloat {
        let text = textContent(from: presentation)
        guard !text.isEmpty else { return 0 }

        // Use short size class font for single-line measurement (natural width)
        _ = metrics
        let font = UIFont.clawline(.shortMessage)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
        return ceil(size.width)
    }

    /// Measure the height of text content at a given width.
    /// Used to estimate line count for layout decisions.
    static func measureTextHeight(
        for presentation: MessagePresentation,
        sizeClass: MessageSizeClass,
        metrics: ChatFlowTheme.Metrics,
        maxWidth: CGFloat
    ) -> CGFloat? {
        guard presentation.hasTextualContent else { return nil }
        let text = textContent(from: presentation)
        guard !text.isEmpty else { return nil }

        let font: UIFont
        let lineSpacing: CGFloat
        switch sizeClass {
        case .short:
            font = UIFont.clawline(.shortMessage)
            lineSpacing = 0
        case .medium:
            font = UIFont.clawline(.mediumMessage)
            lineSpacing = 4
        case .long:
            font = UIFont.clawline(.bodyText)
            lineSpacing = 4
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]

        let size = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return ceil(size.height)
    }

    /// Estimate line count for text at a given bubble width.
    /// contentWidth = bubbleWidth - horizontal padding
    static func estimatedLineCount(
        for presentation: MessagePresentation,
        metrics: ChatFlowTheme.Metrics,
        atBubbleWidth bubbleWidth: CGFloat
    ) -> Int {
        let contentWidth = bubbleWidth - (metrics.bubblePaddingHorizontal * 2)
        guard let textHeight = measureTextHeight(
            for: presentation,
            sizeClass: .medium,
            metrics: metrics,
            maxWidth: contentWidth
        ) else {
            return 1
        }

        let lineSpacing: CGFloat = 4
        _ = metrics
        let font = UIFont.clawline(.mediumMessage)
        let lineHeight = font.lineHeight
        return Int(ceil((textHeight + lineSpacing) / (lineHeight + lineSpacing)))
    }

    private func bubblePath(in rect: CGRect) -> UIBezierPath {
        let radii = bubbleCornerRadii(messageId: messageIdForCorners())
        return roundedRectPath(
            rect: rect,
            topLeft: radii.topLeft,
            topRight: radii.topRight,
            bottomRight: radii.bottomRight,
            bottomLeft: radii.bottomLeft
        )
    }

    private func messageIdForCorners() -> String {
        "\(bodyLabel.text ?? "")_\(senderLabel.text ?? "")"
    }

    private func bubbleCornerRadii(messageId: String) -> (topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) {
        let sharp: CGFloat = 5
        let variationsSelf: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (45, 43, sharp, 43),
            (43, 45, sharp, 45),
            (45, 45, sharp, 43)
        ]
        let variationsOther: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (45, 43, 43, sharp),
            (43, 45, 45, sharp),
            (45, 45, 43, sharp)
        ]
        let index = abs(messageId.hashValue) % variationsSelf.count
        if senderLabel.text == "You" {
            let v = variationsSelf[index]
            return (v.0, v.1, v.2, v.3)
        }
        let v = variationsOther[index]
        return (v.0, v.1, v.2, v.3)
    }

    private func roundedRectPath(rect: CGRect,
                                 topLeft: CGFloat,
                                 topRight: CGFloat,
                                 bottomRight: CGFloat,
                                 bottomLeft: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let tl = min(topLeft, min(rect.width, rect.height) / 2)
        let tr = min(topRight, min(rect.width, rect.height) / 2)
        let br = min(bottomRight, min(rect.width, rect.height) / 2)
        let bl = min(bottomLeft, min(rect.width, rect.height) / 2)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(withCenter: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(withCenter: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.close()
        return path
    }

    private func superellipseRoundedRectPath(rect: CGRect,
                                             topLeft: CGFloat,
                                             topRight: CGFloat,
                                             bottomRight: CGFloat,
                                             bottomLeft: CGFloat,
                                             exponent: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let tl = min(topLeft, min(rect.width, rect.height) / 2)
        let tr = min(topRight, min(rect.width, rect.height) / 2)
        let br = min(bottomRight, min(rect.width, rect.height) / 2)
        let bl = min(bottomLeft, min(rect.width, rect.height) / 2)

        let steps = 12
        let quarterPoints = superellipseQuarterPoints(radius: 1, exponent: exponent, steps: steps)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        appendCorner(path: path,
                     center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                     radius: tr,
                     points: quarterPoints,
                     transform: { CGPoint(x: $0.y, y: -$0.x) })
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        appendCorner(path: path,
                     center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                     radius: br,
                     points: quarterPoints,
                     transform: { CGPoint(x: $0.x, y: $0.y) })
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        appendCorner(path: path,
                     center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                     radius: bl,
                     points: quarterPoints,
                     transform: { CGPoint(x: -$0.y, y: $0.x) })
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        appendCorner(path: path,
                     center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                     radius: tl,
                     points: quarterPoints,
                     transform: { CGPoint(x: -$0.x, y: -$0.y) })
        path.close()
        return path
    }

    private func superellipseQuarterPoints(radius: CGFloat,
                                           exponent: CGFloat,
                                           steps: Int) -> [CGPoint] {
        guard steps > 1 else { return [CGPoint(x: radius, y: 0), CGPoint(x: 0, y: radius)] }
        let n = max(2, exponent)
        let power = 2.0 / n
        let step = (.pi / 2) / CGFloat(steps - 1)
        return (0..<steps).map { idx in
            let theta = CGFloat(idx) * step
            let cosv = max(0, cos(theta))
            let sinv = max(0, sin(theta))
            let x = radius * pow(cosv, power)
            let y = radius * pow(sinv, power)
            return CGPoint(x: x, y: y)
        }
    }

    private func appendCorner(path: UIBezierPath,
                              center: CGPoint,
                              radius: CGFloat,
                              points: [CGPoint],
                              transform: (CGPoint) -> CGPoint) {
        guard radius > 0 else { return }
        for point in points {
            let p = transform(CGPoint(x: point.x * radius, y: point.y * radius))
            path.addLine(to: CGPoint(x: center.x + p.x, y: center.y + p.y))
        }
    }
}

final class AvatarCircleView: UIView {
    private let label = UILabel()
    private let gradientLayer = CAGradientLayer()
    private var sizeConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // Avatar is sacred: fixed size and aspect ratio. Do not allow truncation/layout caps to
        // distort it (GitHub #60 regression).
        let width = widthAnchor.constraint(equalToConstant: 32)
        let height = heightAnchor.constraint(equalToConstant: 32)
        let aspect = widthAnchor.constraint(equalTo: heightAnchor)
        sizeConstraints = [width, height, aspect]
        sizeConstraints.forEach { $0.priority = .required }
        NSLayoutConstraint.activate(sizeConstraints)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        // Radial gradient for spherical/marble look
        layer.insertSublayer(gradientLayer, at: 0)
        gradientLayer.type = .radial
        // Tighter highlight - center upper-left for "lit from above-left" look
        gradientLayer.startPoint = CGPoint(x: 0.35, y: 0.25)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        label.font = UIFont.clawline(.uiLabel, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.layer.shadowOpacity = 0.3
        label.layer.shadowRadius = 1

        layer.cornerRadius = 16
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func configure(role: Message.Role, isDark: Bool) {
        label.text = role == .user ? "Y" : "A"

        // Role-specific gradient - subtle spherical highlight
        if role == .user {
            // Sage green - subtle gradient from design system
            gradientLayer.colors = [
                UIColor(red: 0.48, green: 0.68, blue: 0.48, alpha: 1).cgColor,  // Subtle highlight
                UIColor(red: 0.42, green: 0.61, blue: 0.42, alpha: 1).cgColor,  // #6B9B6A
                UIColor(red: 0.32, green: 0.52, blue: 0.34, alpha: 1).cgColor,  // mid
                UIColor(red: 0.24, green: 0.42, blue: 0.26, alpha: 1).cgColor   // edge
            ]
            gradientLayer.locations = [0.0, 0.3, 0.65, 1.0]
        } else {
            // Terracotta - subtle gradient
            gradientLayer.colors = [
                UIColor(red: 0.94, green: 0.70, blue: 0.65, alpha: 1).cgColor,  // Subtle highlight
                UIColor(red: 0.91, green: 0.66, blue: 0.61, alpha: 1).cgColor,  // soft-coral
                UIColor(red: 0.80, green: 0.52, blue: 0.42, alpha: 1).cgColor,  // mid
                UIColor(red: 0.70, green: 0.42, blue: 0.32, alpha: 1).cgColor   // edge
            ]
            gradientLayer.locations = [0.0, 0.3, 0.65, 1.0]
        }
    }
}

final class MessageFailureBadgeView: UIView {
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isAccessibilityElement = false

        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        button.tintColor = ChatFlowUIKitTheme.failureText(isDark: traitCollection.userInterfaceStyle == .dark)
        button.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Message failed to send. Tap for options."
        button.accessibilityTraits = [.button]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(onResend: @escaping () -> Void) {
        let isDark = traitCollection.userInterfaceStyle == .dark
        button.tintColor = ChatFlowUIKitTheme.failureText(isDark: isDark)
        button.menu = UIMenu(
            options: .displayInline,
            children: [
                UIAction(title: "Resend", image: UIImage(systemName: "arrow.clockwise")) { _ in
                    onResend()
                }
            ]
        )
    }
}

enum ChatFlowUIKitTheme {
    struct Palette {
        let isDark: Bool
        let sage: UIColor
        let cream: UIColor
        let warmBrown: UIColor
        let adminAccent: UIColor
        let ink: UIColor
        let bubbleSelfGradient: [UIColor]
        let bubbleOtherGradient: [UIColor]
        let avatarGradient: [UIColor]
        let terracotta: UIColor
        let borderSubtle: UIColor
        let fadeTop: UIColor
        let failureText: UIColor
        let failureBackground: UIColor
        let shadowNear: UIColor
        let textMuted: UIColor
    }

    static func palette(isDark: Bool) -> Palette {
        if isDark {
            return Palette(
                isDark: true,
                sage: UIColor(red: 0.482, green: 0.639, blue: 0.463, alpha: 1),
                cream: UIColor(red: 0.110, green: 0.098, blue: 0.090, alpha: 1),
                warmBrown: UIColor(red: 0.831, green: 0.769, blue: 0.690, alpha: 1),
                adminAccent: UIColor(red: 0.549, green: 0.756, blue: 0.996, alpha: 1),
                ink: UIColor(red: 0.910, green: 0.894, blue: 0.878, alpha: 1),
                bubbleSelfGradient: [
                    UIColor(red: 0.161, green: 0.214, blue: 0.149, alpha: 1),
                    UIColor(red: 0.125, green: 0.182, blue: 0.117, alpha: 1)
                ],
                bubbleOtherGradient: [
                    UIColor(red: 0.161, green: 0.145, blue: 0.141, alpha: 1),
                    UIColor(red: 0.161, green: 0.145, blue: 0.141, alpha: 1)
                ],
                avatarGradient: [
                    UIColor(red: 0.55, green: 0.34, blue: 0.30, alpha: 1),
                    UIColor(red: 0.64, green: 0.40, blue: 0.36, alpha: 1)
                ],
                terracotta: UIColor(red: 0.878, green: 0.478, blue: 0.373, alpha: 1),
                borderSubtle: UIColor(red: 0.910, green: 0.894, blue: 0.878, alpha: 0.12),
                fadeTop: UIColor(red: 0, green: 0, blue: 0, alpha: 0),
                failureText: UIColor(red: 0.95, green: 0.62, blue: 0.62, alpha: 1),
                failureBackground: UIColor(red: 0.30, green: 0.14, blue: 0.14, alpha: 1),
                shadowNear: UIColor.black.withAlphaComponent(0.35),
                textMuted: UIColor(red: 0.545, green: 0.502, blue: 0.471, alpha: 1)
            )
        }
        return Palette(
            isDark: false,
            sage: UIColor(red: 0.561, green: 0.651, blue: 0.541, alpha: 1),
            cream: UIColor(red: 0.969, green: 0.953, blue: 0.922, alpha: 1),
            warmBrown: UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 1),
            adminAccent: UIColor(red: 0.141, green: 0.420, blue: 0.831, alpha: 1),
            ink: UIColor(red: 0.239, green: 0.204, blue: 0.161, alpha: 1),
            bubbleSelfGradient: [
                UIColor(red: 0.834, green: 0.930, blue: 0.789, alpha: 1),
                UIColor(red: 0.834, green: 0.930, blue: 0.789, alpha: 1)
            ],
            bubbleOtherGradient: [
                UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1),
                UIColor(red: 0.992, green: 0.965, blue: 0.933, alpha: 1)
            ],
            avatarGradient: [
                UIColor(red: 0.62, green: 0.36, blue: 0.30, alpha: 1),
                UIColor(red: 0.72, green: 0.45, blue: 0.39, alpha: 1)
            ],
            terracotta: UIColor(red: 0.769, green: 0.471, blue: 0.361, alpha: 1),
            borderSubtle: UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 0.18),
            fadeTop: UIColor(red: 1, green: 1, blue: 1, alpha: 0),
            failureText: UIColor(red: 0.6, green: 0.12, blue: 0.12, alpha: 1),
            failureBackground: UIColor(red: 0.98, green: 0.92, blue: 0.92, alpha: 1),
            shadowNear: UIColor(red: 0.361, green: 0.290, blue: 0.239, alpha: 0.30),
            textMuted: UIColor(red: 0.651, green: 0.608, blue: 0.553, alpha: 1)
        )
    }

    static func borderSubtle(isDark: Bool) -> UIColor {
        palette(isDark: isDark).borderSubtle
    }

    static func avatarGradient(isDark: Bool) -> [UIColor] {
        palette(isDark: isDark).avatarGradient
    }

    static func failureText(isDark: Bool) -> UIColor {
        palette(isDark: isDark).failureText
    }

    static func failureBackground(isDark: Bool) -> UIColor {
        palette(isDark: isDark).failureBackground
    }
}

final class TruncationFadeView: UIView {
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(gradientLayer)
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func updateColors(top: UIColor, bottom: UIColor) {
        gradientLayer.colors = [top.cgColor, bottom.cgColor]
    }

    func setFadeStartLocation(_ start: CGFloat?) {
        if let start {
            let clampedStart = max(0, min(start, 1))
            gradientLayer.locations = [NSNumber(value: Double(clampedStart)), 1.0]
        } else {
            gradientLayer.locations = nil
        }
    }
}

private extension UIView {
    func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller.topPresentedController()
            }
            responder = current.next
        }
        return nil
    }
}

private extension UIViewController {
    func topPresentedController() -> UIViewController {
        var current = self
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}

final class MessageBubbleUIKitCell: UICollectionViewCell {
    static let reuseIdentifier = "MessageBubbleUIKitCell"
    private static let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "FlowLayout")

    private let containerView = MessageBubbleUIKitContainerView()
    private var messageId: String = ""
    private var messageSnippet: String = ""
    private var lastMismatch: (bounds: CGRect, bubble: CGRect)?
    private var flashOverlayView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: Message,
                   presentation: MessagePresentation,
                   failureReason: String?,
                   isCompact: Bool,
                   maxWidth: CGFloat,
                   bubbleHeightPolicy: BubbleSizingV2.BubbleHeightPolicy? = nil,
                   truncationHeightOverride: CGFloat? = nil,
                   bubbleSizingV2: BubbleSizingV2.LayoutState? = nil,
                   showsHeader: Bool = true,
                   isDark: Bool? = nil,
                   terminalConnectionPool: TerminalSessionConnectionPool? = nil,
                   webBubbleCoordinator: (any WebBubbleCoordinating)? = nil,
                   salientHighlightService: (any SalientHighlightServicing)? = nil,
                   onRequestExpand: (() -> Void)?,
                   onRequestLayout: ((String) -> Void)?,
                   onInteractiveCallback: ((String, String, JSONValue?) -> Void)?,
                   onResend: (() -> Void)?) {
        messageId = message.id
        messageSnippet = String(message.content.prefix(80))
        let guardedRequestLayout: (String) -> Void = { [weak self] requestedId in
            guard let self, self.messageId == requestedId else { return }
            onRequestLayout?(requestedId)
        }
        containerView.configure(
            message: message,
            presentation: presentation,
            failureReason: failureReason,
            isCompact: isCompact,
            maxWidth: maxWidth,
            bubbleHeightPolicy: bubbleHeightPolicy,
            truncationHeightOverride: truncationHeightOverride,
            bubbleSizingV2: bubbleSizingV2,
            showsHeader: showsHeader,
            isDark: isDark,
            terminalConnectionPool: terminalConnectionPool,
            webBubbleCoordinator: webBubbleCoordinator,
            salientHighlightService: salientHighlightService,
            onRequestExpand: onRequestExpand,
            onRequestLayout: guardedRequestLayout,
            onInteractiveCallback: onInteractiveCallback,
            onResend: onResend
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        containerView.prepareForReuse()
        flashOverlayView?.removeFromSuperview()
        flashOverlayView = nil
        messageId = ""
        messageSnippet = ""
        lastMismatch = nil
    }

    func flashUnreadAnchorHighlight(isUnreadTap: Bool) {
        flashOverlayView?.removeFromSuperview()
        flashOverlayView = nil

        let bubbleFrame = containerView.bubbleFrameInContainer()
        let bubbleInCell = containerView.convert(bubbleFrame, to: contentView)
        guard bubbleInCell.width > 8, bubbleInCell.height > 8 else { return }

        let isDark = traitCollection.userInterfaceStyle == .dark
        let palette = ChatFlowUIKitTheme.palette(isDark: isDark)
        let overlay = UIView(frame: bubbleInCell.insetBy(dx: -5, dy: -5))
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = palette.terracotta.withAlphaComponent(isDark ? 0.14 : 0.18)
        overlay.layer.borderColor = palette.terracotta.withAlphaComponent(isDark ? 0.95 : 0.85).cgColor
        overlay.layer.borderWidth = 2
        overlay.layer.cornerRadius = 18
        overlay.layer.cornerCurve = .continuous
        overlay.alpha = 0

        contentView.addSubview(overlay)
        flashOverlayView = overlay

        if isUnreadTap {
            // 3 flashes over 1s, then a slow 3s fade.
            UIView.animateKeyframes(
                withDuration: 1.0,
                delay: 0,
                options: [.calculationModeLinear, .allowUserInteraction]
            ) {
                // Flash 1
                UIView.addKeyframe(withRelativeStartTime: 0.00, relativeDuration: 0.10) { overlay.alpha = 1 }
                UIView.addKeyframe(withRelativeStartTime: 0.10, relativeDuration: 0.12) { overlay.alpha = 0 }
                // Flash 2
                UIView.addKeyframe(withRelativeStartTime: 0.32, relativeDuration: 0.10) { overlay.alpha = 1 }
                UIView.addKeyframe(withRelativeStartTime: 0.42, relativeDuration: 0.12) { overlay.alpha = 0 }
                // Flash 3 (end "on")
                UIView.addKeyframe(withRelativeStartTime: 0.64, relativeDuration: 0.10) { overlay.alpha = 1 }
            } completion: { _ in
                UIView.animate(
                    withDuration: 3.0,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction]
                ) {
                    overlay.alpha = 0
                } completion: { [weak self] _ in
                    overlay.removeFromSuperview()
                    if self?.flashOverlayView === overlay {
                        self?.flashOverlayView = nil
                    }
                }
            }
        } else {
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                overlay.alpha = 1
            } completion: { _ in
                UIView.animate(
                    withDuration: 0.38,
                    delay: 0.10,
                    options: [.curveEaseIn, .allowUserInteraction]
                ) {
                    overlay.alpha = 0
                } completion: { [weak self] _ in
                    overlay.removeFromSuperview()
                    if self?.flashOverlayView === overlay {
                        self?.flashOverlayView = nil
                    }
                }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bubbleFrame = containerView.bubbleFrameInContainer()
        let bubbleInCell = containerView.convert(bubbleFrame, to: contentView)
        let bounds = contentView.bounds
        let heightDelta = abs(bounds.height - bubbleInCell.height)
        let widthDelta = abs(bounds.width - bubbleInCell.width)
        let yDelta = abs(bubbleInCell.minY - bounds.minY)
        let xDelta = abs(bubbleInCell.minX - bounds.minX)
        guard heightDelta > 1 || widthDelta > 1 || yDelta > 1 || xDelta > 1 else {
            lastMismatch = nil
            return
        }
        if let lastMismatch,
           abs(lastMismatch.bounds.width - bounds.width) < 1,
           abs(lastMismatch.bounds.height - bounds.height) < 1,
           abs(lastMismatch.bubble.width - bubbleInCell.width) < 1,
           abs(lastMismatch.bubble.height - bubbleInCell.height) < 1,
           abs(lastMismatch.bubble.minX - bubbleInCell.minX) < 1,
           abs(lastMismatch.bubble.minY - bubbleInCell.minY) < 1 {
            return
        }
        lastMismatch = (bounds: bounds, bubble: bubbleInCell)
        let boundsDesc = String(describing: bounds)
        let bubbleDesc = String(describing: bubbleInCell)
        let id = messageId
        let snippet = messageSnippet
        Self.logger.info("UIKit bubble mismatch id=\(id) snippet=\"\(snippet)\"")
        Self.logger.info("UIKit bubble mismatch bounds=\(boundsDesc)")
        Self.logger.info("UIKit bubble mismatch bubble=\(bubbleDesc)")
    }
}

// MARK: - Code Block View

/// UIKit wrapper for the shared SwiftUI CodeBlockView.
/// This keeps bubble and expanded code block rendering/theming on one implementation path.
final class CodeBlockUIKitView: UIView {
    private var hostingController: UIHostingController<AnyView>?
    private var currentLanguage: String?
    private var currentCode: String = ""
    private var explicitIsDarkOverride: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(language: String?, code: String, isDark: Bool? = nil) {
        currentLanguage = language
        currentCode = code
        explicitIsDarkOverride = isDark
        rebuildHostedView()
    }

    func setAppearanceOverride(isDark: Bool?) {
        explicitIsDarkOverride = isDark
        applyInterfaceStyle()
    }

    private func rebuildHostedView() {
        hostingController?.view.removeFromSuperview()
        hostingController = nil

        let codeView = CodeBlockView(language: currentLanguage, code: currentCode)
        let controller = UIHostingController(rootView: AnyView(codeView))
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.safeAreaRegions = []
        addSubview(controller.view)

        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        hostingController = controller
        applyInterfaceStyle()
        controller.view.layoutIfNeeded()
    }

    private func applyInterfaceStyle() {
        guard let hostingController else { return }
        if let explicitIsDarkOverride {
            let style: UIUserInterfaceStyle = explicitIsDarkOverride ? .dark : .light
            hostingController.overrideUserInterfaceStyle = style
            hostingController.view.overrideUserInterfaceStyle = style
        } else {
            hostingController.overrideUserInterfaceStyle = .unspecified
            hostingController.view.overrideUserInterfaceStyle = .unspecified
        }
    }

    override var intrinsicContentSize: CGSize {
        guard let hostingView = hostingController?.view else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 44)
        }
        let size = hostingView.intrinsicContentSize
        if size.height > 0 {
            return size
        }
        let fittingSize = hostingView.systemLayoutSizeFitting(
            CGSize(width: bounds.width > 0 ? bounds.width : 300, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return fittingSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let hostingView = hostingController?.view else {
            return CGSize(width: size.width, height: 44)
        }
        return hostingView.systemLayoutSizeFitting(
            CGSize(width: size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}

// MARK: - Table Wrapper View

/// UIKit wrapper for the SwiftUI MarkdownTableView.
/// Embeds the SwiftUI table using UIHostingController for consistent rendering.
final class TableUIKitWrapperView: UIView {
    private var hostingController: UIHostingController<AnyView>?
    private var currentModel: TableModel?
    private var currentRole: Message.Role = .assistant
    private var currentMetrics: ChatFlowTheme.Metrics?
    private var onExpandAction: (() -> Void)?
    private var cachedHeight: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        model: TableModel,
        role: Message.Role,
        metrics: ChatFlowTheme.Metrics,
        maxLineWidth: CGFloat,
        isDark: Bool,
        onExpand: @escaping () -> Void
    ) {
        currentModel = model
        currentRole = role
        currentMetrics = metrics
        onExpandAction = onExpand
        cachedHeight = nil

        // Remove existing hosting controller
        hostingController?.view.removeFromSuperview()
        hostingController = nil

        // Create SwiftUI table view
        let tableView = MarkdownTableView(
            model: model,
            role: role,
            metrics: metrics,
            maxLineWidth: maxLineWidth,
            isExpanded: false,
            onExpand: onExpand,
            onCollapse: { }
        )

        let hostingController = UIHostingController(rootView: AnyView(tableView))
        let style: UIUserInterfaceStyle = isDark ? .dark : .light
        hostingController.overrideUserInterfaceStyle = style
        hostingController.view.backgroundColor = .clear
        hostingController.view.overrideUserInterfaceStyle = style
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        // Disable safe area insets to prevent layout issues
        hostingController.safeAreaRegions = []
        addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        self.hostingController = hostingController

        // Force layout to get accurate size
        hostingController.view.layoutIfNeeded()
    }

    override var intrinsicContentSize: CGSize {
        guard let hostingView = hostingController?.view else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 44)
        }
        let size = hostingView.intrinsicContentSize
        if size.height > 0 {
            return size
        }
        // Fallback: calculate based on fitting size
        let fittingSize = hostingView.systemLayoutSizeFitting(
            CGSize(width: bounds.width > 0 ? bounds.width : 300, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return fittingSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let hostingView = hostingController?.view else {
            return CGSize(width: size.width, height: 44)
        }

        // Force layout pass to ensure accurate measurement
        hostingView.setNeedsLayout()
        hostingView.layoutIfNeeded()

        let targetSize = CGSize(width: size.width, height: UIView.layoutFittingCompressedSize.height)
        let fittingSize = hostingView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        // Cache and return
        cachedHeight = fittingSize.height
        return fittingSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Invalidate intrinsic content size when layout changes
        invalidateIntrinsicContentSize()
    }
}
