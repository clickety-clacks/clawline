//
//  MessageKindClassifier.swift
//  Clawline
//
//  The ONE home for message-kind classification at the view-model level.
//  Cycle-3 Goal A. Classifies each rendered Message into a MessageKind that
//  drives which presentation the flow uses (assistant / substrate / marker /
//  agent). It COMPOSES the existing MessageProvenance origin seam
//  (Models/MessageProvenance.swift, spec §T-D) instead of re-parsing the wire
//  `sender` field: there is exactly one origin authority, and nobody forks a
//  parallel detector.
//
//  Decode is TOLERANT and never throws. An unknown wire messageType or an
//  unrecognized origin degrades to `.assistant`. On OpenClaw backends none of
//  these signals are present, so every message classifies as `.assistant` and
//  rendering is unchanged BY CONSTRUCTION — no capability flag, no fallback
//  branch.
//

import Foundation

/// The presentation family a message belongs to. `.assistant` is BOTH the
/// ordinary assistant reply AND the safe fallback: any message the classifier
/// cannot place lands here and renders exactly as it does today.
///
/// EXTENSIBLE: a `.toolCall` case is a likely near-future addition (sibling
/// wi_29a9bf12). Adding a case is a small additive change — no consumer in this
/// file assumes the set is closed beyond its own explicit mapping, so a new case
/// never silently misroutes.
enum MessageKind: String, Equatable, Sendable {
    case assistant
    case substrate
    case marker
    case agent
}

enum MessageKindClassifier {
    /// Map a raw wire `messageType` string to a kind, tolerantly.
    ///
    /// Returns `nil` for a missing OR unrecognized value so the caller falls
    /// through to the heuristic/default rather than throwing (the controls-freeze
    /// lesson: never strict-decode an enum whose value set can grow server-side).
    static func kind(forWireMessageType rawValue: String?) -> MessageKind? {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "assistant": return .assistant
        case "substrate": return .substrate
        case "marker": return .marker
        case "agent": return .agent
        default: return nil
        }
    }

    /// Classify a message into its presentation family. Never throws.
    ///
    /// - Parameters:
    ///   - message: the message to classify.
    ///   - wireMessageType: the raw wire `messageType` string WHEN present. It is
    ///     absent today; the sibling slice (wi_62ef32ae) adds the field, after
    ///     which passing it here makes it the preferred signal with no other
    ///     change to this classifier.
    ///
    /// Precedence: (1) a recognized wire messageType wins; (2) else the
    /// provenance origin heuristic; (3) else `.assistant`.
    static func classify(_ message: Message, wireMessageType: String? = nil) -> MessageKind {
        // (1) Preferred: an explicit, recognized wire messageType.
        if let explicit = kind(forWireMessageType: wireMessageType) {
            return explicit
        }

        // (2) Heuristic TODAY: the provenance origin (Models/MessageProvenance).
        //     `provenanceOrigin` is the single origin authority — it couples to
        //     the anti-forgery first-line stamp cross-check, so a stampless or
        //     forged origin falls through to `.assistant` (renders as today).
        switch message.provenanceOrigin {
        case .process:
            // Automation (`process:*`, e.g. process:tightbeam) -> substrate.
            return .substrate
        case .agent:
            // Colleague DM (`agent:*`) -> agent-to-agent presentation.
            return .agent
        case .user, .none:
            // Operator action (`user:*`), device-typed, an ordinary assistant
            // reply, or any unrecognized signal: no special kind. `.marker` is
            // intentionally UNREACHABLE by heuristic — marker boundaries are not
            // reliably observable client-side today (see the cycle-3 Goal A
            // observability report) and arrive only via an explicit wire
            // messageType.
            return .assistant
        }
    }
}

extension Message {
    /// The presentation family of this message via the centralized classifier.
    /// Convenience for call sites that do not (yet) carry a wire messageType.
    var messageKind: MessageKind {
        MessageKindClassifier.classify(self)
    }
}
