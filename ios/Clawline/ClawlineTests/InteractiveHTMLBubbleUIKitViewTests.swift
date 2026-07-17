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
@Suite(.serialized)
struct InteractiveHTMLBubbleUIKitViewTests {
    @Test("T1377: didFinish geometry stays bound to its producer lifecycle")
    func didFinishGeometryStaysBoundToProducerLifecycle() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Clawline/Views/Chat/InteractiveHTMLBubbleUIKitView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let measureStart = try #require(lines.firstIndex(where: { $0.contains("private func measureAndReveal") }))
        let measureEnd = try #require(lines[measureStart...].firstIndex(where: { $0.contains("func webView(_ webView: WKWebView, decidePolicyFor") }))
        let measure = lines[measureStart..<measureEnd].joined(separator: "\n")

        #expect(measure.contains("let nonce = configureNonce"))
        #expect(measure.contains("let generation = documentGeneration"))
        #expect(measure.contains("guard self.configureNonce == nonce, self.webView === webView else { return }"))
        #expect(measure.contains("guard self.documentGeneration == generation else { return }"))
        #expect(measure.contains("guard !self.heightLocked else { return }"))

        #expect(contents.contains("guard activeUserContentController === userContentController else { return }"))
        #expect(contents.contains("activeUserContentController = nil"))
        #expect(contents.contains("self.attach(webView: replacement)"))
    }

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

    @Test("Interactive bubble reloads once after web content process termination, then shows permanent crash error")
    func interactiveBubbleReloadsOnceAfterWebContentProcessTermination() async throws {
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
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 16),
            bubble.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 16),
            bubble.widthAnchor.constraint(equalToConstant: 320),
            bubble.heightAnchor.constraint(equalToConstant: 44)
        ])
        host.view.layoutIfNeeded()

        bubble.configure(
            descriptor: viewportDrivenDescriptor(),
            messageId: "msg-crash-reload",
            isDark: false
        )

        try await waitFor(timeout: .seconds(3), poll: .milliseconds(25)) {
            guard let webView = firstWebView(in: bubble) else { return false }
            return webView.alpha >= 0.99
        }

        guard let webView = firstWebView(in: bubble) else {
            Issue.record("Expected WKWebView before process termination")
            return
        }
        #expect(heightConstraintConstant(for: webView) > 100)

        try await evaluateNoResult(
            webView: webView,
            js: "setTimeout(function(){ window.webkit.messageHandlers.clawline.postMessage({action:'_resize',height:320}); }, 100); 0"
        )

        bubble.webViewWebContentProcessDidTerminate(webView)
        #expect(visibleLabelText(in: bubble)?.contains("Content crashed") != true)

        try await waitFor(timeout: .seconds(3), poll: .milliseconds(25)) {
            guard let replacement = firstWebView(in: bubble) else { return false }
            return replacement !== webView && replacement.alpha >= 0.99
        }
        let replacement = try #require(firstWebView(in: bubble))
        try await Task.sleep(forDuration: .milliseconds(150))
        #expect(abs(heightConstraintConstant(for: replacement) - 320) > 0.5)
        let reloadedText = try await evaluateString(webView: replacement, js: "document.body.innerText || ''")
        #expect(reloadedText.contains("Visible Content"))

        try await evaluateNoResult(
            webView: replacement,
            js: "window.webkit.messageHandlers.clawline.postMessage({action:'_resize',height:260}); 0"
        )
        try await waitFor(timeout: .seconds(1), poll: .milliseconds(25)) {
            abs(heightConstraintConstant(for: replacement) - 260) <= 0.5
        }

        bubble.webViewWebContentProcessDidTerminate(replacement)
        #expect(firstWebView(in: bubble) == nil)
        #expect(visibleLabelText(in: bubble)?.contains("Content crashed") == true)
    }

    @Test("T1377: Interactive HTML commits didFinish geometry and one explicit resize")
    func interactiveBubbleCommitsOneProducerResize() async throws {
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
        defer { window.isHidden = true }

        try await warmUpInteractiveWebKit(in: host.view)

        let bubble = InteractiveHTMLBubbleUIKitView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 16),
            bubble.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 16),
            bubble.widthAnchor.constraint(equalToConstant: 320)
        ])
        host.view.layoutIfNeeded()

        var observedRevisions: [Int] = []
        bubble.onHeightChange = {
            observedRevisions.append(bubble.geometryRevision)
        }
        bubble.configure(
            descriptor: viewportDrivenDescriptor(),
            messageId: "msg-one-resize",
            isDark: false
        )

        try await waitFor(timeout: .seconds(3), poll: .milliseconds(25)) {
            bubble.geometryRevision == 1 && (firstWebView(in: bubble)?.alpha ?? 0) >= 0.99
        }
        let webView = try #require(firstWebView(in: bubble))
        #expect(observedRevisions == [1])

        try await evaluateNoResult(
            webView: webView,
            js: "window.webkit.messageHandlers.clawline.postMessage({action:'_resize',height:260}); 0"
        )
        try await waitFor(timeout: .seconds(1), poll: .milliseconds(25)) {
            bubble.geometryRevision == 2 && abs(heightConstraintConstant(for: webView) - 260) <= 0.5
        }
        #expect(observedRevisions == [1, 2])

        try await evaluateNoResult(
            webView: webView,
            js: "window.webkit.messageHandlers.clawline.postMessage({action:'_resize',height:320}); 0"
        )
        try await Task.sleep(forDuration: .milliseconds(150))
        #expect(bubble.geometryRevision == 2)
        #expect(abs(heightConstraintConstant(for: webView) - 260) <= 0.5)
        #expect(observedRevisions == [1, 2])
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

@MainActor
private func evaluateNoResult(webView: WKWebView, js: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            continuation.resume()
        }
    }
}
