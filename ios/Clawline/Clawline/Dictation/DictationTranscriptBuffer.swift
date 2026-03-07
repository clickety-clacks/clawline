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

struct DictationSegmentUpdate: Equatable, Sendable {
    let provisionalText: String
    let committedSegments: [String]
    let finished: Bool
    let sawEndpoint: Bool
    let hadAnyTokens: Bool
}

final class DictationTranscriptBuffer: Sendable {
    private var committedText: String = ""
    private var currentSegmentFinalTokens: [String] = []
    private var currentSegmentNonFinalTokens: [String] = []

    var renderedText: String {
        committedText + currentSegmentFinalTokens.joined() + currentSegmentNonFinalTokens.joined()
    }

    func apply(tokens: [SonioxTranscriptToken], finished: Bool) -> DictationSegmentUpdate {
        var committedSegments: [String] = []
        var sawEndpoint = false
        var chunk: [SonioxTranscriptToken] = []

        func applyChunk(_ chunkTokens: [SonioxTranscriptToken]) {
            guard !chunkTokens.isEmpty else { return }
            let finals = chunkTokens.filter(\.isFinal).map(\.text)
            let nonFinals = chunkTokens.filter { !$0.isFinal }.map(\.text)
            currentSegmentFinalTokens = finals
            currentSegmentNonFinalTokens = nonFinals
        }

        for token in tokens {
            if token.text == "<fin>" {
                continue
            }
            if token.text == "<end>" {
                applyChunk(chunk)
                chunk.removeAll(keepingCapacity: true)
                sawEndpoint = true

                let segment = currentSegmentFinalTokens.joined() + currentSegmentNonFinalTokens.joined()
                if !segment.isEmpty {
                    committedSegments.append(segment)
                    committedText += segment
                }
                currentSegmentFinalTokens.removeAll(keepingCapacity: true)
                currentSegmentNonFinalTokens.removeAll(keepingCapacity: true)
                continue
            }
            chunk.append(token)
        }

        applyChunk(chunk)

        return DictationSegmentUpdate(
            provisionalText: currentSegmentFinalTokens.joined() + currentSegmentNonFinalTokens.joined(),
            committedSegments: committedSegments,
            finished: finished,
            sawEndpoint: sawEndpoint,
            hadAnyTokens: !tokens.isEmpty
        )
    }

    func reset() {
        committedText.removeAll(keepingCapacity: true)
        currentSegmentFinalTokens.removeAll(keepingCapacity: true)
        currentSegmentNonFinalTokens.removeAll(keepingCapacity: true)
    }
}
