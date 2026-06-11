//
//  DictationLanguageHintResolver.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation
import UIKit

enum DictationLanguageHintResolver {
    static func resolve() -> String {
        if let keyboardLanguage = UITextInputMode.activeInputModes
            .compactMap(\ .primaryLanguage)
            .first(where: { $0.lowercased() != "emoji" }),
           let normalized = normalize(keyboardLanguage) {
            return normalized
        }

        if let preferred = Locale.preferredLanguages.first,
           let normalized = normalize(preferred) {
            return normalized
        }

        return "en"
    }

    private static func normalize(_ language: String) -> String? {
        let raw = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let base = raw.split(separator: "-").first.map(String.init) ?? raw
        let lowercased = base.lowercased()
        guard !lowercased.isEmpty else { return nil }
        return lowercased
    }
}
