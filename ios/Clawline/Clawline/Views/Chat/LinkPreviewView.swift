//
//  LinkPreviewView.swift
//  Clawline
//
//  Created by Codex on 2/4/26.
//

import Darwin
import Foundation
import OSLog
import SafariServices
import UIKit
import WebKit
#if canImport(SwiftUI)
import SwiftUI
#endif

private final class BubbleSafeAreaNeutralWebView: WKWebView {
    override var safeAreaInsets: UIEdgeInsets { .zero }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        stabilizeScrollInsets()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stabilizeScrollInsets()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stabilizeScrollInsets()
    }

    private func stabilizeScrollInsets() {
        // Keep content anchored to the preview frame while chat list handles screen insets.
        if scrollView.contentInsetAdjustmentBehavior != .never {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        if scrollView.contentInset != .zero {
            scrollView.contentInset = .zero
        }
        let hasVerticalIndicatorInsets = scrollView.verticalScrollIndicatorInsets != .zero
        let hasHorizontalIndicatorInsets = scrollView.horizontalScrollIndicatorInsets != .zero
        if hasVerticalIndicatorInsets || hasHorizontalIndicatorInsets {
            scrollView.verticalScrollIndicatorInsets = .zero
            scrollView.horizontalScrollIndicatorInsets = .zero
        }
        if #available(iOS 13.0, visionOS 1.0, *), scrollView.automaticallyAdjustsScrollIndicatorInsets {
            scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        scrollView.insetsLayoutMarginsFromSafeArea = false
        insetsLayoutMarginsFromSafeArea = false
    }
}

final class LinkPreviewView: UIView, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "LinkPreview")
    private static let heightCache = NSCache<NSString, NSNumber>()

    enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.loaded, .loaded), (.failed, .failed):
                return true
            default:
                return false
            }
        }
    }

    enum FailureReason: String, Sendable {
        case timeout
        case missingHost
        case hostBlocked
        case blockedIPAddressHost
        case redirectLimitExceeded
        case redirectHostBlocked
        case nonHTMLMimeType
        case navigationError
        case provisionalNavigationError
        case emptyBodyHeuristic
        case unknown
    }

    enum CancelReason: String, Sendable {
        case deinitCancel
        case removedFromWindow
        case reuse
        case resetState
        case failureCleanup
    }

    private enum Constants {
        static let defaultMinHeight: CGFloat = 140
        static let defaultMaxHeight: CGFloat = 360
        static let loadTimeout: TimeInterval = 12
        static let emptyBodyDelay: TimeInterval = 0.5
        static let maxRedirects = 5
        // Design system (Link Preview card): 16px radius.
        static let mediaCornerRadius: CGFloat = 16
        static let mediaCornerExponent: CGFloat = 5.0
    }

    /// `UIStackView` lays out arranged subviews (including their final frames) in its own
    /// `layoutSubviews` pass, which can occur after `LinkPreviewView.layoutSubviews`.
    ///
    /// If we update a `layer.mask` for the container too early, the mask can get stuck at a
    /// smaller height, producing the exact failure mode reported by Flynn: only a top strip
    /// paints while the rest of the viewport is hit-testable/scrollable but visually blank.
    ///
    /// Fix: make the container responsible for keeping its own mask in sync with its bounds.
    private final class MaskedWebContainerView: UIView {
        var cornerRadius: CGFloat = Constants.mediaCornerRadius
        var exponent: CGFloat = Constants.mediaCornerExponent

        private let maskLayer = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.mask = maskLayer
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 1, bounds.height > 1 else { return }
            maskLayer.frame = bounds
            maskLayer.path = Self.superellipseRoundedRectPath(
                rect: bounds,
                radius: cornerRadius,
                exponent: exponent
            ).cgPath
        }

        private static func superellipseRoundedRectPath(rect: CGRect, radius: CGFloat, exponent: CGFloat) -> UIBezierPath {
            let r = min(radius, min(rect.width, rect.height) / 2)
            let steps = 12
            let quarterPoints = superellipseQuarterPoints(radius: 1, exponent: exponent, steps: steps)

            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            appendCorner(path: path,
                         center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                         radius: r,
                         points: quarterPoints,
                         transform: { CGPoint(x: $0.y, y: -$0.x) })
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            appendCorner(path: path,
                         center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                         radius: r,
                         points: quarterPoints,
                         transform: { CGPoint(x: $0.x, y: $0.y) })
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            appendCorner(path: path,
                         center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                         radius: r,
                         points: quarterPoints,
                         transform: { CGPoint(x: -$0.y, y: $0.x) })
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            appendCorner(path: path,
                         center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                         radius: r,
                         points: quarterPoints,
                         transform: { CGPoint(x: -$0.x, y: -$0.y) })
            path.close()
            return path
        }

        private static func superellipseQuarterPoints(radius: CGFloat, exponent: CGFloat, steps: Int) -> [CGPoint] {
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

        private static func appendCorner(path: UIBezierPath,
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

    private let stackView = UIStackView()
    private let webContainer = MaskedWebContainerView()
    private let statusLabel = UILabel()
    private let reloadButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let overlayButton = UIButton(type: .custom)
    private let webView: WKWebView
    private var webViewHeightConstraint: NSLayoutConstraint!
    private var maxHeight: CGFloat = Constants.defaultMaxHeight
    private var minHeight: CGFloat = Constants.defaultMinHeight

    private var chromeBaseColor: UIColor?
    private var chromeIsDark: Bool = false

    private var state: State = .idle
    private var currentURL: URL?
    private var configuredURLKey: String?
    private var currentHost: String?
    private var redirectCount = 0

    private var loadToken = UUID()
    private var handlerName: String?
    private var handlerRegistered = false
    private var heightUpdates = 0

    private var loadTimeoutTimer: Timer?
    private var fallbackTimer: Timer?

    private var canLockHeight = false
    private var isHeightLocked = false
    private var fullscreenStateObservation: NSKeyValueObservation?
    private var isDirectMediaPreview = false

    var onHeightChange: (() -> Void)?

    private(set) var mediaPlaybackSuspendedForPreview = false

    private var loadStartedAt: CFTimeInterval?
    private var lastFailureReason: FailureReason?
    private var didShowEmptyBodyWarning = false

    // Invariant (#40): never cancel a preview load that is currently visible (in-window and onscreen)
    // due to memory pressure. Evict queued/offscreen loads first.
    private var memoryWarningObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false

        let webView = BubbleSafeAreaNeutralWebView(frame: .zero, configuration: configuration)
        self.webView = webView

        super.init(frame: frame)

        setupViews()
        suspendMediaPlaybackForPreview()
        observeFullscreenState()

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard !self.isActuallyVisible() else {
                self.logger.info("memory warning: keeping visible preview url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public)")
                return
            }

            // Evict offscreen work first. This avoids killing a visible load and helps relieve pressure.
            if self.state == .loading {
                self.logger.warning("memory warning: evicting offscreen preview url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public)")
                self.cancelLoad()
                self.state = .idle
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        logCancel(.deinitCancel)
        fullscreenStateObservation?.invalidate()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        cancelLoad()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startLoadIfNeeded()
        } else {
            logCancel(.removedFromWindow)
            cancelLoad()
        }
    }

    override var intrinsicContentSize: CGSize {
        let height = webViewHeightConstraint?.constant ?? minHeight
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // MessageBubbleUIKitView's truncation logic relies on `sizeThatFits` to estimate
        // dynamic content height. Auto Layout fitting can return ~0 here because this view
        // is often measured before it has a stable bounds/constraint context.
        //
        // Compute a conservative height directly from our known subview heights so truncation
        // detection can enable scrolling instead of clipping (#62).
        let width = (size.width > 1 ? size.width : (bounds.width > 1 ? bounds.width : 320))

        // While loading we don't yet know the page height; report at least `maxHeight` so the
        // bubble can decide to enable its inner scroll when constrained by a height cap.
        let baseWebHeight: CGFloat
        if isDirectMediaPreview {
            baseWebHeight = Self.preferredDirectMediaHeight(for: width, maxHeight: maxHeight)
        } else if state == .idle || state == .loading {
            baseWebHeight = maxHeight
        } else {
            baseWebHeight = webViewHeightConstraint?.constant ?? minHeight
        }
        var totalHeight = isDirectMediaPreview ? baseWebHeight : max(minHeight, baseWebHeight)

        if !statusLabel.isHidden {
            let labelHeight = statusLabel.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            totalHeight += stackView.spacing + labelHeight
        }
        if !reloadButton.isHidden {
            let buttonHeight = reloadButton.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            totalHeight += stackView.spacing + buttonHeight
        }

        return CGSize(width: width, height: totalHeight)
    }

    var reportedHeight: CGFloat {
        webViewHeightConstraint?.constant ?? minHeight
    }

    var configuredCacheKey: String? {
        configuredURLKey
    }

    func configure(url: URL, maxHeight: CGFloat? = nil) {
        configure(
            url: url,
            maxHeight: maxHeight,
            minHeight: nil,
            cacheKey: nil,
            initialHeight: nil
        )
    }

    func configure(url: URL,
                   maxHeight: CGFloat?,
                   minHeight: CGFloat? = nil,
                   cacheKey: String? = nil,
                   initialHeight: CGFloat? = nil) {
        let desiredMinHeight = max(1, minHeight ?? Constants.defaultMinHeight)
        let desiredMaxHeight = max(desiredMinHeight, maxHeight ?? Constants.defaultMaxHeight)
        let desiredKey = cacheKey ?? url.absoluteString
        if currentURL == url,
           configuredURLKey == desiredKey,
           state != .failed,
           abs(self.minHeight - desiredMinHeight) <= 1,
           abs(self.maxHeight - desiredMaxHeight) <= 1 {
            return
        }
        resetState()
        self.minHeight = desiredMinHeight
        self.maxHeight = desiredMaxHeight
        configuredURLKey = desiredKey
        isDirectMediaPreview = Self.isDirectMediaPreviewURL(url)
        updateScrollBehaviorForPreviewContent()
        // Flynn directive: keep link preview height stable once determined. Use cached height
        // on scroll-back; only re-measure after explicit reload.
        if let cachedKey = configuredURLKey,
           let cached = Self.heightCache.object(forKey: cachedKey as NSString) {
            isHeightLocked = true
            canLockHeight = false
            webViewHeightConstraint.constant = max(self.minHeight, min(self.maxHeight, CGFloat(truncating: cached)))
            invalidateIntrinsicContentSize()
            onHeightChange?()
        } else {
            let target = initialHeight
                ?? (isDirectMediaPreview
                    ? Self.preferredDirectMediaHeight(for: max(bounds.width, 320), maxHeight: self.maxHeight)
                    : self.minHeight)
            if abs(webViewHeightConstraint.constant - target) > 1 {
                webViewHeightConstraint.constant = target
                invalidateIntrinsicContentSize()
                onHeightChange?()
            }
        }
        currentURL = url
        let hostLabel = url.host ?? url.absoluteString
        isAccessibilityElement = true
        accessibilityLabel = "Link preview: \(hostLabel)"
        accessibilityTraits = .link
        startLoadIfNeeded()
        logger.info("configure url=\(url.absoluteString, privacy: .public)")
    }

    func prepareForReuse() {
        logCancel(.reuse)
        cancelLoad()
        currentURL = nil
        configuredURLKey = nil
        currentHost = nil
        redirectCount = 0
        state = .idle
        canLockHeight = false
        isHeightLocked = false
        isDirectMediaPreview = false
        updateScrollBehaviorForPreviewContent()
    }

    func reloadPreview() {
        handleReloadTap()
    }

    func setBubbleChrome(baseColor: UIColor, isDark: Bool) {
        chromeBaseColor = baseColor
        chromeIsDark = isDark
        applyChrome()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // MaskedWebContainerView keeps its own mask synced to its bounds.
        syncDirectMediaPreviewHeightIfNeeded(notifyOnChange: false)
    }

    private func setupViews() {
        backgroundColor = .clear
        // Prevent the web content from painting outside the preview bounds, which can
        // visually overlap adjacent arranged subviews (message text above/below).
        clipsToBounds = true

        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = .clear
        webContainer.cornerRadius = Constants.mediaCornerRadius
        webContainer.exponent = Constants.mediaCornerExponent
        stackView.addArrangedSubview(webContainer)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.clipsToBounds = true
        webView.insetsLayoutMarginsFromSafeArea = false
        // Keep only one visible corner treatment: the outer squircle mask on `webContainer`.
        // Applying an additional WKWebView corner radius creates a second darker inner rim.
        webView.layer.cornerRadius = 0
        webView.scrollView.clipsToBounds = true
        webView.scrollView.insetsLayoutMarginsFromSafeArea = false
        webView.scrollView.layer.cornerRadius = 0
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.alwaysBounceVertical = false
        // Ensure the page starts at the top of the preview viewport and doesn't
        // apply safe-area based insets inside message bubbles.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 13.0, visionOS 1.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        webView.allowsLinkPreview = false
        webView.isUserInteractionEnabled = true
        webContainer.addSubview(webView)

        // Tap anywhere on the preview to open in the browser, but allow scrolling.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleOverlayTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delegate = self
        webContainer.addGestureRecognizer(tap)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        webContainer.addSubview(spinner)

        webViewHeightConstraint = webView.heightAnchor.constraint(equalToConstant: Constants.defaultMinHeight)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            webViewHeightConstraint,

            spinner.centerXAnchor.constraint(equalTo: webContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: webContainer.centerYAnchor)
        ])

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Preview unavailable"
        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        stackView.addArrangedSubview(statusLabel)

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.setTitle("Reload preview", for: .normal)
        reloadButton.addTarget(self, action: #selector(handleReloadTap), for: .touchUpInside)
        reloadButton.contentHorizontalAlignment = .leading
        reloadButton.isHidden = true
        stackView.addArrangedSubview(reloadButton)

        applyChrome()
        updateScrollBehaviorForPreviewContent()
    }

    // Mask path computation now lives in MaskedWebContainerView.

    private func applyChrome() {
        guard let chromeBaseColor else { return }
        // Darken the bubble base color to create a distinct surface behind the embedded browser.
        let amount: CGFloat = chromeIsDark ? 0.14 : 0.08
        let surface = chromeBaseColor.darkened(by: amount)
        webContainer.backgroundColor = surface
        if #available(iOS 15.0, visionOS 1.0, *) {
            webView.underPageBackgroundColor = surface
        }
    }

    private func startLoadIfNeeded() {
        guard window != nil else { return }
        guard let currentURL else { return }
        guard state == .idle else { return }
        startLoad(url: currentURL)
    }

    private func setLoadingState() {
        state = .loading
        statusLabel.isHidden = true
        reloadButton.isHidden = true
        webContainer.isHidden = false
        spinner.startAnimating()
    }

    private func startLoad(url: URL) {
        setLoadingState()
        redirectCount = 0
        currentHost = url.host
        loadToken = UUID()
        heightUpdates = 0
        loadStartedAt = CACurrentMediaTime()
        lastFailureReason = nil
        canLockHeight = false

        if isDirectMediaPreview {
            syncDirectMediaPreviewHeightIfNeeded(notifyOnChange: false)
        } else if !isHeightLocked {
            configureHeightObserver()
        }
        scheduleLoadTimeout()

        resolveHostAndLoad(url: url)
    }

    private func resolveHostAndLoad(url: URL) {
        guard let host = url.host else {
            logger.error("resolveHostAndLoad failed: missing host for url=\(url.absoluteString, privacy: .public)")
            handleFailure(.missingHost)
            return
        }
        currentURL = url
        currentHost = host

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let resolution = self.resolveHost(host)
            DispatchQueue.main.async {
                guard self.currentURL == url else { return }
                switch resolution {
                case .allowed(let ipSet):
                    self.logger.info("host resolved host=\(host, privacy: .public) ips=\(ipSet.joined(separator: ","), privacy: .public)")
                    self.loadURL(url)
                case .blocked:
                    self.logger.error("host blocked host=\(host, privacy: .public)")
                    self.handleFailure(.hostBlocked)
                }
            }
        }
    }

    private func loadURL(_ url: URL) {
        // Temporarily disabled (#35) - re-enable useProtocolCachePolicy once stabilization is proven solid.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Constants.loadTimeout)
        webView.load(request)
    }

    private func resetState(keepURL: Bool = false) {
        logCancel(.resetState)
        cancelLoad()
        statusLabel.isHidden = true
        reloadButton.isHidden = true
        webContainer.isHidden = false
        state = .idle
        canLockHeight = false
        isHeightLocked = false
        didShowEmptyBodyWarning = false
        if !keepURL {
            currentURL = nil
            configuredURLKey = nil
        }
        currentHost = nil
        redirectCount = 0
        if keepURL, let currentURL {
            isDirectMediaPreview = Self.isDirectMediaPreviewURL(currentURL)
        } else {
            isDirectMediaPreview = false
        }
        updateScrollBehaviorForPreviewContent()
    }

    private func cancelLoad() {
        loadTimeoutTimer?.invalidate()
        fallbackTimer?.invalidate()
        loadTimeoutTimer = nil
        fallbackTimer = nil
        closeUnexpectedMediaPresentationsIfNeeded()
        webView.stopLoading()
        spinner.stopAnimating()
        removeHeightObserver()
    }

    private func suspendMediaPlaybackForPreview() {
        guard !mediaPlaybackSuspendedForPreview else { return }
        mediaPlaybackSuspendedForPreview = true
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    private func observeFullscreenState() {
        fullscreenStateObservation = webView.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] _, _ in
            self?.closeUnexpectedMediaPresentationsIfNeeded()
        }
    }

    private func closeUnexpectedMediaPresentationsIfNeeded() {
        guard webView.fullscreenState != .notInFullscreen else { return }
        logger.warning("closing unexpected media presentation url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public) fullscreenState=\(self.webView.fullscreenState.rawValue, privacy: .public)")
        webView.closeAllMediaPresentations(completionHandler: nil)
    }

    private func scheduleLoadTimeout() {
        loadTimeoutTimer?.invalidate()
        loadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Constants.loadTimeout, repeats: false) { [weak self] _ in
            self?.handleFailure(.timeout, detail: "load")
        }
    }

    private func scheduleFallbackMeasurement() {
        guard !isDirectMediaPreview else { return }
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: Constants.emptyBodyDelay, repeats: false) { [weak self] _ in
            if self?.heightUpdates == 0 {
                self?.evaluateHeightFallback()
            }
            self?.evaluateEmptyBodyFallback()
        }
    }

    private func evaluateHeightFallback() {
        // document.*.scrollHeight bottoms out at viewport height, so small pages can appear "tall"
        // if we start the preview at a large height. Use rendered content extents instead.
        let js = """
        (function(){
          try {
            var body = document.body;
            if (!body) { return null; }
            var maxBottom = 0;
            // 4 == NodeFilter.SHOW_TEXT
            var textWalker = document.createTreeWalker(body, 4, null);
            var textCount = 0;
            while (textWalker.nextNode()) {
              var node = textWalker.currentNode;
              if (!node || !node.textContent) { continue; }
              if (!node.textContent.trim()) { continue; }
              var r = document.createRange();
              r.selectNodeContents(node);
              var rect = r.getBoundingClientRect();
              var bottom = (rect && rect.bottom) ? rect.bottom : 0;
              if (bottom > maxBottom) { maxBottom = bottom; }
              textCount++;
              if (textCount > 4000) { break; }
            }

            // 1 == NodeFilter.SHOW_ELEMENT
            var elementWalker = document.createTreeWalker(body, 1, null);
            var elementCount = 0;
            while (elementWalker.nextNode()) {
              var el = elementWalker.currentNode;
              if (!el || !el.getBoundingClientRect) { continue; }
              var tag = (el.tagName || '').toUpperCase();
              if (tag === 'IMG' || tag === 'VIDEO' || tag === 'IFRAME' || tag === 'CANVAS' || tag === 'SVG') {
                var eRect = el.getBoundingClientRect();
                var eBottom = (eRect && eRect.bottom) ? eRect.bottom : 0;
                if (eBottom > maxBottom) { maxBottom = eBottom; }
              }
              elementCount++;
              if (elementCount > 2500) { break; }
            }

            var scrollY = (window.scrollY || 0);
            return Math.max(0, maxBottom + scrollY);
          } catch(e) { return null; }
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            guard let heightNumber = result as? NSNumber else { return }
            self.applyMeasuredHeight(heightNumber.doubleValue)
        }
    }

    private func evaluateEmptyBodyFallback() {
        let js = "(function(){try{return {textLength:(document.body?.innerText||'').trim().length, childCount:(document.body?.childElementCount||0)};}catch(e){return {textLength:0, childCount:0};}})();"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            guard let dict = result as? [String: Any],
                  let textLength = dict["textLength"] as? Int,
                  let childCount = dict["childCount"] as? Int else { return }
            if textLength < 16 && childCount < 1 {
                // #39: Do not treat "empty body" as terminal failure. Many JS-heavy pages
                // render late, use canvas/shadow DOM, or populate after initial load.
                guard !self.didShowEmptyBodyWarning else { return }
                self.didShowEmptyBodyWarning = true
                self.logger.warning("page appears empty (non-fatal) url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public)")
                self.statusLabel.text = "Page appears empty. You can reload to try again."
                self.statusLabel.isHidden = false
                self.reloadButton.isHidden = false
            }
        }
    }

    private func applyMeasuredHeight(_ rawHeight: Double) {
        guard !isDirectMediaPreview else {
            syncDirectMediaPreviewHeightIfNeeded()
            return
        }
        guard rawHeight.isFinite else { return }
        markLoadedIfNeeded()
        let clamped = max(minHeight, min(maxHeight, CGFloat(rawHeight)))
        let needsScroll = rawHeight > Double(maxHeight)
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.showsVerticalScrollIndicator = needsScroll
        webView.scrollView.alwaysBounceVertical = needsScroll
        if isHeightLocked {
            return
        }
        if abs(webViewHeightConstraint.constant - clamped) <= 10 {
            return
        }
        webViewHeightConstraint.constant = clamped
        invalidateIntrinsicContentSize()
        onHeightChange?()

        // Flynn directive: lock and cache preview height once it's determined post-load.
        if canLockHeight {
            isHeightLocked = true
            canLockHeight = false
            if let configuredURLKey {
                Self.heightCache.setObject(NSNumber(value: Double(clamped)), forKey: configuredURLKey as NSString)
            }
        }
    }

    private func handleFailure(_ reason: FailureReason, detail: String? = nil) {
        guard state != .failed else { return }
        state = .failed
        lastFailureReason = reason
        logFailure(reason, detail: detail)
        logCancel(.failureCleanup)
        cancelLoad()
        webContainer.isHidden = true
        statusLabel.isHidden = false
        reloadButton.isHidden = false

        // Always show the failure reason so users (and Flynn) can understand what happened.
        var lines: [String] = ["Preview unavailable (\(reason.rawValue))"]
        if let detail, !detail.isEmpty {
            lines.append(detail)
        }
        if let urlString = currentURL?.absoluteString {
            lines.append(urlString)
        }
        statusLabel.text = lines.joined(separator: "\n")
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    private func showNonFatalError(_ message: String) {
        guard state != .failed else { return }
        // Keep the web preview visible; just surface the error and offer reload.
        webContainer.isHidden = false
        statusLabel.text = message
        statusLabel.isHidden = false
        reloadButton.isHidden = false
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    @objc private func handleReloadTap() {
        guard currentURL != nil else { return }
        logger.info("reload tapped url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public)")
        if let configuredURLKey {
            Self.heightCache.removeObject(forKey: configuredURLKey as NSString)
        }
        resetState(keepURL: true)
        startLoadIfNeeded()
    }

    private func markLoadedIfNeeded() {
        guard state == .loading else { return }
        loadTimeoutTimer?.invalidate()
        loadTimeoutTimer = nil
        spinner.stopAnimating()
        state = .loaded
    }

    @objc private func handleOverlayTap() {
        guard let url = currentURL else { return }
#if os(visionOS)
        UIApplication.shared.open(url)
#else
        let safari = SFSafariViewController(url: url)
        parentViewController?.present(safari, animated: true)
#endif
    }

    override func accessibilityActivate() -> Bool {
        handleOverlayTap()
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        logger.info("didStartProvisionalNavigation url=\(self.currentURL?.absoluteString ?? "nil", privacy: .public)")
        // #36: No silent failures. Clear any non-fatal warnings/errors once WebKit starts a new navigation.
        if state != .failed {
            statusLabel.isHidden = true
            reloadButton.isHidden = true
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        markLoadedIfNeeded()
        if isDirectMediaPreview {
            syncDirectMediaPreviewHeightIfNeeded()
            return
        }
        scheduleFallbackMeasurement()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            logger.info("navigationAction cancelled: missing url token=\(self.loadToken.uuidString, privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        guard isAllowedScheme(url) else {
            logger.info("navigationAction cancelled: blocked scheme scheme=\(url.scheme ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        if isBlockedIPAddressHost(url.host) {
            decisionHandler(.cancel)
            logger.error("navigationAction blocked host=\(url.host ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public)")
            handleFailure(.blockedIPAddressHost, detail: "navAction")
            return
        }
        if let host = url.host, host != currentHost {
            redirectCount += 1
            guard redirectCount <= Constants.maxRedirects else {
                decisionHandler(.cancel)
                logger.error("redirect limit exceeded host=\(host, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                handleFailure(.redirectLimitExceeded, detail: host)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    DispatchQueue.main.async { decisionHandler(.cancel) }
                    return
                }
                let resolution = self.resolveHost(host)
                DispatchQueue.main.async {
                    guard self.state == .loading else {
                        decisionHandler(.cancel)
                        return
                    }
                    switch resolution {
                    case .blocked:
                        decisionHandler(.cancel)
                        self.logger.error("redirect host blocked host=\(host, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                        self.handleFailure(.redirectHostBlocked, detail: host)
                    case .allowed:
                        self.currentURL = url
                        self.currentHost = host
                        decisionHandler(.allow)
                    }
                }
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url else {
            logger.info("navigationResponse cancelled: missing url token=\(self.loadToken.uuidString, privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        guard isAllowedScheme(url) else {
            logger.info("navigationResponse cancelled: blocked scheme scheme=\(url.scheme ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        if isBlockedIPAddressHost(url.host) {
            decisionHandler(.cancel)
            logger.error("navigationResponse blocked host=\(url.host ?? "nil", privacy: .public) url=\(url.absoluteString, privacy: .public)")
            handleFailure(.blockedIPAddressHost, detail: "navResponse")
            return
        }
        if Self.isDirectMediaMimeType(navigationResponse.response.mimeType) {
            isDirectMediaPreview = true
            updateScrollBehaviorForPreviewContent()
            syncDirectMediaPreviewHeightIfNeeded(notifyOnChange: false)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard state == .loading else { return }
        markLoadedIfNeeded()
        if isDirectMediaPreview {
            syncDirectMediaPreviewHeightIfNeeded()
            return
        }
        canLockHeight = !isHeightLocked
        if heightUpdates == 0 {
            evaluateHeightFallback()
        }
        scheduleFallbackMeasurement()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if shouldSuppressDirectMediaNavigationFailure(error) {
            logger.info("didFail navigation suppressed direct-media handoff error=\(error.localizedDescription, privacy: .public)")
            markLoadedIfNeeded()
            statusLabel.isHidden = true
            reloadButton.isHidden = true
            webContainer.isHidden = false
            syncDirectMediaPreviewHeightIfNeeded()
            return
        }
        if isIgnorableNavigationError(error) {
            // #36: No silent failures. Even "ignorable" navigation errors must surface to the user,
            // but keep the preview visible so WebKit can continue if this was a transient cancel.
            logger.info("didFail navigation (non-fatal) error=\(error.localizedDescription, privacy: .public)")
            let nsError = error as NSError
            showNonFatalError("Preview error: \(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)")
            return
        }
        logger.error("didFail navigation error=\(error.localizedDescription, privacy: .public)")
        let nsError = error as NSError
        handleFailure(.navigationError, detail: "\(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if shouldSuppressDirectMediaNavigationFailure(error) {
            logger.info("didFailProvisionalNavigation suppressed direct-media handoff error=\(error.localizedDescription, privacy: .public)")
            markLoadedIfNeeded()
            statusLabel.isHidden = true
            reloadButton.isHidden = true
            webContainer.isHidden = false
            syncDirectMediaPreviewHeightIfNeeded()
            return
        }
        if isIgnorableNavigationError(error) {
            // #36: No silent failures. Even "ignorable" provisional errors must surface.
            logger.info("didFailProvisionalNavigation (non-fatal) error=\(error.localizedDescription, privacy: .public)")
            let nsError = error as NSError
            showNonFatalError("Preview error: \(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)")
            return
        }
        logger.error("didFailProvisionalNavigation error=\(error.localizedDescription, privacy: .public)")
        let nsError = error as NSError
        handleFailure(.provisionalNavigationError, detail: "\(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)")
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer == webView.scrollView.panGestureRecognizer
    }

    // MARK: - Height Observer

    private func configureHeightObserver() {
        removeHeightObserver()
        let token = loadToken.uuidString
        let handler = "linkPreviewHeight_\(token)"
        handlerName = handler
        handlerRegistered = true
        webView.configuration.userContentController.add(self, name: handler)

        let scriptSource = """
        (function(){
          var handler = '\(handler)';
          var token = '\(token)';
          var store = window.__clawlineLinkPreviewObservers || (window.__clawlineLinkPreviewObservers = {});
          function contentBottom(){
            try {
              var body = document.body;
              if (!body) { return 0; }
              var maxBottom = 0;

              // Prefer measuring real rendered content (text nodes / replaced elements) rather than
              // container boxes, because many pages set full-height wrappers that would force
              // element.getBoundingClientRect().bottom to be viewport-height even for short pages.

              // 4 == NodeFilter.SHOW_TEXT
              var textWalker = document.createTreeWalker(body, 4, null);
              var textCount = 0;
              while (textWalker.nextNode()) {
                var node = textWalker.currentNode;
                if (!node || !node.textContent) { continue; }
                if (!node.textContent.trim()) { continue; }
                var r = document.createRange();
                r.selectNodeContents(node);
                var rect = r.getBoundingClientRect();
                var bottom = (rect && rect.bottom) ? rect.bottom : 0;
                if (bottom > maxBottom) { maxBottom = bottom; }
                textCount++;
                if (textCount > 4000) { break; }
              }

              // 1 == NodeFilter.SHOW_ELEMENT
              var elementWalker = document.createTreeWalker(body, 1, null);
              var elementCount = 0;
              while (elementWalker.nextNode()) {
                var el = elementWalker.currentNode;
                if (!el || !el.getBoundingClientRect) { continue; }
                var tag = (el.tagName || '').toUpperCase();
                if (tag === 'IMG' || tag === 'VIDEO' || tag === 'IFRAME' || tag === 'CANVAS' || tag === 'SVG') {
                  var eRect = el.getBoundingClientRect();
                  var eBottom = (eRect && eRect.bottom) ? eRect.bottom : 0;
                  if (eBottom > maxBottom) { maxBottom = eBottom; }
                }
                elementCount++;
                if (elementCount > 2500) { break; }
              }

              // Convert viewport-relative bottom to a document-height estimate.
              var scrollY = (window.scrollY || 0);
              return Math.max(0, maxBottom + scrollY);
            } catch(e) {
              return 0;
            }
          }
          function postHeight(){
            try {
              var body = document.body;
              if (!body) { return; }
              // scrollHeight bottoms out at viewport height; measure rendered content extents first,
              // then fall back to scrollHeight if the document has no measurable content.
              var bottom = contentBottom();
              var scrollH = Math.max(body.scrollHeight || 0, (document.documentElement && document.documentElement.scrollHeight) || 0);
              var height = bottom > 0 ? bottom : scrollH;
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
                window.webkit.messageHandlers[handler].postMessage({token: token, height: height});
              }
            } catch(e) {}
          }
          function attach(){
            if (typeof ResizeObserver !== 'undefined') {
              var target = document.body || document.documentElement;
              if (!target) { return; }
              var obs = new ResizeObserver(function(){ postHeight(); });
              obs.observe(target);
              store[handler] = obs;
              postHeight();
            } else {
              postHeight();
            }
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', attach);
          } else {
            attach();
          }
        })();
        """
        let script = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)
    }

    private func removeHeightObserver() {
        disconnectHeightObserver()
        webView.configuration.userContentController.removeAllUserScripts()
        if let handlerName, handlerRegistered {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        }
        handlerRegistered = false
        handlerName = nil
    }

    private func disconnectHeightObserver() {
        guard let handlerName else { return }
        let js = """
        (function(){
          var store = window.__clawlineLinkPreviewObservers;
          if (store && store['\(handlerName)']) {
            store['\(handlerName)'].disconnect();
            delete store['\(handlerName)'];
          }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Helpers

    private func isAllowedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isDirectMediaPreviewURL(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8", "webm"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isDirectMediaMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        let normalized = mimeType.lowercased()
        return normalized.hasPrefix("video/")
            || normalized == "application/vnd.apple.mpegurl"
            || normalized == "application/x-mpegurl"
    }

    static func preferredDirectMediaHeight(for width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard width > 1 else { return max(44, maxHeight) }
        let aspectHeight = floor(width * 9 / 16)
        return max(120, min(maxHeight, aspectHeight))
    }

    static func isPluginHandledLoadNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == WKErrorDomain || nsError.domain == "WebKitErrorDomain")
            && nsError.code == 204
    }

    private func updateScrollBehaviorForPreviewContent() {
        if isDirectMediaPreview {
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.showsVerticalScrollIndicator = false
            webView.scrollView.alwaysBounceVertical = false
            return
        }
        webView.scrollView.isScrollEnabled = true
    }

    private func syncDirectMediaPreviewHeightIfNeeded(notifyOnChange: Bool = true) {
        guard isDirectMediaPreview else { return }
        let width = max(bounds.width, webContainer.bounds.width)
        guard width > 1 else { return }
        let desiredHeight = Self.preferredDirectMediaHeight(for: width, maxHeight: maxHeight)
        if abs(webViewHeightConstraint.constant - desiredHeight) > 1 {
            webViewHeightConstraint.constant = desiredHeight
            invalidateIntrinsicContentSize()
            if notifyOnChange {
                onHeightChange?()
            }
        }
        if let configuredURLKey {
            Self.heightCache.setObject(NSNumber(value: Double(desiredHeight)), forKey: configuredURLKey as NSString)
        }
    }

    private func shouldSuppressDirectMediaNavigationFailure(_ error: Error) -> Bool {
        isDirectMediaPreview && Self.isPluginHandledLoadNavigationError(error)
    }

    private func isBlockedIPAddressHost(_ host: String?) -> Bool {
        // Policy: show everything (match browser behavior). Do not block local/LAN/Tailscale hosts.
        return false
    }

    private enum HostResolutionResult {
        case allowed(Set<String>)
        case blocked
    }

    private func resolveHost(_ host: String) -> HostResolutionResult {
        var resolved: Set<String> = []
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &hints, &res) == 0, let res {
            defer { freeaddrinfo(res) }
            var ptr: UnsafeMutablePointer<addrinfo>? = res
            while let current = ptr {
                let addr = current.pointee.ai_addr
                if current.pointee.ai_family == AF_INET, let addr {
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var addr4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if inet_ntop(AF_INET, &addr4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buffer)
                        resolved.insert(ip)
                    }
                } else if current.pointee.ai_family == AF_INET6, let addr {
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var addr6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if inet_ntop(AF_INET6, &addr6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buffer)
                        resolved.insert(ip)
                    }
                }
                ptr = current.pointee.ai_next
            }
        }
        return .allowed(resolved)
    }

    private func isActuallyVisible() -> Bool {
        guard let window else { return false }
        if isHidden || alpha < 0.01 { return false }
        let frameInWindow = convert(bounds, to: window)
        return frameInWindow.intersects(window.bounds)
    }

    private func isPrivateIPAddress(_ host: String) -> Bool {
        // Policy: show everything (match browser behavior). Do not treat private IPs / localhost as blocked.
        return false
    }

    private func isPrivateIPv4(_ ip: UInt32) -> Bool {
        if (ip & 0xFF000000) == 0x0A000000 { return true }          // 10.0.0.0/8
        if (ip & 0xFFF00000) == 0xAC100000 { return true }          // 172.16.0.0/12
        if (ip & 0xFFFF0000) == 0xC0A80000 { return true }          // 192.168.0.0/16
        if (ip & 0xFF000000) == 0x7F000000 { return true }          // 127.0.0.0/8
        if (ip & 0xFFFF0000) == 0xA9FE0000 { return true }          // 169.254.0.0/16
        if (ip & 0xFF000000) == 0x00000000 { return true }          // 0.0.0.0/8
        if (ip & 0xFFC00000) == 0x64400000 { return true }          // 100.64.0.0/10
        return false
    }

    private func isIgnorableNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        if (nsError.domain == WKErrorDomain || nsError.domain == "WebKitErrorDomain"),
           nsError.code == 102 {
            return true
        }
        return false
    }
}

// MARK: - WKScriptMessageHandler

extension LinkPreviewView: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handlerName else { return }
        guard message.name == handlerName else { return }
        guard let body = message.body as? [String: Any],
              let token = body["token"] as? String,
              token == loadToken.uuidString else { return }
        guard let heightValue = body["height"] as? Double, heightValue.isFinite else { return }
        guard heightValue >= 1 && heightValue <= 10000 else { return }

        heightUpdates += 1
        applyMeasuredHeight(heightValue)
        if heightUpdates >= 2 {
            removeHeightObserver()
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

private extension LinkPreviewView {
    func logCancel(_ reason: CancelReason) {
        let urlString = self.currentURL?.absoluteString ?? "nil"
        let elapsed = loadElapsedMsString()
        self.logger.info("cancel reason=\(reason.rawValue, privacy: .public) url=\(urlString, privacy: .public) elapsedMs=\(elapsed, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public)")
    }

    func logFailure(_ reason: FailureReason, detail: String?) {
        let urlString = self.currentURL?.absoluteString ?? "nil"
        let elapsed = loadElapsedMsString()
        if let detail, !detail.isEmpty {
            self.logger.error("failure reason=\(reason.rawValue, privacy: .public) url=\(urlString, privacy: .public) elapsedMs=\(elapsed, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public) detail=\(detail, privacy: .public)")
        } else {
            self.logger.error("failure reason=\(reason.rawValue, privacy: .public) url=\(urlString, privacy: .public) elapsedMs=\(elapsed, privacy: .public) token=\(self.loadToken.uuidString, privacy: .public)")
        }
    }

    func loadElapsedMsString() -> String {
        guard let loadStartedAt = self.loadStartedAt else { return "nil" }
        let elapsedMs = Int(((CACurrentMediaTime() - loadStartedAt) * 1000.0).rounded())
        return String(elapsedMs)
    }
}

private extension UIColor {
    func darkened(by amount: CGFloat) -> UIColor {
        let clamped = max(0, min(1, amount))
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            return UIColor(hue: h, saturation: s, brightness: max(0, b - clamped), alpha: a)
        }
        var w: CGFloat = 0
        if getWhite(&w, alpha: &a) {
            return UIColor(white: max(0, w - clamped), alpha: a)
        }
        // Fallback: apply a subtle black overlay.
        return withAlphaComponent(1).withAlphaComponent(a)
    }
}

// Superellipse helpers are implemented in MaskedWebContainerView.

#if canImport(SwiftUI)
struct LinkPreviewRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LinkPreviewView {
        let view = LinkPreviewView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: LinkPreviewView, context: Context) {
        uiView.configure(url: url)
    }
}
#endif
