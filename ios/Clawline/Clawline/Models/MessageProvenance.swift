//
//  MessageProvenance.swift
//  Clawline
//
//  Provenance classification for non-user-originated messages.
//
//  Normative source: tightbeam_ex/lib/tightbeam/wire/payloads.ex "PROVENANCE
//  CONVENTION" moduledoc and spec §T-D. Clients render from the wire `sender`
//  field, never from text parsing. Origin classes are a CLOSED set:
//  `user:<id>` (operator action), `agent:<handle>` (colleague DM), and
//  `process:<name>` (automation).
//

import Foundation

/// The origin of a wake-delivered, `role=user` message that was not typed on
/// this device. Closed set — an unrecognized `sender` prefix is not represented
/// here (the message falls through to today's rendering).
enum MessageProvenanceOrigin: Equatable {
    /// `sender: "agent:<handle>"` — a colleague's DM.
    case agent(handle: String)
    /// `sender: "user:<id>"` — an operator action via CLI/wake.
    case user(id: String)
    /// `sender: "process:<name>"` — automation (cron/CI/webhook).
    case process(name: String)

    /// Text shown in the provenance chip: the value after the class prefix.
    var chipLabel: String {
        switch self {
        case .agent(let handle):
            return handle
        case .user(let id):
            return id
        case .process(let name):
            return name
        }
    }

    /// Leading glyph for the chip. Only automation carries a distinct glyph (⚙)
    /// per spec §T-D; agent/user chips are unglyphed.
    var chipGlyph: String? {
        switch self {
        case .agent, .user:
            return nil
        case .process:
            return "⚙"
        }
    }
}

enum MessageProvenance {
    static let agentPrefix = "agent:"
    static let userPrefix = "user:"
    static let processPrefix = "process:"

    /// Classify a message's origin from wire fields alone.
    ///
    /// Returns `nil` when the message is typed-by-human (`role == .user` with no
    /// `sender`), when `role != .user`, or when the `sender` prefix is outside
    /// the closed set. In every `nil` case the caller renders as today — an
    /// unrecognized prefix is never invented into a chip class.
    static func origin(role: Message.Role, sender: String?) -> MessageProvenanceOrigin? {
        guard role == .user, let sender, !sender.isEmpty else { return nil }
        if sender.hasPrefix(agentPrefix) {
            return .agent(handle: String(sender.dropFirst(agentPrefix.count)))
        }
        if sender.hasPrefix(userPrefix) {
            return .user(id: String(sender.dropFirst(userPrefix.count)))
        }
        if sender.hasPrefix(processPrefix) {
            return .process(name: String(sender.dropFirst(processPrefix.count)))
        }
        return nil
    }

    /// Strip the wake provenance stamp from the FIRST LINE of `content` when — and
    /// only when — that line is exactly `[from <sender>]` (the `sender` field
    /// verbatim, prefix included). The exact match against the `sender` field is
    /// the anti-forgery cross-check: a first line that does not match is left in
    /// place (it is ordinary text), and any `[from ...]` deeper in the body is
    /// quoted text that is never touched.
    static func strippingProvenanceStamp(from content: String, sender: String) -> String {
        let stamp = "[from \(sender)]"
        let firstLineEnd = content.firstIndex(of: "\n")
        let firstLine = firstLineEnd.map { String(content[content.startIndex..<$0]) } ?? content
        guard firstLine == stamp else { return content }
        guard let firstLineEnd else { return "" }
        return String(content[content.index(after: firstLineEnd)...])
    }
}

extension Message {
    /// The provenance origin of this message, or `nil` when it should render as a
    /// device-typed message (see `MessageProvenance.origin`).
    var provenanceOrigin: MessageProvenanceOrigin? {
        MessageProvenance.origin(role: role, sender: sender)
    }

    /// A copy of this message with the first-line provenance stamp removed.
    /// This is the ONE seam that produces the display body for provenance
    /// messages: presentation building (and therefore V1/V2 sizing), bubble
    /// rendering, and copy/accessibility all consume its output, so measure
    /// and render can never disagree about the stamp line. Returns `self`
    /// unchanged when there is no provenance origin or the first line fails
    /// the anti-forgery cross-check.
    func strippingProvenanceStampForDisplay() -> Message {
        guard provenanceOrigin != nil, let sender else { return self }
        let stripped = MessageProvenance.strippingProvenanceStamp(from: content, sender: sender)
        guard stripped != content else { return self }
        return Message(
            id: id,
            llmVisibleMessageId: llmVisibleMessageId,
            role: role,
            content: stripped,
            timestamp: timestamp,
            streaming: streaming,
            attachments: attachments,
            deviceId: deviceId,
            sessionKey: sessionKey,
            sender: sender,
            clientMessageId: clientMessageId,
            replyToMessageId: replyToMessageId,
            replyToClientMessageId: replyToClientMessageId,
            deliveryState: deliveryState
        )
    }
}
