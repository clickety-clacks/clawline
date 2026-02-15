//
//  DictationTranscriptBuffer.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation

struct SonioxTranscriptToken: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

struct DictationTranscriptSnapshot: Equatable, Sendable {
    let text: String
    let finished: Bool
}

final class DictationTranscriptBuffer: Sendable {
    private var finalTokens: [SonioxTranscriptToken] = []
    private var nonFinalTokens: [SonioxTranscriptToken] = []

    var renderedText: String {
        let finalText = finalTokens.map(\.text).joined()
        let nonFinalText = nonFinalTokens.map(\.text).joined()
        return finalText + nonFinalText
    }

    func apply(tokens: [SonioxTranscriptToken], finished: Bool) -> DictationTranscriptSnapshot {
        let filtered = tokens.filter { $0.text != "<end>" && $0.text != "<fin>" }
        let finals = filtered.filter(\.isFinal)
        let nonFinals = filtered.filter { !$0.isFinal }

        finalTokens.append(contentsOf: finals)
        nonFinalTokens = nonFinals

        if finished {
            nonFinalTokens.removeAll()
        }

        return DictationTranscriptSnapshot(text: renderedText, finished: finished)
    }

    func reset() {
        finalTokens.removeAll()
        nonFinalTokens.removeAll()
    }
}
