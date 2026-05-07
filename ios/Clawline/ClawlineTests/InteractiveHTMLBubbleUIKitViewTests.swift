//
//  InteractiveHTMLBubbleUIKitViewTests.swift
//  ClawlineTests
//
//  Created by Codex on 2/13/26.
//

import Foundation
import Testing
import UIKit
import WebKit
@testable import Clawline

@MainActor
struct InteractiveHTMLBubbleUIKitViewTests {
    @Test("Interactive bubble waits for non-zero width before loading and renders visible content")
    func interactiveBubbleWaitsForWidthAndRenders() async throws {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            Issue.record("No UIWindowScene available for interactive bubble test")
            return
        }

        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        host.view.frame = window.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }

        try await warmUpInteractiveWebKit(in: host.view)

        let bubble = InteractiveHTMLBubbleUIKitView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(bubble)
        let widthConstraint = bubble.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 16),
            bubble.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 16),
            bubble.heightAnchor.constraint(equalToConstant: 44),
            widthConstraint
        ])
        host.view.layoutIfNeeded()

        bubble.configure(
            descriptor: viewportDrivenDescriptor(),
            messageId: "msg-width-gated",
            isDark: false
        )

        // Give the configure path time to run while width remains zero.
        try await Task.sleep(forDuration: .milliseconds(150))
        #expect(firstWebView(in: bubble) == nil)

        widthConstraint.constant = 320
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        try await waitFor(timeout: .seconds(3), poll: .milliseconds(25)) {
            guard let webView = firstWebView(in: bubble) else { return false }
            return webView.alpha >= 0.99 && heightConstraintConstant(for: webView) > 100
        }

        guard let webView = firstWebView(in: bubble) else {
            Issue.record("Expected WKWebView after width became non-zero")
            return
        }

        let renderedText = try await evaluateString(webView: webView, js: "document.body.innerText || ''")
        #expect(renderedText.contains("Visible Content"))

        let viewportMeta = try await evaluateString(
            webView: webView,
            js: "(() => { const m = document.querySelector('meta[name=\"viewport\"]'); return m ? (m.getAttribute('content') || '') : ''; })()"
        )
        #expect(viewportMeta.contains("width=device-width"))

        let textSizeAdjust = try await evaluateString(
            webView: webView,
            js: "getComputedStyle(document.body).webkitTextSizeAdjust || ''"
        )
        #expect(textSizeAdjust.contains("100"))
    }

    @Test("Interactive bubble renders visible error for empty HTML after descriptor gates")
    func interactiveBubbleShowsErrorForEmptyHTML() async throws {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            Issue.record("No UIWindowScene available for interactive bubble test")
            return
        }

        let bubble = InteractiveHTMLBubbleUIKitView()
        bubble.configure(
            descriptor: InteractiveHTMLDescriptor(version: 1, html: "   \n", metadata: nil),
            messageId: "msg-empty-html",
            isDark: false
        )

        #expect(visibleLabelText(in: bubble)?.contains("Interactive content could not be displayed") == true)
        #expect(bubble.systemLayoutSizeFitting(CGSize(width: 320, height: 0)).height >= 44)

        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        host.view.frame = window.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 16),
            stack.widthAnchor.constraint(equalToConstant: 320)
        ])
        stack.addArrangedSubview(bubble)
        host.view.layoutIfNeeded()
        try await Task.sleep(forDuration: .milliseconds(150))

        #expect(visibleLabelText(in: bubble)?.contains("Interactive content could not be displayed") == true)
        #expect(bubble.bounds.height >= 44)
        #expect(firstWebView(in: bubble) == nil)
    }
}

@MainActor
private func warmUpInteractiveWebKit(in container: UIView) async throws {
    let warmup = InteractiveHTMLBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    container.addSubview(warmup)
    warmup.configure(descriptor: viewportDrivenDescriptor(), messageId: "warmup", isDark: false)

    try await waitFor(timeout: .seconds(3), poll: .milliseconds(25)) {
        firstWebView(in: warmup) != nil
    }

    warmup.prepareForReuse()
    warmup.removeFromSuperview()
}

private func viewportDrivenDescriptor() -> InteractiveHTMLDescriptor {
    let html = """
    <!doctype html>
    <html>
    <body style="margin:0;">
      <div style="height:calc(100vw * 0.6);background:#0A84FF;color:#FFFFFF;display:flex;align-items:center;justify-content:center;font-size:20px;font-weight:600;">
        Visible Content
      </div>
    </body>
    </html>
    """

    return InteractiveHTMLDescriptor(
        version: 1,
        html: html,
        metadata: .init(title: nil, height: .auto, maxHeight: 400, backgroundColor: nil)
    )
}

@MainActor
private func waitFor(
    timeout: Duration,
    poll: Duration,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while !condition() {
        if clock.now >= deadline {
            struct Timeout: Error {}
            throw Timeout()
        }
        try await Task.sleep(forDuration: poll)
    }
}

@MainActor
private func firstWebView(in view: UIView) -> WKWebView? {
    if let webView = view as? WKWebView {
        return webView
    }
    for child in view.subviews {
        if let webView = firstWebView(in: child) {
            return webView
        }
    }
    return nil
}

@MainActor
private func visibleLabelText(in view: UIView) -> String? {
    if let label = view as? UILabel, !label.isHidden, let text = label.text, !text.isEmpty {
        return text
    }
    for child in view.subviews {
        if let text = visibleLabelText(in: child) {
            return text
        }
    }
    return nil
}

@MainActor
private func heightConstraintConstant(for webView: WKWebView) -> CGFloat {
    webView.constraints.first(where: { constraint in
        constraint.firstAttribute == .height
            && constraint.secondItem == nil
            && constraint.relation == .equal
    })?.constant ?? 0
}

@MainActor
private func evaluateString(webView: WKWebView, js: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(js) { value, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            continuation.resume(returning: (value as? String) ?? "")
        }
    }
}
