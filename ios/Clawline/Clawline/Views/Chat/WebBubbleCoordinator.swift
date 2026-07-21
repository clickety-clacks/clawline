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
    private var itemIdsInOrderByStream: [ChatStream: [String]] = [:]
    private var itemIdsByParentByStream: [ChatStream: [String: [String]]] = [:]
    private var parentlessItemIdsByStream: [ChatStream: [String]] = [:]
    private var webViewsById: [String: WKWebView] = [:]
    private var delegatesById: [String: WebBubbleWebViewDelegate] = [:]

    private var ownerItemIdByWebViewId: [ObjectIdentifier: String] = [:]
    private var bubbleIdByWebViewId: [ObjectIdentifier: String] = [:]

    var onItemsChanged: (() -> Void)?
    var onReconfigureItem: ((String) -> Void)?
    var onScrollToItem: ((String) -> Void)?

    var currentStream: ChatStream = .personal

#if DEBUG
    func debugInsertItem(_ item: WebBubbleItem) {
        itemsById[item.id] = item
        itemsInOrder.append(item.id)
        itemIdsInOrderByStream[item.stream, default: []].append(item.id)
        if let parent = item.parentItemId {
            itemIdsByParentByStream[item.stream, default: [:]][parent, default: []].append(item.id)
        } else {
            parentlessItemIdsByStream[item.stream, default: []].append(item.id)
        }
    }
#endif

    func items(for stream: ChatStream) -> [WebBubbleItem] {
        itemIdsInOrderByStream[stream, default: []].compactMap { id in
            guard let item = itemsById[id], item.stream == stream else { return nil }
            return item
        }
    }

    func items(for stream: ChatStream, parentIds: Set<String>, limit: Int) -> [WebBubbleItem] {
        guard limit > 0 else { return [] }
        struct Candidate {
            let item: WebBubbleItem
            let bucket: [String]
            let index: Int
        }

        func isNewer(_ lhs: Candidate, than rhs: Candidate) -> Bool {
            if lhs.item.createdAt != rhs.item.createdAt {
                return lhs.item.createdAt > rhs.item.createdAt
            }
            return lhs.item.id > rhs.item.id
        }

        var heap: [Candidate] = []
        func push(_ candidate: Candidate) {
            heap.append(candidate)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard isNewer(heap[child], than: heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }
        func pop() -> Candidate? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let result = heap[0]
            heap[0] = heap.removeLast()
            var parent = 0
            while true {
                let left = (parent * 2) + 1
                guard left < heap.count else { break }
                let right = left + 1
                let child = right < heap.count && isNewer(heap[right], than: heap[left]) ? right : left
                guard isNewer(heap[child], than: heap[parent]) else { break }
                heap.swapAt(parent, child)
                parent = child
            }
            return result
        }
        func seed(_ bucket: [String]) {
            guard let index = bucket.indices.last,
                  let item = itemsById[bucket[index]] else { return }
            push(Candidate(item: item, bucket: bucket, index: index))
        }

        seed(parentlessItemIdsByStream[stream, default: []])
        for parentId in parentIds {
            seed(itemIdsByParentByStream[stream]?[parentId] ?? [])
        }

        var selected: [WebBubbleItem] = []
        selected.reserveCapacity(limit)
        while selected.count < limit, let candidate = pop() {
            selected.append(candidate.item)
            let previousIndex = candidate.index - 1
            if previousIndex >= 0,
               let item = itemsById[candidate.bucket[previousIndex]]
            {
                push(Candidate(item: item, bucket: candidate.bucket, index: previousIndex))
            }
        }
        return selected
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
        windowFeatures _: WKWindowFeatures
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
        itemIdsInOrderByStream[item.stream, default: []].append(bubbleId)
        if let parent = item.parentItemId {
            itemIdsByParentByStream[item.stream, default: [:]][parent, default: []].append(bubbleId)
        } else {
            parentlessItemIdsByStream[item.stream, default: []].append(bubbleId)
        }
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
            let item = itemsById[id]
            let stream = item?.stream
            itemsById.removeValue(forKey: id)
            if let stream, let item {
                if let parent = item.parentItemId {
                    itemIdsByParentByStream[stream]?[parent]?.removeAll { $0 == id }
                } else {
                    parentlessItemIdsByStream[stream]?.removeAll { $0 == id }
                }
            }
            itemsInOrder.removeAll(where: { $0 == id })
            if let stream { itemIdsInOrderByStream[stream]?.removeAll(where: { $0 == id }) }
            onItemsChanged?()
            return
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        let stream = itemsById[id]?.stream
        let parent = itemsById[id]?.parentItemId
        webViewsById.removeValue(forKey: id)
        delegatesById.removeValue(forKey: id)
        itemsById.removeValue(forKey: id)
        if let stream {
            if let parent {
                itemIdsByParentByStream[stream]?[parent]?.removeAll { $0 == id }
            } else {
                parentlessItemIdsByStream[stream]?.removeAll { $0 == id }
            }
        }
        itemsInOrder.removeAll(where: { $0 == id })
        if let stream { itemIdsInOrderByStream[stream]?.removeAll(where: { $0 == id }) }

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
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
    {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard Self.isAllowedScheme(url) else {
            decisionHandler(.cancel)
            return
        }
        if ExternalWebContentPolicy.shouldOpenInBrowserSurface(url) {
            ExternalWebContentPolicy.openBrowserSurface(for: url, from: webView)
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

    func webView(_: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void)
    {
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

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        coordinator?.updateTitle(for: ownerItemId, title: webView.title)
    }

    func webView(_: WKWebView,
                 requestMediaCapturePermissionFor _: WKSecurityOrigin,
                 initiatedByFrame _: WKFrameInfo,
                 type _: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void)
    {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView?
    {
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
