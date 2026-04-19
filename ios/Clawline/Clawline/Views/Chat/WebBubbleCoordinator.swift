//
//  WebBubbleCoordinator.swift
//  Clawline
//
//  #57: Popup/new-window handling in embedded web previews: popup-as-bubble.
//

import Foundation
import WebKit

@MainActor
protocol WebBubbleCoordinating: AnyObject {
    func register(webView: WKWebView, ownerItemId: String)
    func unregister(webView: WKWebView)

    func createPopupWebView(
        originatingWebView: WKWebView,
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView?

    func dismissWebBubble(id: String)
    func dismissBubble(for webView: WKWebView)

    func webBubbleItem(for id: String) -> WebBubbleItem?
    func webView(for id: String) -> WKWebView?
}

struct WebBubbleItem: Hashable {
    let id: String
    let createdAt: Date
    let stream: ChatStream
    let parentItemId: String?
    let initialURL: URL?
    let isPopup: Bool
    var title: String?
}

@MainActor
final class WebBubbleCoordinator: WebBubbleCoordinating {
    private var itemsById: [String: WebBubbleItem] = [:]
    private var itemsInOrder: [String] = []
    private var webViewsById: [String: WKWebView] = [:]
    private var delegatesById: [String: WebBubbleWebViewDelegate] = [:]

    private var ownerItemIdByWebViewId: [ObjectIdentifier: String] = [:]
    private var bubbleIdByWebViewId: [ObjectIdentifier: String] = [:]

    var onItemsChanged: (() -> Void)?
    var onReconfigureItem: ((String) -> Void)?
    var onScrollToItem: ((String) -> Void)?

    var currentStream: ChatStream = .personal

    func items(for stream: ChatStream) -> [WebBubbleItem] {
        itemsInOrder.compactMap { id in
            guard let item = itemsById[id], item.stream == stream else { return nil }
            return item
        }
    }

    func webBubbleItem(for id: String) -> WebBubbleItem? {
        itemsById[id]
    }

    func webView(for id: String) -> WKWebView? {
        webViewsById[id]
    }

    func register(webView: WKWebView, ownerItemId: String) {
        ownerItemIdByWebViewId[ObjectIdentifier(webView)] = ownerItemId
    }

    func unregister(webView: WKWebView) {
        ownerItemIdByWebViewId.removeValue(forKey: ObjectIdentifier(webView))
        // If this was a bubble web view, it will be removed via dismissal. For previews, this is enough.
    }

    func createPopupWebView(
        originatingWebView: WKWebView,
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let parentItemId = ownerItemIdByWebViewId[ObjectIdentifier(originatingWebView)]

        let bubbleId = "web_\(UUID().uuidString)"
        let initialURL = navigationAction.request.url
        let title = initialURL?.host

        // Fresh config: enforce persistent store, then copy safe settings.
        let popupConfig = WKWebViewConfiguration()
        popupConfig.websiteDataStore = WebSessionSharedResources.shared.websiteDataStore
        popupConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        popupConfig.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Preserve common WebKit semantics where safe.
        popupConfig.allowsInlineMediaPlayback = configuration.allowsInlineMediaPlayback
        popupConfig.mediaTypesRequiringUserActionForPlayback = configuration.mediaTypesRequiringUserActionForPlayback

        let popupWebView = WKWebView(frame: .zero, configuration: popupConfig)
        popupWebView.allowsLinkPreview = false
        popupWebView.isOpaque = false
        popupWebView.backgroundColor = .clear

        let delegate = WebBubbleWebViewDelegate(coordinator: self, ownerItemId: bubbleId)
        popupWebView.navigationDelegate = delegate
        popupWebView.uiDelegate = delegate

        let item = WebBubbleItem(
            id: bubbleId,
            createdAt: Date(),
            stream: currentStream,
            parentItemId: parentItemId,
            initialURL: initialURL,
            isPopup: true,
            title: title
        )

        itemsById[bubbleId] = item
        itemsInOrder.append(bubbleId)
        webViewsById[bubbleId] = popupWebView
        delegatesById[bubbleId] = delegate

        bubbleIdByWebViewId[ObjectIdentifier(popupWebView)] = bubbleId
        ownerItemIdByWebViewId[ObjectIdentifier(popupWebView)] = bubbleId

        // Snapshot apply can be expensive. Schedule it after returning the WKWebView to WebKit.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onItemsChanged?()
            self.onScrollToItem?(bubbleId)
        }

        return popupWebView
    }

    func dismissWebBubble(id: String) {
        guard let webView = webViewsById[id] else {
            itemsById.removeValue(forKey: id)
            itemsInOrder.removeAll(where: { $0 == id })
            onItemsChanged?()
            return
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        webViewsById.removeValue(forKey: id)
        delegatesById.removeValue(forKey: id)
        itemsById.removeValue(forKey: id)
        itemsInOrder.removeAll(where: { $0 == id })

        bubbleIdByWebViewId.removeValue(forKey: ObjectIdentifier(webView))
        ownerItemIdByWebViewId.removeValue(forKey: ObjectIdentifier(webView))

        onItemsChanged?()
    }

    func dismissBubble(for webView: WKWebView) {
        guard let id = bubbleIdByWebViewId[ObjectIdentifier(webView)] else { return }
        dismissWebBubble(id: id)
    }

    fileprivate func updateTitle(for bubbleId: String, title: String?) {
        guard var item = itemsById[bubbleId] else { return }
        item.title = title
        itemsById[bubbleId] = item
        onReconfigureItem?(bubbleId)
    }
}

@MainActor
final class WebBubbleWebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var coordinator: WebBubbleCoordinator?
    private let ownerItemId: String
    private var redirectCount: Int = 0

    init(coordinator: WebBubbleCoordinator, ownerItemId: String) {
        self.coordinator = coordinator
        self.ownerItemId = ownerItemId
        super.init()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard Self.isAllowedScheme(url) else {
            decisionHandler(.cancel)
            return
        }

        let navType = navigationAction.navigationType
        if navType == .linkActivated || navType == .formSubmitted {
            redirectCount = 0
        } else if navType == .other || navType == .reload || navType == .backForward {
            redirectCount = max(1, redirectCount + 1)
            if redirectCount > 10 {
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url else {
            decisionHandler(.cancel)
            return
        }
        guard Self.isAllowedScheme(url) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator?.updateTitle(for: ownerItemId, title: webView.title)
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let coordinator else { return nil }
        coordinator.register(webView: webView, ownerItemId: ownerItemId)
        return coordinator.createPopupWebView(
            originatingWebView: webView,
            configuration: configuration,
            navigationAction: navigationAction,
            windowFeatures: windowFeatures
        )
    }

    func webViewDidClose(_ webView: WKWebView) {
        coordinator?.dismissBubble(for: webView)
    }

    private static func isAllowedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "about" || scheme == "blob"
    }
}
