//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ChatView")

// MARK: - ⚠️⚠️⚠️ CRITICAL: DO NOT MODIFY WITHOUT READING ⚠️⚠️⚠️
//
// This file contains a non-obvious keyboard positioning fix that took 7+ iterations to solve.
// If you are an AI agent or developer planning to modify keyboard/focus/state handling here,
// STOP and read this entire comment block first.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE PROBLEM
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// MessageInputBar needs to reposition when keyboard appears:
// - Keyboard HIDDEN: Concentric alignment with device corners (~26pt from edges)
// - Keyboard VISIBLE: Positioned above keyboard with smaller gap
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHY "OBVIOUS" SOLUTIONS FAIL
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// SwiftUI ties @State, @FocusState, and onChange to a view's IDENTITY. When identity changes,
// ALL state resets silently. Views inside .safeAreaInset get RECREATED when geometry changes
// (like keyboard appearing), which resets their state.
//
// THESE APPROACHES WERE TRIED AND FAILED:
//
// 1. @FocusState in MessageInputBar
//    → View recreated on keyboard appear → @FocusState resets → onChange never fires
//
// 2. @State in MessageInputBar for keyboard tracking
//    → Same problem: view recreation resets state
//
// 3. UIKit keyboard notifications in MessageInputBar
//    → onReceive fires, but @State mutation is lost when view recreates
//
// 4. Passing computed Bool from parent
//    → .safeAreaInset content doesn't re-render on parent state change
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE SOLUTION (DO NOT CHANGE WITHOUT UNDERSTANDING)
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// 1. @State isInputFocused lives HERE in ChatView (stable parent, survives geometry changes)
// 2. MessageInputBar reports focus via callback: onFocusChange: { isInputFocused = $0 }
// 3. Offset modifier applied HERE in ChatView (modifiers on .safeAreaInset content DO update)
//
// KEY INSIGHT: .safeAreaInset content body doesn't re-render on parent state change,
// BUT modifiers applied TO that content from the parent DO update.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// IF YOU MUST MODIFY THIS CODE
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// 1. Understand SwiftUI view identity and state lifetime
// 2. Understand why .safeAreaInset causes view recreation
// 3. Test on device with keyboard show/hide cycling
// 4. Verify concentric alignment visually (equal padding on all sides when keyboard hidden)
// 5. The working solution is tagged: `working-keyboard-behaviors`
//
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var toastManager: ToastManager
    @Environment(\.scenePhase) private var scenePhase

    // ⚠️ CRITICAL: This state MUST live here in ChatView, NOT in MessageInputBar.
    // MessageInputBar is inside .safeAreaInset and gets recreated on geometry changes.
    // State in recreated views resets silently. See header comment for full explanation.
    @State private var isInputFocused = false
    @State private var selectionRange = NSRange(location: 0, length: 0)
    @State private var showAttachmentMenu = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var focusRequestID = 0
    @State private var shouldRestoreFocusAfterPicker = false

    init(auth: any AuthManaging,
         chatService: any ChatServicing,
         settings: SettingsManager,
         device: any DeviceIdentifying,
         uploadService: any UploadServicing,
         toastManager: ToastManager) {
        _toastManager = State(initialValue: toastManager)
        _viewModel = State(initialValue: ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: settings,
            device: device,
            uploadService: uploadService,
            toastManager: toastManager
        ))
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass


    var body: some View {
        @Bindable var viewModel = viewModel
        @Bindable var toastManager = toastManager

        GeometryReader { geometry in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    messageList(topInset: 60)
                        .frame(maxHeight: .infinity)

                    if let error = viewModel.error {
                        errorBanner(error)
                    }
                }
                // ═══════════════════════════════════════════════════════════════════════════════
                // ⚠️ CRITICAL SECTION - READ HEADER COMMENT BEFORE MODIFYING ⚠️
                // ═══════════════════════════════════════════════════════════════════════════════
                //
                // This .safeAreaInset block is where the keyboard positioning fix is implemented.
                // The content inside gets RECREATED when geometry changes (keyboard show/hide).
                //
                // WHY THE OFFSET IS APPLIED HERE (not in MessageInputBar):
                // - MessageInputBar's body won't re-render when parent state changes
                // - BUT modifiers applied TO MessageInputBar from here DO update
                // - So we calculate offset here using parent's @State isInputFocused
                //
                // WHY onFocusChange CALLBACK (not @FocusState in MessageInputBar):
                // - @FocusState in MessageInputBar resets when view recreates
                // - Callback allows MessageInputBar to report focus to stable parent
                // - Parent's @State survives the geometry change
                //
                .safeAreaInset(edge: .bottom) {
                    // Positive offset pushes bar DOWN into safe area for concentric alignment.
                    // When focused (keyboard visible), offset is 0 (bar sits above keyboard).
                    let rawOffset = calculateConcentricOffset(bottomInset: geometry.safeAreaInsets.bottom)
                    let concentricOffset = isInputFocused ? 0 : rawOffset

                    MessageInputBar(
                        content: $viewModel.inputContent,
                        selectionRange: $selectionRange,
                        canSend: viewModel.canSend,
                        isSending: viewModel.isSending,
                        connectionAlert: viewModel.connectionAlert,
                        focusTrigger: focusRequestID,
                        bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                        isKeyboardVisible: isInputFocused,
                        onSend: { viewModel.send() },
                        onCancel: { viewModel.cancelSend() },
                        onAdd: {
                            logger.info("Attachment menu requested")
                            showAttachmentMenu = true
                        },
                        // ⚠️ This callback is how focus state survives view recreation.
                        // DO NOT replace with @Binding or try to use @FocusState directly.
                        onFocusChange: { focused in isInputFocused = focused }
                    )
                    // ⚠️ Offset MUST be applied here, not inside MessageInputBar.
                    // See header comment for why.
                    .offset(y: concentricOffset)
                    .animation(.easeOut(duration: 0.25), value: concentricOffset)
                }

                if let toast = toastManager.toast {
                    ToastBanner(message: toast.message) {
                        toastManager.dismiss()
                    }
                    .padding(.top, geometry.safeAreaInsets.top + 12)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background {
            ChatFlowTheme.pageBackground(colorScheme)
                .ignoresSafeArea()
                .overlay(NoiseOverlayView().ignoresSafeArea())
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            viewModel.handleSceneDidBecomeActive()
        }
        .sheet(isPresented: $showAttachmentMenu) {
            AttachmentSourceSheet(
                onCamera: {
                    showAttachmentMenu = false
                    presentCamera()
                },
                onPhotos: {
                    showAttachmentMenu = false
                    prepareForAttachmentPicker()
                    showPhotoPicker = true
                },
                onFiles: {
                    showAttachmentMenu = false
                    prepareForAttachmentPicker()
                    showFilePicker = true
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(
                onImage: { image in
                    showCamera = false
                    Task {
                        await handleCapturedImage(image)
                        await MainActor.run { restoreFocusIfNeeded() }
                    }
                },
                onCancel: {
                    showCamera = false
                    restoreFocusIfNeeded()
                }
            )
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(
                selectionLimit: 0,
                onPick: { results in
                    showPhotoPicker = false
                    Task {
                        await handlePhotoResults(results)
                        await MainActor.run { restoreFocusIfNeeded() }
                    }
                },
                onCancel: {
                    showPhotoPicker = false
                    restoreFocusIfNeeded()
                }
            )
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(
                contentTypes: [.item],
                onPick: { urls in
                    showFilePicker = false
                    Task {
                        await handleDocumentResults(urls)
                        await MainActor.run { restoreFocusIfNeeded() }
                    }
                },
                onCancel: {
                    showFilePicker = false
                    restoreFocusIfNeeded()
                }
            )
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toastManager.toast)
    }

    private func messageList(topInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                let isCompact = horizontalSizeClass == .compact
                let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
                let maxWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)

                FlowLayout(
                    itemSpacing: metrics.flowGap,
                    rowSpacing: metrics.flowGap,
                    maxLineWidth: maxWidth,
                    isCompact: isCompact
                ) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .messageFailureIndicator(viewModel.failureMessage(for: message.id))
                    }
                }
                .padding(metrics.containerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.top, topInset, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .foregroundColor(.white)
            Spacer()
            Button("Dismiss") { viewModel.clearError() }
                .foregroundColor(.white)
        }
        .padding()
        .background(Color.red)
    }

    @MainActor
    private func prepareForAttachmentPicker() {
        shouldRestoreFocusAfterPicker = isInputFocused
    }

    @MainActor
private func restoreFocusIfNeeded() {
        guard shouldRestoreFocusAfterPicker else { return }
        focusRequestID &+= 1
        shouldRestoreFocusAfterPicker = false
    }

    @MainActor
    private func presentCamera() {
        prepareForAttachmentPicker()
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            toastManager.show(error: .cameraUnavailable)
            restoreFocusIfNeeded()
            return
        }
        showCamera = true
    }

    private func handleCapturedImage(_ image: UIImage) async {
        guard let attachment = makeImageAttachment(from: image, suggestedFilename: "camera.jpg") else {
            await MainActor.run { toastManager.show(error: .invalidData) }
            return
        }
        await MainActor.run {
            insertAttachments([attachment])
        }
    }

    private func handlePhotoResults(_ results: [PHPickerResult]) async {
        var attachments: [PendingAttachment] = []
        for result in results {
            if let attachment = await loadPhotoAttachment(from: result) {
                attachments.append(attachment)
            }
        }
        if attachments.isEmpty {
            await MainActor.run { toastManager.show(error: .invalidData) }
            return
        }
        await MainActor.run {
            insertAttachments(attachments)
        }
    }

    private func handleDocumentResults(_ urls: [URL]) async {
        var attachments: [PendingAttachment] = []
        for url in urls {
            do {
                let attachment = try loadDocumentAttachment(from: url)
                attachments.append(attachment)
            } catch let attachmentError as AttachmentError {
                await MainActor.run { toastManager.show(error: attachmentError) }
            } catch {
                await MainActor.run { toastManager.show(error.localizedDescription) }
            }
        }
        guard !attachments.isEmpty else { return }
        await MainActor.run {
            insertAttachments(attachments)
        }
    }

    @MainActor
    private func insertAttachments(_ attachments: [PendingAttachment]) {
        guard !attachments.isEmpty else { return }
        let mutable = NSMutableAttributedString(attributedString: viewModel.inputContent)
        let safeRange = clamp(selectionRange, length: mutable.length)
        mutable.replaceCharacters(in: safeRange, with: NSAttributedString(string: ""))
        var insertionLocation = safeRange.location
        for attachment in attachments {
            let textAttachment = PendingTextAttachment(
                id: attachment.id,
                thumbnail: attachment.thumbnail,
                accessibilityLabel: attachment.accessibilityLabel
            )
            let attachmentString = NSAttributedString(attachment: textAttachment)
            mutable.insert(attachmentString, at: insertionLocation)
            insertionLocation += attachmentString.length
        }
        viewModel.stageAttachments(attachments)
        viewModel.inputContent = mutable
        selectionRange = NSRange(location: insertionLocation, length: 0)
    }

    private func clamp(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let safeLocation = min(max(range.location, 0), length)
        let maxLength = max(0, min(range.length, length - safeLocation))
        return NSRange(location: safeLocation, length: maxLength)
    }

    private func loadPhotoAttachment(from result: PHPickerResult) async -> PendingAttachment? {
        let provider = result.itemProvider
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        do {
            let image = try await loadImage(from: provider)
            return makeImageAttachment(from: image, suggestedFilename: provider.suggestedName)
        } catch {
            return nil
        }
    }

    private func loadImage(from provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let image = object as? UIImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: AttachmentError.invalidData)
                }
            }
        }
    }

    private func loadDocumentAttachment(from url: URL) throws -> PendingAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw AttachmentError.invalidData }
        let mimeType = mimeType(for: url)
        let thumbnail = makeDocumentThumbnail()
        return PendingAttachment(
            id: UUID(),
            data: data,
            thumbnail: thumbnail,
            mimeType: mimeType,
            filename: url.lastPathComponent
        )
    }

    private func makeImageAttachment(from image: UIImage, suggestedFilename: String?) -> PendingAttachment? {
        guard let (data, mimeType) = encodeImage(image) else { return nil }
        return PendingAttachment(
            id: UUID(),
            data: data,
            thumbnail: makeThumbnail(from: image),
            mimeType: mimeType,
            filename: suggestedFilename
        )
    }

    private func encodeImage(_ image: UIImage) -> (Data, String)? {
        if let data = image.jpegData(compressionQuality: 0.85) {
            return (data, "image/jpeg")
        }
        if let data = image.pngData() {
            return (data, "image/png")
        }
        return nil
    }

    private func makeThumbnail(from image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 120
        let scale = min(maxDimension / max(image.size.width, image.size.height), 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func makeDocumentThumbnail() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.systemGray5.setFill()
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
            path.fill()

            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            let symbol = UIImage(systemName: "doc.fill", withConfiguration: symbolConfig)?
                .withRenderingMode(.alwaysTemplate)
            UIColor.systemBlue.setFill()
            symbol?.draw(in: rect.insetBy(dx: 16, dy: 16))
        }
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private struct ToastBanner: View {
        let message: String
        let dismiss: () -> Void

        var body: some View {
            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: Capsule())
                .onTapGesture(perform: dismiss)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { value in
                            if value.translation.height < -10 {
                                dismiss()
                            }
                        }
                )
                .accessibilityLabel(message)
                .accessibilityHint("Dismiss with tap or swipe up.")
                .accessibilityAddTraits(.isStaticText)
                .onAppear {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
        }
    }

    /// Calculate concentric offset to align input bar with device corner radius.
    /// Returns ~16pt when keyboard hidden, 0pt when keyboard visible (handled by caller).
    private func calculateConcentricOffset(bottomInset: CGFloat) -> CGFloat {
        // Device corner radius: ~50pt for Face ID devices, 0pt for home button devices
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        let deviceCornerRadius: CGFloat = hasRoundedCorners ? 50 : 0

        let inputBarHeight: CGFloat = 48
        let elementSpacing: CGFloat = 8
        let concentricPadding = max(deviceCornerRadius - (inputBarHeight / 2), 8)

        let minSafeArea: CGFloat = 34
        let maxSafeArea: CGFloat = 100
        let maxOffset = max(minSafeArea - concentricPadding + elementSpacing, 0)
        let t = (bottomInset - minSafeArea) / (maxSafeArea - minSafeArea)
        let clampedT = max(0, min(1, t))
        return maxOffset * (1 - clampedT)
    }
}

private struct MessageFailureModifier: ViewModifier {
    let reason: String?

    func body(content: Content) -> some View {
        if let reason {
            content
                .padding(.bottom, 32)
                .overlay(alignment: .bottomLeading) {
                    MessageFailureBadge(reason: reason)
                        .offset(y: 18)
                }
        } else {
            content
        }
    }
}

private struct MessageFailureBadge: View {
    let reason: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
            Text(reason)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundColor(labelColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(backgroundColor)
        )
        .accessibilityLabel("Message failed. \(reason)")
    }

    private var labelColor: Color {
        colorScheme == .dark ? Color.yellow : Color(red: 0.6, green: 0.12, blue: 0.12)
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.yellow.opacity(0.15)
            : Color(red: 0.98, green: 0.92, blue: 0.92)
    }
}

private extension View {
    func messageFailureIndicator(_ reason: String?) -> some View {
        modifier(MessageFailureModifier(reason: reason))
    }
}

// MARK: - Previews

@Observable
private final class PreviewAuthManager: AuthManaging {
    var isAuthenticated = true
    var currentUserId: String? = "preview-user"
    var token: String? = "preview-token"
    func storeCredentials(token: String, userId: String) {}
    func clearCredentials() {}
}

private struct PreviewDevice: DeviceIdentifying {
    let deviceId = "preview-device"
}

private final class PreviewChatService: ChatServicing {
    var incomingMessages: AsyncStream<Message> {
        AsyncStream { _ in }
    }
    var connectionState: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }
    var serviceEvents: AsyncStream<ChatServiceEvent> {
        AsyncStream { _ in }
    }
    func connect(token: String, lastMessageId: String?) async throws {}
    func disconnect() {}
    func send(id: String, content: String, attachments: [WireAttachment]) async throws {}
}

private struct AttachmentSourceSheet: View {
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(.secondary.opacity(0.4))
                .frame(width: 40, height: 4)
                .padding(.top, 12)

            Text("Add Attachment")
                .font(.headline)

            VStack(spacing: 12) {
                Button {
                    onCamera()
                } label: {
                    Label("Camera", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AttachmentActionStyle())

                Button {
                    onPhotos()
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AttachmentActionStyle())

                Button {
                    onFiles()
                } label: {
                    Label("Files", systemImage: "doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AttachmentActionStyle())
            }
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .presentationDragIndicator(.visible)
    }
}

private struct AttachmentActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private final class PreviewUploadService: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String { "preview-asset" }
    func download(assetId: String) async throws -> Data { Data() }
}

#Preview("Empty Chat") {
    let device = PreviewDevice()
    return ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device,
        uploadService: PreviewUploadService(),
        toastManager: ToastManager()
    )
}

#Preview("With Messages") {
    let device = PreviewDevice()
    return ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device,
        uploadService: PreviewUploadService(),
        toastManager: ToastManager()
    )
}
