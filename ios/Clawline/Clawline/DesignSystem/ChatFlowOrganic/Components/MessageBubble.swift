//
//  MessageBubble.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit
import LinkPresentation

struct MessageBubble: View {
    let message: Message

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showExpandedSheet = false
    @State private var measuredContentHeight: CGFloat = 0
    @State private var promotedSizeClass: MessageSizeClass? = nil
    @State private var promotionTask: Task<Void, Never>? = nil

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var metrics: ChatFlowTheme.Metrics { ChatFlowTheme.Metrics(isCompact: isCompact) }
    private var presentation: MessagePresentation { MessagePresentationBuilder.build(from: message) }
    private var textualParts: [MessagePart] { presentation.parts.filter { $0.isTextual }}
    private var nonTextParts: [MessagePart] { presentation.parts.filter { !$0.isTextual }}
    private var hasTextualParts: Bool { !textualParts.isEmpty }
    private var derivedSizeClass: MessageSizeClass { presentation.inferredSizeClass() }
    private var maxLineWidth: CGFloat { ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize) }

    private var sizeClass: MessageSizeClass {
        if message.streaming {
            return promotedSizeClass ?? derivedSizeClass
        }
        return derivedSizeClass
    }

    var body: some View {
        bubble
            .fixedSize(horizontal: sizeClass == .short, vertical: true)
            .layoutValue(key: MessageSizeClassKey.self, value: sizeClass)
            .onAppear(perform: schedulePromotionUpdate)
            .onChange(of: message.content) { _, _ in schedulePromotionUpdate() }
            .onChange(of: message.attachments.count) { _, _ in schedulePromotionUpdate() }
            .onChange(of: message.streaming) { _, _ in schedulePromotionUpdate() }
            .sheet(isPresented: $showExpandedSheet) {
                ExpandedMessageSheet(message: message, presentation: presentation)
            }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            bubbleContent
                .clipShape(bubbleContentShape)

            if shouldShowTruncationControl {
                truncationIndicator
                    .padding(.horizontal, bubblePaddingHorizontal)
                    .padding(.bottom, bubblePaddingVertical)
                    .background(bubbleBackground)
                    .clipShape(truncationIndicatorShape)
                    .offset(y: -1) // Overlap by 1pt to hide seam
            }
        }
        .shadow(color: bubbleShadowNear, radius: 2, x: 0, y: 2)
        .shadow(color: bubbleShadowMid, radius: 12, x: 0, y: 8)
        .shadow(color: bubbleShadowFar, radius: 20, x: 0, y: 16)
        .overlay(adminOutline)
        .accessibilityLabel(MessageAccessibilityFormatter.label(for: message, presentation: presentation))
    }

    /// Shape for bubble content - flat bottom when truncation indicator is shown
    private var bubbleContentShape: UnevenRoundedRectangle {
        let radii = bubbleCornerRadii()
        if shouldShowTruncationControl {
            return UnevenRoundedRectangle(
                topLeadingRadius: radii.topLeading,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: radii.topTrailing
            )
        }
        return bubbleShape
    }

    /// Shape for truncation indicator - flat top, rounded bottom matching bubble
    private var truncationIndicatorShape: UnevenRoundedRectangle {
        let radii = bubbleCornerRadii()
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: 0
        )
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            messageBody

            if message.streaming {
                ProgressView()
                    .scaleEffect(0.75)
            }
        }
        .padding(.vertical, bubblePaddingVertical)
        .padding(.horizontal, bubblePaddingHorizontal)
        .background(bubbleBackground)
        .overlay(innerHighlightOverlay)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(role: message.role)
            Text(senderName)
                .font(.system(size: metrics.senderFontSize, weight: .semibold))
                .foregroundColor(message.channelType == .admin ? ChatFlowTheme.adminAccent(colorScheme) : ChatFlowTheme.warmBrown(colorScheme))
                .opacity(message.channelType == .admin ? 1 : 0.7)
                .tracking(0.3)
        }
    }

    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasTextualParts {
                textContainer
            }
            ForEach(Array(nonTextParts.enumerated()), id: \.offset) { item in
                partView(item.element)
            }
        }
    }

    private var textContainer: some View {
        Group {
            if sizeClass == .long {
                textualStack
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxLineWidth, alignment: .leading)
                    .frame(maxHeight: shouldTruncate ? metrics.truncationHeight : nil, alignment: .topLeading)
                    .clipped()
                    .overlay(truncationFadeOverlay)
                    .background(
                        textualStack
                            .frame(maxWidth: maxLineWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(ContentHeightReader())
                            .hidden()
                    )
            } else {
                textualStack
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxLineWidth, alignment: .leading)
            }
        }
        .onPreferenceChange(ContentHeightPreferenceKey.self) { newValue in
            measuredContentHeight = newValue
        }
    }

    private var textualStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(textualParts.enumerated()), id: \.offset) { item in
                partView(item.element)
            }
        }
        .font(fontForSizeClass())
        .foregroundColor(ChatFlowTheme.ink(colorScheme))
        .lineSpacing(sizeClass == .short ? 0 : 4)
    }

    @ViewBuilder
    private func partView(_ part: MessagePart) -> some View {
        switch part {
        case .text(let value):
            Text(value)
                .lineLimit(nil)
        case .markdown(let value):
            if let attributed = try? AttributedString(markdown: value) {
                Text(attributed)
                    .lineLimit(nil)
            } else {
                Text(value)
                    .lineLimit(nil)
            }
        case .inlineEmoji(let value):
            Text(value)
                .font(.system(size: metrics.shortFontSize + 8))
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .linkPreview(let url):
            LinkPreviewCard(url: url)
        case .image(let attachment):
            AttachmentImageView(attachment: attachment, isMediaOnly: presentation.hasMediaOnly)
        case .gallery(let attachments):
            MessageAttachmentView(attachments: attachments, isMediaOnly: presentation.hasMediaOnly)
        }
    }

    private var truncationIndicator: some View {
        Button(action: { showExpandedSheet = true }) {
            VStack(spacing: 0) {
                // Top border separator
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(borderSubtleColor)

                // Indicator content with padding
                HStack(spacing: 6) {
                    Text("Show more")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(truncationIndicatorColor)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .contentShape(Rectangle())
        }
        .padding(.top, 8) // margin-top per design system
        .accessibilityLabel("Expand message")
        .accessibilityAddTraits(.isButton)
    }

    private var truncationFadeOverlay: some View {
        Group {
            if shouldTruncate {
                LinearGradient(
                    colors: [Color.clear, bubbleFadeColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private var bubbleBackground: some View {
        Group {
            if message.role == .user {
                ChatFlowTheme.bubbleSelfGradient(colorScheme)
            } else {
                ChatFlowTheme.bubbleOtherGradient(colorScheme)
            }
        }
    }

    private var innerHighlightOverlay: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.15), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .clipShape(bubbleShape)
    }

    @ViewBuilder
    private var adminOutline: some View {
        if message.channelType == .admin {
            bubbleShape
                .stroke(ChatFlowTheme.adminAccent(colorScheme).opacity(0.6), lineWidth: 1.5)
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let radii = bubbleCornerRadii()
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing
        )
    }

    private struct CornerRadii {
        let topLeading: CGFloat
        let topTrailing: CGFloat
        let bottomLeading: CGFloat
        let bottomTrailing: CGFloat
    }

    private func bubbleCornerRadii() -> CornerRadii {
        let base: CGFloat = 28
        let sharp: CGFloat = 4
        let variationsSelf: [CornerRadii] = [
            .init(topLeading: base, topTrailing: base, bottomLeading: base, bottomTrailing: sharp),
            .init(topLeading: 32, topTrailing: 24, bottomLeading: 26, bottomTrailing: sharp),
            .init(topLeading: 24, topTrailing: 32, bottomLeading: 28, bottomTrailing: sharp),
            .init(topLeading: 26, topTrailing: 30, bottomLeading: 28, bottomTrailing: sharp)
        ]
        let variationsOther: [CornerRadii] = [
            .init(topLeading: base, topTrailing: base, bottomLeading: sharp, bottomTrailing: base),
            .init(topLeading: 32, topTrailing: 24, bottomLeading: sharp, bottomTrailing: 26),
            .init(topLeading: 24, topTrailing: 32, bottomLeading: sharp, bottomTrailing: 28),
            .init(topLeading: 26, topTrailing: 30, bottomLeading: sharp, bottomTrailing: 28)
        ]
        let index = abs(message.id.hashValue) % variationsSelf.count
        return message.role == .user ? variationsSelf[index] : variationsOther[index]
    }

    private func fontForSizeClass() -> Font {
        switch sizeClass {
        case .short:
            return .system(size: metrics.shortFontSize, weight: .semibold)
        case .medium:
            return .system(size: metrics.mediumFontSize, weight: .medium)
        case .long:
            return .system(size: metrics.bodyFontSize, weight: .regular)
        }
    }

    private func schedulePromotionUpdate() {
        guard message.streaming else {
            promotionTask?.cancel()
            promotedSizeClass = nil
            return
        }

        promotionTask?.cancel()
        promotionTask = Task { @MainActor in
            try? await Task.sleep(for: MessageFlowRules.streamingPromotionDelay)
            let next = derivedSizeClass
            let current = promotedSizeClass ?? next
            promotedSizeClass = MessageFlowRules.promotedSizeClass(current: current, next: next)
        }
    }

    private var shouldTruncate: Bool {
        MessageFlowRules.shouldTruncate(
            hasTextualParts: hasTextualParts,
            sizeClass: sizeClass,
            isExpanded: false,
            measuredHeight: measuredContentHeight,
            metrics: metrics
        )
    }

    private var shouldShowTruncationControl: Bool {
        MessageFlowRules.shouldShowTruncationControl(
            hasTextualParts: hasTextualParts,
            sizeClass: sizeClass,
            measuredHeight: measuredContentHeight,
            metrics: metrics
        )
    }

    private var senderName: String {
        message.role == .user ? "You" : "Assistant"
    }

    private var bubbleShadowNear: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.15)
            : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.06)
    }

    private var bubbleShadowMid: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.25)
            : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.10)
    }

    private var bubbleShadowFar: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.20)
            : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.08)
    }

    private var borderSubtleColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.10)
    }

    private var bubbleFadeColor: Color {
        message.role == .user
            ? ChatFlowTheme.sage(colorScheme)
            : ChatFlowTheme.cream(colorScheme)
    }

    private var truncationIndicatorColor: Color {
        message.role == .user ? ChatFlowTheme.terracotta(colorScheme) : ChatFlowTheme.warmBrown(colorScheme)
    }

    private var bubblePaddingVertical: CGFloat {
        presentation.hasMediaOnly ? 8 : metrics.bubblePaddingVertical
    }

    private var bubblePaddingHorizontal: CGFloat {
        presentation.hasMediaOnly ? 8 : metrics.bubblePaddingHorizontal
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ContentHeightReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
        }
    }
}

private struct AvatarView: View {
    let role: Message.Role
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(initial)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(avatarGradient)
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 2)
    }

    private var initial: String {
        role == .user ? "Y" : "A"
    }

    private var avatarGradient: RadialGradient {
        if role == .user {
            return RadialGradient(
                colors: [
                    Color(red: 0.420, green: 0.608, blue: 0.416),
                    Color(red: 0.290, green: 0.478, blue: 0.306),
                    Color(red: 0.176, green: 0.353, blue: 0.196)
                ],
                center: .top,
                startRadius: 2,
                endRadius: 18
            )
        }
        return RadialGradient(
            colors: [
                ChatFlowTheme.softCoral(colorScheme),
                ChatFlowTheme.terracotta(colorScheme),
                Color(red: 0.659, green: 0.353, blue: 0.259)
            ],
            center: .top,
            startRadius: 2,
            endRadius: 18
        )
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.6))
                    .tracking(0.5)
            }
            Text(code)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.9))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(red: 0.118, green: 0.118, blue: 0.118))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MessageAttachmentView: View {
    let attachments: [Attachment]
    let isMediaOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentImageView(attachment: attachment, isMediaOnly: isMediaOnly)
            }
        }
    }
}

private struct AttachmentImageView: View {
    let attachment: Attachment
    let isMediaOnly: Bool

    var body: some View {
        Group {
            if let data = attachment.data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if let remoteURL = remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: isMediaOnly ? 280 : 360)
        .frame(height: isMediaOnly ? 200 : 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var remoteURL: URL? {
        guard let assetId = attachment.assetId else { return nil }
        guard let baseURL = ProviderBaseURLStore.baseURL else { return nil }
        return baseURL
            .appendingPathComponent("download")
            .appendingPathComponent(assetId)
    }

    private var placeholder: some View {
        ZStack {
            Color.black.opacity(0.05)
            Image(systemName: "photo")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.gray)
        }
    }
}

private struct LinkPreviewCard: View {
    let url: URL
    @Environment(\.colorScheme) private var colorScheme
    @State private var metadata: LPLinkMetadata? = nil
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ChatFlowTheme.terracotta(colorScheme))
                    .frame(width: 6, height: 6)
                Text(domain.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ChatFlowTheme.warmBrown(colorScheme))
                    .tracking(0.5)
            }
            Text(primaryText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ChatFlowTheme.ink(colorScheme))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(linkBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: shadowColor, radius: 6, x: 0, y: 2)
        .onAppear(perform: fetchMetadataIfNeeded)
    }

    private var domain: String {
        url.host ?? url.absoluteString
    }

    private var primaryText: String {
        if let title = metadata?.title, !title.isEmpty {
            return title
        }
        return url.absoluteString
    }

    private func fetchMetadataIfNeeded() {
        guard metadata == nil, !isLoading else { return }
        isLoading = true
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { fetched, _ in
            DispatchQueue.main.async {
                self.metadata = fetched
                self.isLoading = false
            }
        }
    }

    private var linkBackground: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.25)
            : Color.white.opacity(0.7)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.15) : Color(red: 0.235, green: 0.176, blue: 0.118).opacity(0.06)
    }
}

private struct ExpandedMessageSheet: View {
    let message: Message
    let presentation: MessagePresentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var dragOffset: CGFloat = 0
    private let dismissThreshold: CGFloat = 100

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var metrics: ChatFlowTheme.Metrics { ChatFlowTheme.Metrics(isCompact: isCompact) }

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
            .navigationTitle(message.role == .user ? "Your Message" : "Assistant")
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
                .fill(message.role == .user ? ChatFlowTheme.sage(colorScheme) : ChatFlowTheme.softCoral(colorScheme))
                .frame(width: 8, height: 8)
            Text(message.role == .user ? "You" : "Assistant")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ChatFlowTheme.warmBrown(colorScheme))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(presentation.parts.enumerated()), id: \.offset) { item in
                partView(item.element)
            }
        }
        .font(.system(size: metrics.bodyFontSize, weight: .regular))
        .foregroundColor(ChatFlowTheme.ink(colorScheme))
        .lineSpacing(4)
    }

    @ViewBuilder
    private func partView(_ part: MessagePart) -> some View {
        switch part {
        case .text(let value):
            Text(value)
        case .markdown(let value):
            if let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(value)
            }
        case .inlineEmoji(let value):
            Text(value)
                .font(.system(size: 32))
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.6))
                        .tracking(0.5)
                }
                Text(code)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.9))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color(red: 0.118, green: 0.118, blue: 0.118))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .linkPreview(let url):
            Link(destination: url) {
                Text(url.absoluteString)
                    .foregroundColor(.blue)
                    .underline()
            }
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
        }
    }

    private var sheetBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.1, green: 0.1, blue: 0.1)
            : ChatFlowTheme.cream(colorScheme)
    }
}
