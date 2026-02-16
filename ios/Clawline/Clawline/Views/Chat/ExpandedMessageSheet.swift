//
//  ExpandedMessageSheet.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import SwiftUI
import UIKit

struct ExpandedMessageSheet: View {
    let message: Message
    let presentation: MessagePresentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var dragOffset: CGFloat = 0
    private let dismissThreshold: CGFloat = 100

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var metrics: ChatFlowTheme.Metrics { ChatFlowTheme.Metrics(isCompact: isCompact) }
    private var effectiveColorScheme: ColorScheme {
#if os(visionOS)
        return settings.appearanceMode == .dark ? .dark : .light
#else
        return colorScheme
#endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    content
                }
                .padding()
            }
            .background(sheetBackground)
            .navigationTitle(message.role == .user ? "Your Message" : message.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .offset(x: dragOffset)
        .opacity(1.0 - Double(abs(dragOffset)) / 300.0)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    if abs(value.translation.width) > dismissThreshold {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(message.role == .user ? ChatFlowTheme.sage(effectiveColorScheme) : ChatFlowTheme.softCoral(effectiveColorScheme))
                .frame(width: 8, height: 8)
            Text(message.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ChatFlowTheme.warmBrown(effectiveColorScheme))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fileAttachments) { attachment in
                FileAttachmentRow(
                    filename: attachment.filename ?? attachment.assetId ?? attachment.mimeType ?? "Attachment",
                    sizeText: attachment.size.map(Self.formatFileSize),
                    colorScheme: effectiveColorScheme
                )
            }

            if let emojiOnlyText {
                Text(emojiOnlyText)
                    .font(.system(size: 32))
            } else if let attributedText {
                SelectableAttributedText(
                    attributedString: attributedText,
                    alignment: .left,
                    colorScheme: effectiveColorScheme,
                    onSelectionChange: { _ in },
                    onLinkTap: { url in
                        UIApplication.shared.open(url)
                    }
                )
            }

            ForEach(Array(linkPreviewURLs.enumerated()), id: \.offset) { item in
                LinkPreviewRepresentable(url: item.element)
                    .frame(maxWidth: .infinity)
            }

            ForEach(Array(codeBlocks.enumerated()), id: \.offset) { item in
                CodeBlockView(language: item.element.language, code: item.element.code)
            }

            ForEach(Array(tables.enumerated()), id: \.offset) { item in
                MarkdownTableView(
                    model: item.element,
                    role: message.role,
                    metrics: metrics,
                    maxLineWidth: ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize),
                    isExpanded: true,
                    onExpand: {},
                    onCollapse: { dismiss() }
                )
            }

            ForEach(Array(terminalSessions.enumerated()), id: \.offset) { item in
                TerminalBubbleExpandedRepresentable(descriptor: item.element)
                    .frame(maxWidth: .infinity)
            }

            ForEach(Array(interactiveHTMLDescriptors.enumerated()), id: \.offset) { item in
                let descriptor = item.element
                FileAttachmentRow(
                    filename: descriptor.metadata?.title.map { "Interactive: \($0)" } ?? "Interactive HTML",
                    sizeText: nil,
                    colorScheme: effectiveColorScheme
                )
            }

            ForEach(Array(mediaParts.enumerated()), id: \.offset) { item in
                mediaPartView(item.element)
            }
        }
        .font(.system(size: metrics.bodyFontSize, weight: .regular))
        .foregroundColor(ChatFlowTheme.ink(effectiveColorScheme))
        .lineSpacing(4)
    }

    private var attributedText: NSAttributedString? {
        let ink = UIColor(ChatFlowTheme.ink(effectiveColorScheme))
        let attributed = MessageTextPartRenderer.attributedText(
            from: presentation,
            sizeClass: .long,
            metrics: metrics,
            inkColor: ink,
            stripDetectedURLs: false,
            isDarkMode: effectiveColorScheme == .dark,
            enableMarkdownHighlights: message.role == .assistant
        )
        let trimmed = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : attributed
    }

    private var emojiOnlyText: String? {
        guard presentation.isEmojiOnly else { return nil }
        let values = presentation.parts.compactMap { part -> String? in
            if case .inlineEmoji(let value) = part { return value }
            return nil
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: "\n\n")
    }

    private var fileAttachments: [Attachment] {
        presentation.parts.compactMap { part in
            if case .file(let attachment) = part { return attachment }
            return nil
        }
    }

    private var linkPreviewURLs: [URL] {
        presentation.parts.compactMap { part in
            if case .linkPreview(let url) = part { return url }
            return nil
        }
    }

    private var codeBlocks: [(language: String?, code: String)] {
        presentation.parts.compactMap { part in
            if case .code(let language, let code) = part {
                return (language: language, code: code)
            }
            return nil
        }
    }

    private var tables: [TableModel] {
        presentation.parts.compactMap { part in
            if case .table(let model) = part { return model }
            return nil
        }
    }

    private var terminalSessions: [TerminalSessionDescriptor] {
        presentation.parts.compactMap { part in
            if case .terminalSession(let descriptor) = part { return descriptor }
            return nil
        }
    }

    private var interactiveHTMLDescriptors: [InteractiveHTMLDescriptor] {
        presentation.parts.compactMap { part in
            if case .interactiveHTML(let descriptor) = part { return descriptor }
            return nil
        }
    }

    private var mediaParts: [MessagePart] {
        presentation.parts.filter { part in
            switch part {
            case .image, .gallery:
                return true
            default:
                return false
            }
        }
    }

    @ViewBuilder
    private func mediaPartView(_ part: MessagePart) -> some View {
        switch part {
        case .image(let attachment):
            if let data = attachment.data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .gallery(let attachments):
            ForEach(attachments) { attachment in
                if let data = attachment.data, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        case .text, .markdown, .table, .code, .linkPreview, .file, .terminalSession, .interactiveHTML, .inlineEmoji:
            EmptyView()
        }
    }

    nonisolated private static func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var sheetBackground: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.1, green: 0.1, blue: 0.1)
            : ChatFlowTheme.cream(effectiveColorScheme)
    }
}

private struct TerminalBubbleExpandedRepresentable: UIViewRepresentable {
    let descriptor: TerminalSessionDescriptor

    final class Coordinator {
        var lastTerminalSessionId: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TerminalBubbleUIKitView {
        let view = TerminalBubbleUIKitView()
        view.configure(descriptor: descriptor, style: .expanded(height: 520))
        context.coordinator.lastTerminalSessionId = descriptor.terminalSessionId
        return view
    }

    func updateUIView(_ uiView: TerminalBubbleUIKitView, context: Context) {
        // Avoid reconfiguring during unrelated SwiftUI updates (can cause flicker/reconnect churn).
        if context.coordinator.lastTerminalSessionId != descriptor.terminalSessionId {
            uiView.configure(descriptor: descriptor, style: .expanded(height: 520))
            context.coordinator.lastTerminalSessionId = descriptor.terminalSessionId
        }
    }
}

private struct FileAttachmentRow: View {
    let filename: String
    let sizeText: String?
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(ChatFlowTheme.ink(colorScheme).opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ChatFlowTheme.ink(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sizeText {
                    Text(sizeText)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(ChatFlowTheme.ink(colorScheme).opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(ChatFlowTheme.ink(colorScheme).opacity(colorScheme == .dark ? 0.08 : 0.06))
        )
    }
}
