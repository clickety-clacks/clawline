//
//  MessageDetailViewer.swift
//  Clawline
//
//  Goal B (Clawline cycle 3): detail viewer that Goal A's compact bubble
//  renderings open into, plus the visionOS new-window behavior.
//

import Foundation
import SwiftUI

#if DEBUG
// MARK: - Verification fixture (DEBUG only)

extension Message {
    /// Real long-form prose (excerpted from clawline-spec.md, not hand-written lorem ipsum)
    /// used to verify the detail viewer's layout in the simulator ahead of Goal A's bubble
    /// tap wiring into openDetail(for:). See CLAWLINE_DEBUG_PREVIEW_MESSAGE_DETAIL in
    /// ClawlineApp.swift.
    static var debugPreviewLongMessage: Message {
        Message(
            id: "debug-preview-message-detail",
            role: .assistant,
            content: """
            Clawline is the USER-FACING CLIENT for tightbeam on Apple devices. It was originally \
            created for OpenClaw and later adapted to run against tightbeam; the repo README still \
            says OpenClaw and is out of date. Clawline is a LIVE product, already stood up and \
            working. The org's job is additions and maintenance, not greenfield build.

            OpenClaw compatibility is an INVARIANT — preserved by default. BUT not an absolute \
            limit: a breaking feature that adds amazing value to clawline+tightbeam is a \
            product-owner DISCUSSION, never an automatic reject and never thrown away silently.

            FIRST PRIORITY — performance/stability: parts slow to a crawl under heavy use; hangs \
            and crashes are occurring. These come before everything else. SECOND PRIORITY — UX \
            de-noising: Clawline was built for OpenClaw's event stream; tightbeam sends a much \
            RICHER stream and Clawline has become noisy. Iteratively clean up how it presents \
            things.

            Four surfaces exist, at varying completeness: iOS, Mac, visionOS (a spatial version, \
            not a mere port), and web. The three Apple surfaces are mostly at feature parity. Web \
            is the outlier: a disjunct codebase, though it lives in the SAME monorepo.
            """,
            timestamp: Date(timeIntervalSince1970: 1_786_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "debug-preview-session",
            sender: "Clawline spec"
        )
    }
}
#endif

// MARK: - Entry point (Goal A wires to this)

/// Environment action Goal A calls as `openDetail(for: message)` to open the
/// full contents of a message. iOS/Catalyst present it as the in-app layout
/// below; visionOS opens it as a new window/scene instead of a modal.
struct MessageDetailAction {
    private let handler: @MainActor (Message) -> Void

    init(handler: @escaping @MainActor (Message) -> Void) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction(for message: Message) {
        handler(message)
    }
}

private struct MessageDetailActionKey: EnvironmentKey {
    static let defaultValue = MessageDetailAction { _ in }
}

extension EnvironmentValues {
    var openDetail: MessageDetailAction {
        get { self[MessageDetailActionKey.self] }
        set { self[MessageDetailActionKey.self] = newValue }
    }
}

// MARK: - Shared presentation state

/// Holds the message currently open in the detail viewer. One instance is
/// owned at each app's composition root (ClawlineApp / Clawline_SpatialApp)
/// and injected into every scene, so a visionOS detail window can read the
/// message its sibling scene asked to open.
@Observable
final class MessageDetailPresentation {
    var message: Message?
}

private struct MessageDetailPresentationKey: EnvironmentKey {
    static let defaultValue = MessageDetailPresentation()
}

extension EnvironmentValues {
    var messageDetailPresentation: MessageDetailPresentation {
        get { self[MessageDetailPresentationKey.self] }
        set { self[MessageDetailPresentationKey.self] = newValue }
    }
}

// MARK: - Content (platform-neutral: the message's full contents)

struct MessageDetailContentView: View {
    let message: Message
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !message.attachments.isEmpty {
                        attachmentsSummary
                    }
                }
                .padding()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(message.displayName)
                    .font(.headline)
                Text(message.timestamp, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }
        }
        .padding()
    }

    private var attachmentsSummary: some View {
        Text("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - iOS / Catalyst layout (in-app modal-style layout, NOT a system sheet)

/// ~80% of parent width, full height, top and bottom padding. Presented as a
/// full-bleed overlay so the detail viewer's own frame — not a system sheet
/// detent — controls the exact proportions the spec calls for.
struct MessageDetailViewer: View {
    let message: Message
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)

                MessageDetailContentView(message: message, onClose: onDismiss)
                    .frame(width: proxy.size.width * 0.8)
                    .frame(maxHeight: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(radius: 20)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
    }
}

// MARK: - visionOS new-window wiring

/// Installs `openDetail` so it opens a NEW WINDOW (the "message-detail"
/// WindowGroup) instead of presenting a modal. Applied as a view modifier
/// (not set directly on the App struct) so `@Environment(\.openWindow)`
/// resolves against a real scene/view context.
struct MessageDetailWindowOpener: ViewModifier {
    let presentation: MessageDetailPresentation
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .environment(\.messageDetailPresentation, presentation)
            .environment(\.openDetail, MessageDetailAction { message in
                presentation.message = message
                openWindow(id: MessageDetailWindowOpener.windowID)
            })
    }

    static let windowID = "message-detail"
}

// MARK: - visionOS new-window content

/// Root content of the visionOS "message-detail" WindowGroup. Reads the
/// message via the shared presentation object rather than a typed window
/// value, since Message isn't Hashable and that conformance isn't this
/// goal's to add to a model shared with Goal A.
struct MessageDetailWindowScene: View {
    @Environment(\.messageDetailPresentation) private var presentation

    var body: some View {
        if let message = presentation.message {
            MessageDetailContentView(message: message)
        } else {
            ContentUnavailableView(
                "No message selected",
                systemImage: "doc.text.magnifyingglass"
            )
        }
    }
}
