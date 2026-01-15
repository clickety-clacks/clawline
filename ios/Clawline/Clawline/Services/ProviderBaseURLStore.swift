//
//  ProviderBaseURLStore.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

enum ProviderBaseURLStore {
    private static let key = "provider.baseURL"

    static var baseURL: URL? {
        guard let value = UserDefaults.standard.string(forKey: key) else {
            return nil
        }
        return URL(string: value)
    }

    static func setBaseURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: key)
    }
}
