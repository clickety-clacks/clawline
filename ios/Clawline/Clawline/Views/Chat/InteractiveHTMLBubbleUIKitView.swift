//
//  InteractiveHTMLBubbleUIKitView.swift
//  Clawline
//
//  Created by Codex on 2/9/26.
//

import OSLog
import UIKit
import WebKit

final class InteractiveHTMLBubbleUIKitView: UIView {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "InteractiveHTML")

    private let placeholder = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()
    private let summaryLabel = UILabel()

    private var webView: WKWebView?
    private var webViewHeightConstraint: NSLayoutConstraint?

    private var descriptor: InteractiveHTMLDescriptor?
    private var sourceMessageId: String?
    private var configureNonce = UUID()
    private var pendingStart = false
    private var pendingIsDark = false

    private var isInitialLoadInProgress = false
    private var heightLocked = false
    private var resizeUsed = false

    private var callbackWindowStart: CFAbsoluteTime = 0
    private var callbackWindowCount: Int = 0

    var onHeightChange: (() -> Void)?
    var onCallback: ((String, JSONValue?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        placeholder.hidesWhenStopped = true

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.numberOfLines = 0
        errorLabel.font = .systemFont(ofSize: 14, weight: .medium)
        errorLabel.textAlignment = .center
        errorLabel.textColor = .secondaryLabel
        errorLabel.isHidden = true
        addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.numberOfLines = 0
        summaryLabel.font = .systemFont(ofSize: 16, weight: .regular)
        summaryLabel.textColor = .label
        summaryLabel.isHidden = true
        addSubview(summaryLabel)
        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            summaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            summaryLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])

        placeholder.startAnimating()
    }

    func prepareForReuse() {
        configureNonce = UUID()
        pendingStart = false
        descriptor = nil
        sourceMessageId = nil
        isInitialLoadInProgress = false
        heightLocked = false
        resizeUsed = false
        callbackWindowStart = 0
        callbackWindowCount = 0
        summaryLabel.isHidden = true
        summaryLabel.text = nil
        errorLabel.isHidden = true
        errorLabel.text = nil
        placeholder.startAnimating()
        teardownWebView()
        onHeightChange = nil
        onCallback = nil
    }

    func configure(descriptor: InteractiveHTMLDescriptor, messageId: String, isDark: Bool) {
        let nonce = UUID()
        configureNonce = nonce
        self.descriptor = descriptor
        self.sourceMessageId = messageId
        pendingStart = true
        pendingIsDark = isDark
        self.isInitialLoadInProgress = true
        self.heightLocked = false
        self.resizeUsed = false
        self.summaryLabel.isHidden = true
        self.errorLabel.isHidden = true
        self.placeholder.startAnimating()

        guard descriptor.version == 1 else {
            showError("Update Clawline to view this content.")
            return
        }

        let htmlBytes = descriptor.html.lengthOfBytes(using: .utf8)
        if htmlBytes > 256 * 1024 {
            showError("Interactive content too large to render.")
            return
        }

        startIfPossible(nonce: nonce)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startIfPossible(nonce: configureNonce)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if pendingStart {
            startIfPossible(nonce: configureNonce)
        }
    }

    private func startIfPossible(nonce: UUID) {
        guard pendingStart else { return }
        // Avoid creating WKWebView during offscreen sizing passes; only load when attached to a window.
        guard window != nil else { return }
        // Wait for layout to provide a real width. Loading at width=0 can produce bogus
        // measurements and invisible content for viewport-relative layouts.
        guard bounds.width > 1 else { return }
        pendingStart = false

        InteractiveHTMLWebKit.shared.makeWebView(handler: self) { [weak self] webView in
            guard let self else { return }
            guard self.configureNonce == nonce else { return }
            self.attach(webView: webView)
            self.loadHTML(isDark: self.pendingIsDark)
        }
    }

    private func attach(webView: WKWebView) {
        teardownWebView()
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        webView.alpha = 0

        // Keep the web view constrained to the bubble content width.
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Height is locked once measured; initial minimum keeps a tappable target.
        let height = webView.heightAnchor.constraint(equalToConstant: 44)
        height.priority = .required
        height.isActive = true
        webViewHeightConstraint = height
    }

    private func teardownWebView() {
        webViewHeightConstraint?.isActive = false
        webViewHeightConstraint = nil
        if let webView {
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        webView = nil
    }

    private func showError(_ message: String) {
        placeholder.stopAnimating()
        errorLabel.isHidden = false
        errorLabel.text = message
        teardownWebView()
    }

    private func loadHTML(isDark: Bool) {
        guard let descriptor, let webView else { return }
        let maxHeight = descriptor.metadata?.maxHeight ?? 400
        let fixedHeight: CGFloat? = {
            guard let height = descriptor.metadata?.height else { return nil }
            switch height {
            case .auto:
                return nil
            case .fixed(let value):
                return value
            }
        }()

        // If a fixed height is provided, lock immediately and allow internal scrolling.
        if let fixedHeight {
            lockHeight(min(fixedHeight, maxHeight), maxHeight: maxHeight)
        }

        let html = InteractiveHTMLHTMLInjector.inject(
            rawHTML: descriptor.html,
            isDark: isDark
        )

        // Base URL is nil by design (T031): no origin, no credential leakage, no file access.
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func lockHeight(_ height: CGFloat, maxHeight: CGFloat) {
        guard let webViewHeightConstraint else { return }
        let clamped = max(44, min(height, maxHeight))
        if abs(webViewHeightConstraint.constant - clamped) <= 0.5 {
            return
        }
        webViewHeightConstraint.constant = clamped
        onHeightChange?()
        updateScrollability(maxHeight: maxHeight, lockedHeight: clamped)
    }

    private func updateScrollability(maxHeight: CGFloat, lockedHeight: CGFloat) {
        guard let webView else { return }
        // Allow internal scroll only when we are height-capped.
        webView.scrollView.isScrollEnabled = lockedHeight >= maxHeight - 0.5
        webView.scrollView.alwaysBounceVertical = webView.scrollView.isScrollEnabled
    }

    private func acceptCallback() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if callbackWindowStart == 0 || now - callbackWindowStart >= 1.0 {
            callbackWindowStart = now
            callbackWindowCount = 0
        }
        if callbackWindowCount >= 10 {
            return false
        }
        callbackWindowCount += 1
        return true
    }
}

// MARK: - WebKit plumbing (isolated from LinkPreviewView)

private final class InteractiveHTMLWebKit: NSObject {
    static let shared = InteractiveHTMLWebKit()
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "InteractiveHTMLWebKit")

    private var cachedRuleList: WKContentRuleList?
    private var compiling = false
    private var pending: [() -> Void] = []

    func makeWebView(handler: WKScriptMessageHandler, ready: @escaping (WKWebView) -> Void) {
        // Compile content rule list once; use for all interactive bubbles (but not shared with any other feature).
        if let cachedRuleList {
            ready(makeWebView(ruleList: cachedRuleList, handler: handler))
            return
        }

        pending.append { [weak self] in
            guard let self else { return }
            ready(self.makeWebView(ruleList: self.cachedRuleList, handler: handler))
        }

        if compiling { return }
        compiling = true

        let rules = """
        [{
          "trigger": { "url-filter": ".*" },
          "action": { "type": "block" }
        }]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "co.clicketyclacks.clawline.interactivehtml.blockall", encodedContentRuleList: rules) { [weak self] ruleList, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.compiling = false
                if let error {
                    self.logger.error("content_rule_list_compile_failed error=\(error.localizedDescription, privacy: .public)")
                }
                if let ruleList {
                    self.cachedRuleList = ruleList
                }
                // Recreate pending web views with the compiled rule list. We intentionally don't
                // refactor existing WKWebView code paths; this feature is isolated (T031).
                let completions = self.pending
                self.pending = []
                for completion in completions {
                    completion()
                }
            }
        }
    }

    private func makeWebView(ruleList: WKContentRuleList?, handler: WKScriptMessageHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let userContent = WKUserContentController()
        userContent.removeAllUserScripts()
        userContent.add(handler, name: "clawline")
        if let ruleList {
            userContent.add(ruleList)
        }
        configuration.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.insetsLayoutMarginsFromSafeArea = false
        webView.scrollView.insetsLayoutMarginsFromSafeArea = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 13.0, visionOS 1.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }

        // Delegates are set by the owning view instance.
        return webView
    }
}

// MARK: - Navigation / UI delegation

extension InteractiveHTMLBubbleUIKitView: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        placeholder.stopAnimating()

        guard let descriptor else { return }
        let maxHeight = descriptor.metadata?.maxHeight ?? 400

        // Respect fixed height if present (already locked).
        if case .fixed = descriptor.metadata?.height {
            isInitialLoadInProgress = false
            heightLocked = true
            webView.alpha = 1
            return
        }

        guard !heightLocked else { return }
        measureAndReveal(maxHeight: maxHeight)
    }

    private func measureAndReveal(maxHeight: CGFloat) {
        guard let webView else { return }
        let js = "Math.ceil(document.body.scrollHeight)"
        webView.evaluateJavaScript(js) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.isInitialLoadInProgress = false
                let id = self.sourceMessageId ?? ""
                self.logger.error("measure_failed messageId=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.showError("Content failed to render.")
                return
            }
            let measured: CGFloat? = {
                if let n = value as? NSNumber { return CGFloat(truncating: n) }
                if let d = value as? Double { return CGFloat(d) }
                return nil
            }()
            guard let measured else {
                self.isInitialLoadInProgress = false
                self.showError("Content failed to render.")
                return
            }

            self.isInitialLoadInProgress = false
            self.heightLocked = true
            self.lockHeight(min(measured, maxHeight), maxHeight: maxHeight)
            UIView.animate(withDuration: 0.18) {
                webView.alpha = 1
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Block all navigations except the initial HTML load. Links open externally.
        if isInitialLoadInProgress {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
            }
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // If any non-initial response is attempted, cancel.
        decisionHandler(isInitialLoadInProgress ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showError("Content crashed.")
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Suppress popups/window.open().
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - JS bridge

extension InteractiveHTMLBubbleUIKitView: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "clawline" else { return }
        guard acceptCallback() else { return }
        guard let descriptor, let sourceMessageId else { return }

        // Expected shape: { action: String, data?: any } or reserved { action:"_close", summary?: String }.
        guard let dict = message.body as? [String: Any] else {
            logger.error("invalid_bridge_payload messageId=\(sourceMessageId, privacy: .public)")
            return
        }
        guard let action = dict["action"] as? String, !action.isEmpty, action.count <= 128 else {
            logger.error("invalid_bridge_action messageId=\(sourceMessageId, privacy: .public)")
            return
        }

        if action == "_close" {
            let summary = (dict["summary"] as? String) ?? "Done."
            summaryLabel.text = String(summary.prefix(500))
            summaryLabel.isHidden = false
            teardownWebView()
            placeholder.stopAnimating()
            errorLabel.isHidden = true
            onHeightChange?()
            return
        }

        if action == "_resize" {
            guard !resizeUsed else { return }
            resizeUsed = true

            let maxHeight = descriptor.metadata?.maxHeight ?? 400
            var requested: CGFloat?
            if let data = dict["data"] as? [String: Any] {
                if let height = data["height"] as? Double { requested = CGFloat(height) }
                if let height = data["height"] as? Int { requested = CGFloat(height) }
            }
            if let height = dict["height"] as? Double { requested = CGFloat(height) }
            if let height = dict["height"] as? Int { requested = CGFloat(height) }
            guard let requested else { return }

            // One-time resize: lock again immediately.
            lockHeight(min(requested, maxHeight), maxHeight: maxHeight)
            heightLocked = true
            return
        }

        // User-defined action: send callback upstream.
        let dataValue: JSONValue? = {
            guard let raw = dict["data"] else { return nil }
            let value = JSONValue.from(any: raw)
            return value
        }()

        // Enforce payload size limit (64KB serialized JSON) for data.
        if let dataValue {
            if let encoded = try? JSONEncoder().encode(dataValue), encoded.count > 64 * 1024 {
                logger.error("callback_payload_too_large messageId=\(sourceMessageId, privacy: .public) action=\(action, privacy: .public)")
                return
            }
        }

        onCallback?(action, dataValue)
    }
}

// MARK: - HTML injection (CSP + theme variables)

private enum InteractiveHTMLHTMLInjector {
    static func inject(rawHTML: String, isDark: Bool) -> String {
        let csp = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:;">"#
        let viewport = #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
        let themeStyle = themeVariablesStyle(isDark: isDark)

        var html = rawHTML

        // Ensure there's a <head> to insert into.
        if let headRange = html.range(of: "<head>", options: [.caseInsensitive]) {
            let insertion = "\n\(viewport)\n\(csp)\n\(themeStyle)\n"
            html.insert(contentsOf: insertion, at: headRange.upperBound)
        } else if let htmlRange = html.range(of: "<html", options: [.caseInsensitive]) {
            if let tagEnd = html[htmlRange.lowerBound...].firstIndex(of: ">") {
                let insertion = "\n<head>\n\(viewport)\n\(csp)\n\(themeStyle)\n</head>\n"
                html.insert(contentsOf: insertion, at: html.index(after: tagEnd))
            } else {
                html = "<head>\n\(viewport)\n\(csp)\n\(themeStyle)\n</head>\n" + html
            }
        } else {
            html = "<head>\n\(viewport)\n\(csp)\n\(themeStyle)\n</head>\n" + html
        }

        return html
    }

    private static func themeVariablesStyle(isDark: Bool) -> String {
        let bg = isDark ? "#1a1a1a" : "#ffffff"
        let fg = isDark ? "#ffffff" : "#111111"
        let bubbleBg = isDark ? "#2a2a2a" : "#f2f2f2"
        let accent = "#007AFF"
        return """
        <style>
        :root {
          --clawline-bg: \(bg);
          --clawline-fg: \(fg);
          --clawline-accent: \(accent);
          --clawline-bubble-bg: \(bubbleBg);
          --clawline-font-family: -apple-system, system-ui;
          --clawline-font-size: 16px;
        }
        html, body {
          background: transparent;
          color: var(--clawline-fg);
          font-family: var(--clawline-font-family);
          font-size: var(--clawline-font-size);
          -webkit-text-size-adjust: 100%;
          text-size-adjust: 100%;
          margin: 0;
          padding: 0;
        }
        </style>
        """
    }
}
