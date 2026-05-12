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
    private var currentSegmentFinalText: String = ""
    private var currentSegmentInterimText: String = ""

    var renderedText: String {
        committedText + currentSegmentText
    }

    private var currentSegmentText: String {
        currentSegmentFinalText + currentSegmentInterimText
    }

    func apply(tokens: [SonioxTranscriptToken], finished: Bool) -> DictationSegmentUpdate {
        var committedSegments: [String] = []
        var sawEndpoint = false
        var chunk: [SonioxTranscriptToken] = []

        func applyChunk(_ chunkTokens: [SonioxTranscriptToken]) {
            guard !chunkTokens.isEmpty else { return }
            let finalPrefix = chunkTokens
                .prefix { $0.isFinal }
                .map(\.text)
                .joined()
            let interimText = chunkTokens
                .drop { $0.isFinal }
                .map(\.text)
                .joined()

            if !finalPrefix.isEmpty {
                currentSegmentFinalText = mergedFinalText(
                    currentSegmentFinalText,
                    with: finalPrefix
                )
            }
            currentSegmentInterimText = interimText
        }

        for token in tokens {
            if token.text == "<fin>" {
                continue
            }
            if token.text == "<end>" {
                applyChunk(chunk)
                chunk.removeAll(keepingCapacity: true)
                sawEndpoint = true

                let segment = currentSegmentText
                if !segment.isEmpty {
                    committedSegments.append(segment)
                    committedText += segment
                }
                currentSegmentFinalText.removeAll(keepingCapacity: true)
                currentSegmentInterimText.removeAll(keepingCapacity: true)
                continue
            }
            chunk.append(token)
        }

        applyChunk(chunk)

        return DictationSegmentUpdate(
            provisionalText: currentSegmentText,
            committedSegments: committedSegments,
            finished: finished,
            sawEndpoint: sawEndpoint,
            hadAnyTokens: !tokens.isEmpty
        )
    }

    func reset() {
        committedText.removeAll(keepingCapacity: true)
        currentSegmentFinalText.removeAll(keepingCapacity: true)
        currentSegmentInterimText.removeAll(keepingCapacity: true)
    }

    private func mergedFinalText(_ existing: String, with incoming: String) -> String {
        guard !incoming.isEmpty else { return existing }
        guard !existing.isEmpty else { return incoming }
        if incoming.hasPrefix(existing) {
            return incoming
        }
        return existing + incoming
    }
}
