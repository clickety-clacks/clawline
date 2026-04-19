//
//  WebSessionSharedResources.swift
//  Clawline
//
//  Shared WebKit resources for authenticated embedded browsing (#57).
//

import Foundation
import WebKit

/// WebKit cookie/session persistence requires `WKWebsiteDataStore.default()`.
final class WebSessionSharedResources {
    static let shared = WebSessionSharedResources()

    let websiteDataStore: WKWebsiteDataStore

    private init() {
        self.websiteDataStore = .default()
    }
}
