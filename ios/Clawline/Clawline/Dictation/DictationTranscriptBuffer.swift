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
    private var currentSegmentTokens: [String] = []

    var renderedText: String {
        committedText + currentSegmentTokens.joined()
    }

    func apply(tokens: [SonioxTranscriptToken], finished: Bool) -> DictationSegmentUpdate {
        var committedSegments: [String] = []
        var sawEndpoint = false
        var chunk: [SonioxTranscriptToken] = []

        func applyChunk(_ chunkTokens: [SonioxTranscriptToken]) {
            guard !chunkTokens.isEmpty else { return }
            currentSegmentTokens = chunkTokens.map(\.text)
        }

        for token in tokens {
            if token.text == "<fin>" {
                continue
            }
            if token.text == "<end>" {
                applyChunk(chunk)
                chunk.removeAll(keepingCapacity: true)
                sawEndpoint = true

                let segment = currentSegmentTokens.joined()
                if !segment.isEmpty {
                    committedSegments.append(segment)
                    committedText += segment
                }
                currentSegmentTokens.removeAll(keepingCapacity: true)
                continue
            }
            chunk.append(token)
        }

        applyChunk(chunk)

        return DictationSegmentUpdate(
            provisionalText: currentSegmentTokens.joined(),
            committedSegments: committedSegments,
            finished: finished,
            sawEndpoint: sawEndpoint,
            hadAnyTokens: !tokens.isEmpty
        )
    }

    func reset() {
        committedText.removeAll(keepingCapacity: true)
        currentSegmentTokens.removeAll(keepingCapacity: true)
    }
}
