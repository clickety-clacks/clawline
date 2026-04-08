//
//  WebSessionSharedResources.swift
//  Clawline
//
//  Shared WebKit resources for authenticated embedded browsing (#57).
//

import Foundation
import WebKit

/// WebKit cookie/session persistence requires `WKWebsiteDataStore.default()`.
/// A shared `WKProcessPool` helps keep WebKit process behavior consistent across multiple `WKWebView`s.
final class WebSessionSharedResources {
    static let shared = WebSessionSharedResources()

    let websiteDataStore: WKWebsiteDataStore
    let processPool: WKProcessPool

    private init() {
        self.websiteDataStore = .default()
        self.processPool = WKProcessPool()
    }
}

