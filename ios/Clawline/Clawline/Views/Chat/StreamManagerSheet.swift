//
//  StreamManagerSheet.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI
import UIKit
#if canImport(GameController)
import GameController
#endif

enum StreamPopupSearchPresentationFocusPolicy {
    static func shouldRenderSearchTextFieldOnInitialPresentation(searchFocusRequestID: Int?) -> Bool {
        searchFocusRequestID != nil
    }
}

struct StreamManagerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings

    @Bindable var viewModel: ChatViewModel
    let streams: [StreamSession]
    let dotStateLookup: StreamDotStateLookup
    let searchFocusRequestID: Int?
    let maxAvailableHeight: CGFloat
    let maxAvailableWidth: CGFloat
    let onSelectStream: (String) -> Void
    let onRequestTrackPicker: () -> Void
    let onConsumeSearchFocusRequest: () -> Void
    let onShortcutOwnershipChange: ([String]) -> Void

    @State private var draftName = ""
    @State private var searchQuery = ""
    @State private var activeEditor: EditorMode?
    @State private var isWorking = false
    @State private var resolvedHardwareKeyboardShortcutsAvailable = false
    @State private var removingSessionKeys: Set<String> = []
    @State private var pendingCreateRows: [PendingCreateRow] = []
    @State private var pendingRemovalStream: StreamSession?
    @State private var selectedStreamSessionKey: String?
    @State private var didActivateSelection = false
    @State private var isSearchFieldFocusEnabled = false
    @FocusState private var focusedEditor: EditorMode?
    @FocusState private var isSearchFieldFocused: Bool

    private enum EditorMode: Hashable {
        case renaming(String)
    }

    private struct PendingCreateRow: Identifiable, Hashable {
        let id: UUID
        let displayName: String
    }

    private let listRowHeight: CGFloat = 52
    private let listRowSpacing: CGFloat = 2
    private let listRowHorizontalInset: CGFloat = 12
    private let functionBarHeight: CGFloat = 40
    private let actionBarTopPadding: CGFloat = 12
    private let actionBarBottomPadding: CGFloat = 20
    private let listOuterVerticalPadding: CGFloat = 20
    private let minimumPopoverHeight: CGFloat = 140
    private let minimumPopoverWidth: CGFloat = 280
    private let baselineIdealPopoverWidth: CGFloat = 320
    private let baselineMaximumPopoverWidth: CGFloat = 360
    private let popupCornerRadius: CGFloat = 20
    private let actionBarSeparatorInset: CGFloat = 12
    private let rowDotDiameter: CGFloat = 8
    private let rowContentSpacing: CGFloat = 10
    private let rowTrailingAccessoryReserve: CGFloat = 28
    private let shortcutLabelReservedWidth: CGFloat = 58

    private var maximumPopoverWidth: CGFloat {
        max(baselineMaximumPopoverWidth, floor(maxAvailableWidth * 0.8))
    }

    private var idealPopoverWidth: CGFloat {
        let visibleNames = filteredStreams.map(\.displayName) + filteredPendingCreateRows.map(\.displayName)
        let titleFont = UIFont.clawline(.subsectionHeader)
        let longestTitleWidth = visibleNames
            .map { ceil(($0 as NSString).size(withAttributes: [.font: titleFont]).width) }
            .max() ?? 0
        return StreamSelectorLayout.popupWidth(
            longestItemWidth: longestTitleWidth,
            minimumPopoverWidth: minimumPopoverWidth,
            baselineIdealPopoverWidth: baselineIdealPopoverWidth,
            maximumPopoverWidth: maximumPopoverWidth,
            rowHorizontalInset: listRowHorizontalInset,
            rowContentSpacing: rowContentSpacing,
            leadingDotDiameter: rowDotDiameter,
            trailingAccessoryReserve: rowTrailingAccessoryReserve
        )
    }

    private var actionBarContentHeight: CGFloat {
        functionBarHeight + actionBarTopPadding + actionBarBottomPadding
    }

    private var actionBarReservedHeight: CGFloat {
        actionBarContentHeight
    }

    private var actionBarSeparatorHeight: CGFloat {
        1 / max(UITraitCollection.current.displayScale, 1)
    }

    private var actionBarSeparatorColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.34)
    }

    private var listItemCount: Int {
        filteredStreams.count + filteredPendingCreateRows.count
    }

    private var filteredStreams: [StreamSession] {
        StreamSelectorLayout.filter(streams: streams, query: searchQuery)
    }

    private var filteredStreamSessionKeys: [String] {
        filteredStreams.map(\.sessionKey)
    }

    private var selectorShortcutsAvailable: Bool {
        resolvedHardwareKeyboardShortcutsAvailable
    }

    private var selectableShortcutSessionKeys: [String] {
        selectableShortcutSessionKeys(shortcutsAvailable: selectorShortcutsAvailable)
    }

    private var filteredPendingCreateRows: [PendingCreateRow] {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return pendingCreateRows
        }
        return pendingCreateRows.filter {
            StreamSelectorLayout.matchesStreamName($0.displayName, query: searchQuery)
        }
    }

    private var listContentHeight: CGFloat {
        StreamSelectorLayout.listContentHeight(
            itemCount: listItemCount,
            showsCreateInlineRow: false,
            rowHeight: listRowHeight,
            rowSpacing: listRowSpacing,
            outerVerticalPadding: listOuterVerticalPadding
        )
    }

    var body: some View {
        let _ = settings.fontScaleChangeSequence
        let idealVerticalLayout = StreamSelectorLayout.popupVerticalLayout(
            itemCount: listItemCount,
            showsCreateInlineRow: false,
            rowHeight: listRowHeight,
            rowSpacing: listRowSpacing,
            actionBarHeight: actionBarReservedHeight,
            outerVerticalPadding: listOuterVerticalPadding,
            maxAvailableHeight: maxAvailableHeight,
            minimumPopoverHeight: minimumPopoverHeight
        )
        let heightFrame = StreamSelectorLayout.popupHeightFrame(
            idealContainerHeight: idealVerticalLayout.containerHeight,
            minimumPopoverHeight: minimumPopoverHeight,
            isSpatial: Self.isSpatialPlatform
        )
        let rowDotStates = StreamSelectorLayout.dotStatesBySession(
            streams: filteredStreams,
            lookup: dotStateLookup
        )
        GeometryReader { geometry in
            let containerHeight = StreamSelectorLayout.popupContainerHeight(
                idealContainerHeight: idealVerticalLayout.containerHeight,
                allocatedContainerHeight: geometry.size.height,
                isSpatial: Self.isSpatialPlatform
            )
            let listViewportHeight = StreamSelectorLayout.listViewportHeight(
                containerHeight: containerHeight,
                actionBarReservedHeight: actionBarReservedHeight
            )
            VStack(spacing: 0) {
                List {
                    ForEach(filteredStreams) { stream in
                        streamRow(
                            for: stream,
                            dotState: rowDotStates[stream.sessionKey] ?? .inactive
                        )
                    }

                    ForEach(filteredPendingCreateRows) { pendingRow in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.primary.opacity(0.18))
                                .frame(width: 8, height: 8)
                            Text(pendingRow.displayName)
                                .font(.clawline(.subsectionHeader).weight(.regular))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ProgressView()
                                .controlSize(.small)
                                .tint(.secondary)
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .frame(height: listRowHeight, alignment: .center)
                        .listRowInsets(
                            EdgeInsets(
                                top: 0,
                                leading: listRowHorizontalInset,
                                bottom: 0,
                                trailing: listRowHorizontalInset
                            )
                        )
                        .contentShape(Rectangle())
                    }

                    if filteredStreams.isEmpty && filteredPendingCreateRows.isEmpty {
                        Text("No streams found")
                            .font(.clawline(.secondaryLabel))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .frame(height: listRowHeight, alignment: .center)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 0,
                                    leading: listRowHorizontalInset,
                                    bottom: 0,
                                    trailing: listRowHorizontalInset
                                )
                            )
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, listRowHeight)
                .listRowSpacing(listRowSpacing)
                .scrollBounceBehavior(.always)
                .contentMargins(.top, listOuterVerticalPadding, for: .scrollContent)
                .contentMargins(.bottom, listOuterVerticalPadding, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(height: listViewportHeight)
                .clipShape(Rectangle())
                .disabled(isWorking)

                bottomActionBar
            }
            .frame(width: geometry.size.width, height: containerHeight, alignment: .top)
        }
        .frame(height: heightFrame.fixedHeight, alignment: .top)
        .frame(
            minWidth: minimumPopoverWidth,
            idealWidth: idealPopoverWidth,
            maxWidth: maximumPopoverWidth
        )
        .frame(
            // Clamp the floor to the capped height so we never produce an inconsistent
            // (minHeight > maxHeight) frame when the window is shorter than our preferred minimum.
            minHeight: heightFrame.minHeight,
            idealHeight: heightFrame.idealHeight,
            maxHeight: heightFrame.maxHeight,
            alignment: .top
        )
        .background(Color.clear)
        // Hard-clip at the popup's own corner radius so any late-updating list content
        // cannot visually bleed past the popup bounds when the popover system reallocates height.
        .clipShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .background {
            selectorShortcutKeyCommandBridge
        }
        .onAppear {
            refreshShortcutAvailabilityAndPublish()
            syncSelectionWithFilteredStreams()
            handleInitialSearchFocus(searchFocusRequestID)
        }
        .onDisappear {
            onShortcutOwnershipChange([])
            resetInlineEditing()
            searchQuery = ""
            isSearchFieldFocused = false
            isSearchFieldFocusEnabled = false
            selectedStreamSessionKey = nil
            didActivateSelection = false
        }
        .onChange(of: searchFocusRequestID) { _, requestID in
            handleSearchFocusRequest(requestID)
        }
        .onChange(of: searchQuery) { _, _ in
            syncSelectionWithFilteredStreams()
            publishShortcutOwnership()
        }
        .onChange(of: streams.map(\.sessionKey)) { _, _ in
            syncSelectionWithFilteredStreams()
            publishShortcutOwnership()
        }
        .onChange(of: selectableShortcutSessionKeys) { _, _ in
            publishShortcutOwnership()
        }
        .onKeyPress(characters: .decimalDigits) { keyPress in
            handleSelectorShortcutKeyPress(keyPress)
        }
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(GameController)
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            refreshShortcutAvailabilityAndPublish()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            refreshShortcutAvailabilityAndPublish()
        }
#endif
        .alert(
            pendingRemovalTitle,
            isPresented: Binding(
                get: { pendingRemovalStream != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRemovalStream = nil
                    }
                }
            ),
            presenting: pendingRemovalStream
        ) { stream in
            Button("Cancel", role: .cancel) {}
            Button(removalActionTitle(for: stream), role: .destructive) {
                pendingRemovalStream = nil
                Task { await removeStream(stream) }
            }
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                searchField
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        focusSearchField()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear stream filter")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: functionBarHeight)
            .contentShape(Rectangle())

            if viewModel.canUseTrackFeature {
                Button {
                    onRequestTrackPicker()
                } label: {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.clear)
                        .frame(width: functionBarHeight, height: functionBarHeight, alignment: .center)
                        .overlay {
                            Image(systemName: "eye")
                                .font(.clawline(.subsectionHeader).weight(.regular))
                                .foregroundStyle(.primary)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(activeEditor != nil || isWorking)
                .accessibilityLabel("Track")
                .accessibilityHint("Tracks an existing untracked session")
            }

            // Keep add affordance optically centered in a fixed-height toolbar regardless of keyboard changes.
            Button {
                addStreamDirectly()
            } label: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: functionBarHeight, height: functionBarHeight, alignment: .center)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.clawline(.subsectionHeader).weight(.regular))
                            .foregroundStyle(.primary)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(activeEditor != nil)
            .accessibilityLabel("Add stream")
            .accessibilityHint("Creates a new stream")
        }
        .padding(.horizontal, listRowHorizontalInset)
        .padding(.top, actionBarTopPadding)
        .padding(.bottom, actionBarBottomPadding)
        .overlay(alignment: .top) {
            sectionSeparator
        }
    }

    private var selectorShortcutKeyCommandBridge: some View {
        StreamSelectorShortcutKeyCommandBridge(
            selectableSessionKeys: selectorShortcutsAvailable ? selectableShortcutSessionKeys : [],
            isSearchFieldFocused: isSearchFieldFocused
        )
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var searchField: some View {
        if isSearchFieldFocusEnabled {
            TextField("Filter…", text: $searchQuery)
                .font(.clawline(.uiLabel))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    selectHighlightedStream()
                }
                .onKeyPress(.upArrow) {
                    moveSelection(step: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(step: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    selectHighlightedStream()
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits) { keyPress in
                    handleSelectorShortcutKeyPress(keyPress)
                }
        } else {
            Button {
                isSearchFieldFocusEnabled = true
                focusSearchField()
            } label: {
                Text("Filter…")
                    .font(.clawline(.uiLabel))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter streams")
        }
    }

    @ViewBuilder
    private func streamRow(for stream: StreamSession, dotState: StreamDotState) -> some View {
        rowContent(for: stream, dotState: dotState)
            .frame(height: listRowHeight, alignment: .center)
            .listRowInsets(
                EdgeInsets(
                    top: 0,
                    leading: listRowHorizontalInset,
                    bottom: 0,
                    trailing: listRowHorizontalInset
                )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(rowBackground(for: stream))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    beginRenaming(stream)
                } label: {
                    Image(systemName: "pencil")
                        .font(.title3.weight(.semibold))
                }
                .accessibilityLabel("Rename")
                .disabled(!canPerformRenameAction(for: stream))
                .tint(canPerformRenameAction(for: stream) ? .blue : Color.gray.opacity(0.35))

                Button {
                    pendingRemovalStream = stream
                } label: {
                    Image(systemName: removalActionImage(for: stream))
                        .font(.title3.weight(.semibold))
                }
                .accessibilityLabel(removalActionTitle(for: stream))
                .disabled(!canPerformRemovalAction(for: stream))
                .tint(canPerformRemovalAction(for: stream) ? .red : Color.gray.opacity(0.35))
            }
            .streamRowContextMenu(
                isPresented: activeEditor != .renaming(stream.sessionKey),
                renameEnabled: canPerformRenameAction(for: stream),
                removalEnabled: canPerformRemovalAction(for: stream),
                removalTitle: removalActionTitle(for: stream),
                removalImage: removalActionImage(for: stream),
                onRename: { beginRenaming(stream) },
                onRemove: { pendingRemovalStream = stream }
            )
    }

    @ViewBuilder
    private func rowContent(for stream: StreamSession, dotState: StreamDotState) -> some View {
        if activeEditor == .renaming(stream.sessionKey) {
            TextField("Stream name", text: $draftName)
                .font(.clawline(.subsectionHeader))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .focused($focusedEditor, equals: .renaming(stream.sessionKey))
                .onSubmit {
                    Task { await renameStream(stream) }
                }
        } else {
            Button {
                let selectedSessionKey = stream.sessionKey
                onSelectStream(selectedSessionKey)
            } label: {
                let isActive = stream.sessionKey == viewModel.uiSelectedSessionKey
                let dotIdentity = StreamPopupRowStatusDotIdentity(
                    sessionKey: stream.sessionKey,
                    dotState: dotState,
                    isActive: isActive,
                    colorScheme: colorScheme
                )
                HStack(spacing: 10) {
                    StreamPopupRowStatusDot(
                        isActive: isActive,
                        dotState: dotState,
                        colorScheme: colorScheme
                    )
                    .id(dotIdentity)
                    Text(stream.displayName)
                        .font(.clawline(.subsectionHeader).weight(isActive ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isRemovingStream(stream.sessionKey) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                    shortcutLabel(for: stream)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isRemovingStream(stream.sessionKey))
            .accessibilityHint(accessibilityShortcutLabel(for: stream).map { "Shortcut \($0)" } ?? "")
        }
    }

    @ViewBuilder
    private func shortcutLabel(for stream: StreamSession) -> some View {
        if let label = shortcutLabelText(for: stream) {
            Text(label)
                .font(.clawline(.secondaryLabel))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: shortcutLabelReservedWidth, alignment: .trailing)
                .accessibilityLabel(StreamSelectorShortcutMap.accessibilityLabel(forShortcutLabel: label))
        }
    }

    private func rowBackground(for stream: StreamSession) -> some View {
        let highlight = StreamSelectorLayout.selectionHighlightStyle(
            isSelected: selectedStreamSessionKey == stream.sessionKey,
            isDark: colorScheme == .dark,
            isSpatial: Self.isSpatialPlatform
        )
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(highlight.fillOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(highlight.strokeOpacity),
                        lineWidth: highlight.strokeLineWidth
                    )
            }
            .padding(.vertical, 2)
    }

    private static var isSpatialPlatform: Bool {
#if os(visionOS)
        true
#else
        false
#endif
    }

    private func beginRenaming(_ stream: StreamSession) {
        activeEditor = .renaming(stream.sessionKey)
        draftName = stream.displayName
        Task { @MainActor in
            focusedEditor = .renaming(stream.sessionKey)
        }
    }

    private func resetInlineEditing() {
        activeEditor = nil
        draftName = ""
        focusedEditor = nil
        removingSessionKeys.removeAll()
        pendingCreateRows.removeAll()
        pendingRemovalStream = nil
    }

    private func canPerformRenameAction(for stream: StreamSession) -> Bool {
        guard !isWorking else { return false }
        guard !isRemovingStream(stream.sessionKey) else { return false }
        guard activeEditor != .renaming(stream.sessionKey) else { return false }
        return viewModel.canRenameStream(sessionKey: stream.sessionKey)
    }

    private func canPerformRemovalAction(for stream: StreamSession) -> Bool {
        guard !isWorking else { return false }
        guard !isRemovingStream(stream.sessionKey) else { return false }
        guard activeEditor != .renaming(stream.sessionKey) else { return false }
        return viewModel.isAdoptedStream(sessionKey: stream.sessionKey)
            ? viewModel.canUntrackStream(sessionKey: stream.sessionKey)
            : viewModel.canDeleteStream(sessionKey: stream.sessionKey)
    }

    private func isRemovingStream(_ sessionKey: String) -> Bool {
        removingSessionKeys.contains(sessionKey)
    }

    private func addStreamDirectly() {
        let existingCount = streams.count + pendingCreateRows.count
        let name = "Stream \(existingCount + 1)"
        let pendingID = UUID()
        pendingCreateRows.append(PendingCreateRow(id: pendingID, displayName: name))

        Task {
            _ = await viewModel.createStream(displayName: name)
            await MainActor.run {
                pendingCreateRows.removeAll { $0.id == pendingID }
            }
        }
    }

    private func focusSearchField() {
        isSearchFieldFocusEnabled = true
        Task { @MainActor in
            await Task.yield()
            isSearchFieldFocused = true
            syncSelectionWithFilteredStreams()
        }
    }

    private func handleSearchFocusRequest(_ requestID: Int?) {
        guard requestID != nil else { return }
        focusSearchField()
        onConsumeSearchFocusRequest()
    }

    private func handleInitialSearchFocus(_ requestID: Int?) {
        isSearchFieldFocusEnabled = StreamPopupSearchPresentationFocusPolicy
            .shouldRenderSearchTextFieldOnInitialPresentation(searchFocusRequestID: requestID)
        guard requestID != nil else {
            isSearchFieldFocused = false
            return
        }
        handleSearchFocusRequest(requestID)
    }

    private func syncSelectionWithFilteredStreams() {
        selectedStreamSessionKey = StreamSelectorLayout.resolvedSelection(
            preferredSessionKey: selectedStreamSessionKey,
            activeSessionKey: viewModel.uiSelectedSessionKey,
            sessionKeys: filteredStreamSessionKeys
        )
        didActivateSelection = false
    }

    private func moveSelection(step: Int) {
        selectedStreamSessionKey = StreamSelectorLayout.selectionAfterMoving(
            currentSessionKey: selectedStreamSessionKey,
            sessionKeys: filteredStreamSessionKeys,
            step: step
        )
        didActivateSelection = false
    }

    private func selectHighlightedStream() {
        guard !didActivateSelection else { return }
        syncSelectionWithFilteredStreams()
        guard let selectedStreamSessionKey = StreamSelectorLayout.activationTarget(
            selectedSessionKey: selectedStreamSessionKey,
            didActivateSelection: didActivateSelection
        ) else { return }
        didActivateSelection = true
        onSelectStream(selectedStreamSessionKey)
    }

    private func handleSelectorShortcutKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard let intent = StreamSelectorShortcutActivation.intent(
            characters: keyPress.characters,
            modifiers: keyPress.modifiers
        ),
              case .notificationAssignedOpen(let slot) = intent,
              StreamSelectorShortcutMap.sessionKey(
                forSlot: slot,
                selectableSessionKeys: selectableShortcutSessionKeys
              ) != nil else {
            return .ignored
        }
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: intent)
        return .handled
    }

    private func publishShortcutOwnership() {
        onShortcutOwnershipChange(selectableShortcutSessionKeys)
    }

    private func refreshShortcutAvailabilityAndPublish() {
        let shortcutsAvailable = CrossChatShortcutLabelAvailability.current
        resolvedHardwareKeyboardShortcutsAvailable = shortcutsAvailable
        onShortcutOwnershipChange(selectableShortcutSessionKeys(shortcutsAvailable: shortcutsAvailable))
    }

    private func selectableShortcutSessionKeys(shortcutsAvailable: Bool) -> [String] {
        let renamingSessionKey: String? = {
            guard case .renaming(let sessionKey) = activeEditor else { return nil }
            return sessionKey
        }()
        return StreamSelectorShortcutMap.selectableSessionKeys(
            filteredSessionKeys: filteredStreamSessionKeys,
            shortcutsAvailable: shortcutsAvailable,
            isWorking: isWorking,
            removingSessionKeys: removingSessionKeys,
            renamingSessionKey: renamingSessionKey
        )
    }

    private func shortcutLabelText(for stream: StreamSession) -> String? {
        guard selectorShortcutsAvailable,
              let slot = StreamSelectorShortcutMap.slot(
                forSessionKey: stream.sessionKey,
                selectableSessionKeys: selectableShortcutSessionKeys
              ) else { return nil }
        return StreamSelectorShortcutMap.shortcutLabel(forSlot: slot)
    }

    private func accessibilityShortcutLabel(for stream: StreamSession) -> String? {
        shortcutLabelText(for: stream).map(StreamSelectorShortcutMap.accessibilityLabel(forShortcutLabel:))
    }

    private func renameStream(_ stream: StreamSession) async {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        let succeeded = await viewModel.renameStream(sessionKey: stream.sessionKey, displayName: trimmed)
        isWorking = false
        guard succeeded else { return }
        resetInlineEditing()
    }

    private func removeStream(_ stream: StreamSession) async {
        guard !isRemovingStream(stream.sessionKey) else { return }
        removingSessionKeys.insert(stream.sessionKey)
        let succeeded = await viewModel.deleteStream(sessionKey: stream.sessionKey)
        removingSessionKeys.remove(stream.sessionKey)
        if activeEditor == .renaming(stream.sessionKey) {
            resetInlineEditing()
        }
        guard succeeded else { return }
    }

    private var pendingRemovalTitle: String {
        guard let stream = pendingRemovalStream else { return "Are you sure?" }
        return viewModel.isAdoptedStream(sessionKey: stream.sessionKey) ? "Untrack this session?" : "Delete this stream?"
    }

    private func removalActionTitle(for stream: StreamSession) -> String {
        viewModel.isAdoptedStream(sessionKey: stream.sessionKey) ? "Untrack" : "Delete"
    }

    private func removalActionImage(for stream: StreamSession) -> String {
        viewModel.isAdoptedStream(sessionKey: stream.sessionKey) ? "eye.slash" : "trash"
    }

    private var sectionSeparator: some View {
        Rectangle()
            .fill(actionBarSeparatorColor)
            .frame(height: actionBarSeparatorHeight)
            .padding(.horizontal, actionBarSeparatorInset)
            .allowsHitTesting(false)
    }

}

struct StreamPopupRowStatusDotIdentity: Hashable {
    let sessionKey: String
    let dotState: StreamDotState
    let isActive: Bool
    let colorScheme: ColorScheme
}

enum StreamSelectorShortcutMap {
    static let orderedSlots = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]

    static func selectableSessionKeys(
        filteredSessionKeys: [String],
        shortcutsAvailable: Bool,
        isWorking: Bool,
        removingSessionKeys: Set<String>,
        renamingSessionKey: String?
    ) -> [String] {
        guard shortcutsAvailable, !isWorking else { return [] }
        return filteredSessionKeys.filter { sessionKey in
            !removingSessionKeys.contains(sessionKey) && renamingSessionKey != sessionKey
        }
    }

    static func shortcutMap(selectableSessionKeys: [String]) -> [Int: KeyboardSurfaceId] {
        Dictionary(
            uniqueKeysWithValues: zip(orderedSlots, selectableSessionKeys.prefix(orderedSlots.count))
                .map { slot, sessionKey in
                    (slot, KeyboardSurfaceId.chatSelectorRow(sessionKey))
                }
        )
    }

    static func records(selectableSessionKeys: [String]) -> [KeyboardSurfaceRecord] {
        selectableSessionKeys.prefix(orderedSlots.count).map { sessionKey in
            KeyboardSurfaceRecord(
                surfaceId: .chatSelectorRow(sessionKey),
                surfaceKind: .chatSelector,
                parentSurfaceId: nil,
                lifecycleToken: "chat-selector-row:\(sessionKey)",
                visible: true,
                active: true,
                focusedHint: false,
                commandFamilies: [.chatSelectorAssigned],
                domainRef: sessionKey
            )
        }
    }

    static func store(selectableSessionKeys: [String]) -> KeyboardOwnershipStore {
        var store = KeyboardOwnershipStore()
        store.synchronize(
            records: records(selectableSessionKeys: selectableSessionKeys),
            notificationShortcutMap: [:],
            chatSelectorShortcutMap: shortcutMap(selectableSessionKeys: selectableSessionKeys)
        )
        return store
    }

    static func slot(forSessionKey sessionKey: String, selectableSessionKeys: [String]) -> Int? {
        guard let index = selectableSessionKeys.prefix(orderedSlots.count).firstIndex(of: sessionKey) else {
            return nil
        }
        return orderedSlots[index]
    }

    static func sessionKey(forSlot slot: Int, selectableSessionKeys: [String]) -> String? {
        guard let index = orderedSlots.firstIndex(of: slot),
              selectableSessionKeys.indices.contains(index) else {
            return nil
        }
        return selectableSessionKeys[index]
    }

    static func shortcutLabel(forSlot slot: Int) -> String {
        "⌘ \(slot)"
    }

    static func accessibilityLabel(forShortcutLabel label: String) -> String {
        label.replacingOccurrences(of: "⌘ ", with: "Command ")
    }
}

enum StreamSelectorShortcutActivation {
    static func intent(
        characters: String,
        modifiers: EventModifiers
    ) -> KeyboardCommandIntent? {
        guard modifiers == .command,
              let character = characters.first,
              characters.dropFirst().isEmpty,
              let slot = Int(String(character)) else {
            return nil
        }
        return .notificationAssignedOpen(slot)
    }
}

enum StreamSelectorShortcutKeyCommands {
    struct KeyCommandSpec: Equatable {
        let input: String
        let modifierFlags: UIKeyModifierFlags
        let intent: KeyboardCommandIntent
    }

    static func keyCommandSpecs(selectableSessionKeys: [String]) -> [KeyCommandSpec] {
        StreamSelectorShortcutMap.orderedSlots.compactMap { slot in
            guard StreamSelectorShortcutMap.sessionKey(
                forSlot: slot,
                selectableSessionKeys: selectableSessionKeys
            ) != nil else {
                return nil
            }
            return KeyCommandSpec(
                input: "\(slot)",
                modifierFlags: .command,
                intent: .notificationAssignedOpen(slot)
            )
        }
    }
}

private struct StreamSelectorShortcutKeyCommandBridge: UIViewRepresentable {
    let selectableSessionKeys: [String]
    let isSearchFieldFocused: Bool

    func makeUIView(context: Context) -> KeyCommandView {
        let view = KeyCommandView()
        view.selectableSessionKeys = selectableSessionKeys
        view.isSearchFieldFocused = isSearchFieldFocused
        return view
    }

    func updateUIView(_ uiView: KeyCommandView, context: Context) {
        uiView.selectableSessionKeys = selectableSessionKeys
        uiView.isSearchFieldFocused = isSearchFieldFocused
        uiView.refreshKeyCommandsIfNeeded()
        uiView.activateIfSearchFieldInactive()
    }

    final class KeyCommandView: UIView {
        var selectableSessionKeys: [String] = []
        var isSearchFieldFocused = false
        private var keyCommandSignature: [String] = []

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            StreamSelectorShortcutKeyCommands
                .keyCommandSpecs(selectableSessionKeys: selectableSessionKeys)
                .map { spec in
                    UIKeyCommand(
                        input: spec.input,
                        modifierFlags: spec.modifierFlags,
                        action: #selector(handleShortcut)
                    )
                }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            activateIfSearchFieldInactive()
        }

        func activateIfSearchFieldInactive() {
            guard !isSearchFieldFocused else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isSearchFieldFocused else { return }
                self.becomeFirstResponder()
            }
        }

        func refreshKeyCommandsIfNeeded() {
            let nextSignature = StreamSelectorShortcutKeyCommands
                .keyCommandSpecs(selectableSessionKeys: selectableSessionKeys)
                .map { "\($0.input)|\($0.modifierFlags.rawValue)|\($0.intent)" }
            guard nextSignature != keyCommandSignature else { return }
            keyCommandSignature = nextSignature
            reloadInputViews()
        }

        @objc private func handleShortcut(_ sender: UIKeyCommand) {
            guard let input = sender.input,
                  let intent = KeyboardCommandBridge.intent(input: input, modifierFlags: sender.modifierFlags),
                  case .notificationAssignedOpen(let slot) = intent,
                  StreamSelectorShortcutMap.sessionKey(
                    forSlot: slot,
                    selectableSessionKeys: selectableSessionKeys
                  ) != nil else {
                return
            }
            NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: intent)
        }
    }
}

private struct StreamPopupRowStatusDot: View {
    let isActive: Bool
    let dotState: StreamDotState
    let colorScheme: ColorScheme

    var body: some View {
        Circle()
            .fill(
                StreamDotColor.resolve(
                    isActive: isActive,
                    dotState: dotState,
                    colorScheme: colorScheme
                )
            )
            .frame(width: 8, height: 8)
            .fixedSize()
            .shadow(
                color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                radius: isActive ? StreamDotColor.activeOuterGlowRadius(colorScheme: colorScheme) : 0
            )
            .shadow(
                color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                radius: isActive ? StreamDotColor.activeInnerGlowRadius(colorScheme: colorScheme) : 0
            )
    }
}

struct TrackPickerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings

    @Bindable var viewModel: ChatViewModel
    let onDismissRequested: () -> Void

    @State private var selectedTrackCandidateSessionKey: String?
    @State private var trackSearchQuery = ""
    @State private var isWorking = false
    @FocusState private var isTrackSearchFieldFocused: Bool

    private let trackPickerRowCornerRadius: CGFloat = 12
    private let trackPickerContentHorizontalPadding: CGFloat = 20
    private let trackPickerSectionSpacing: CGFloat = 20
    private let trackPickerBottomBarHeight: CGFloat = 88
    private let trackPickerSearchFieldHeight: CGFloat = 40
    private let trackPickerActionButtonHeight: CGFloat = 44

    private var trackCandidates: [ChatViewModel.UntrackedSessionCandidate] {
        viewModel.untrackedSessionCandidates
    }

    private var selectedTrackCandidate: ChatViewModel.UntrackedSessionCandidate? {
        guard let selectedTrackCandidateSessionKey else { return nil }
        return filteredTrackCandidates.first { $0.sessionKey == selectedTrackCandidateSessionKey }
            ?? trackCandidates.first { $0.sessionKey == selectedTrackCandidateSessionKey }
    }

    private var filteredTrackCandidates: [ChatViewModel.UntrackedSessionCandidate] {
        let normalized = trackSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return trackCandidates }
        return trackCandidates.filter {
            StreamSelectorLayout.matchesTrackCandidate(
                displayName: $0.displayName,
                sessionKey: $0.sessionKey,
                query: normalized
            )
        }
    }

    private var trackPickerEmptyStateTitle: String {
        trackSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No sessions available"
            : "No matching sessions"
    }

    private var hasSelectedTrackCandidate: Bool {
        selectedTrackCandidate != nil
    }

    private var trackPickerActionBackgroundColor: Color {
        hasSelectedTrackCandidate && !isWorking
            ? Color.primary
            : Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08)
    }

    private var trackPickerActionForegroundColor: Color {
        hasSelectedTrackCandidate && !isWorking
            ? (colorScheme == .dark ? .black : .white)
            : .secondary
    }

    private var trackPickerMatchHighlightColor: Color {
        StreamDotColor.resolve(
            isActive: true,
            dotState: .inactive,
            colorScheme: colorScheme
        )
    }

    var body: some View {
        let _ = settings.fontScaleChangeSequence
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: trackPickerSectionSpacing) {
                    trackPickerIntroCard
                    trackPickerCandidateSection
                }
                .padding(.horizontal, trackPickerContentHorizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color.clear)
            .navigationTitle("Track Session")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                trackPickerBottomBar
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismissTrackPicker()
                    }
                }
            }
        }
        .onChange(of: trackCandidates.map(\.sessionKey)) { _, sessionKeys in
            guard let selectedTrackCandidateSessionKey else { return }
            if !sessionKeys.contains(selectedTrackCandidateSessionKey) {
                self.selectedTrackCandidateSessionKey = nil
            }
        }
        .task {
            viewModel.refreshTrackableSessionsOnDemand()
        }
        .onDisappear {
            clearTrackPickerFirstResponder()
        }
    }

    private func dismissTrackPicker() {
        clearTrackPickerFirstResponder()
        selectedTrackCandidateSessionKey = nil
        trackSearchQuery = ""
        onDismissRequested()
    }

    private func clearTrackPickerFirstResponder() {
        isTrackSearchFieldFocused = false
    }

    private func adoptSelectedTrackSession() {
        guard let selectedTrackCandidate else { return }
        guard !isWorking else { return }
        isWorking = true
        Task {
            let succeeded = await viewModel.trackSession(sessionKey: selectedTrackCandidate.sessionKey)
            await MainActor.run {
                isWorking = false
                guard succeeded else { return }
                dismissTrackPicker()
            }
        }
    }

    private var trackPickerIntroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "eye")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
                )

            VStack(alignment: .leading, spacing: 6) {
                Text("Adopt an agent session")
                    .font(.clawline(.uiLabel, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Select a session below, then tap Adopt. Nothing is tracked until you confirm.")
                    .font(.clawline(.secondaryLabel))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.5)
        }
    }

    private var trackPickerSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Filter sessions", text: $trackSearchQuery)
                .font(.clawline(.uiLabel))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isTrackSearchFieldFocused)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: trackPickerSearchFieldHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05))
        }
    }

    private var trackPickerCandidateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Sessions")
                    .font(.clawline(.timestamp, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if !trackCandidates.isEmpty {
                    Text("\(filteredTrackCandidates.count)")
                        .font(.clawline(.timestamp, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 6) {
                if filteredTrackCandidates.isEmpty {
                    trackPickerEmptyState
                } else {
                    ForEach(filteredTrackCandidates) { candidate in
                        trackPickerRow(for: candidate)
                    }
                }
            }
        }
    }

    private var trackPickerEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: trackSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "eye.slash" : "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(trackPickerEmptyStateTitle)
                .font(.clawline(.uiLabel, weight: .medium))
                .foregroundStyle(.secondary)
            Text(
                trackSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No adoptable agent sessions are available right now."
                    : "Try a different filter to find the session you want to adopt."
            )
                .font(.clawline(.secondaryLabel))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 32)
    }

    private var trackPickerBottomBar: some View {
        VStack(spacing: 0) {
            trackPickerBottomSeparator

            HStack(alignment: .center, spacing: 10) {
                trackPickerSearchField

                Button {
                    adoptSelectedTrackSession()
                } label: {
                    Text("Adopt")
                        .font(.clawline(.uiLabel, weight: .semibold))
                        .frame(minWidth: 80)
                        .frame(height: trackPickerActionButtonHeight)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(trackPickerActionForegroundColor)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(trackPickerActionBackgroundColor)
                }
                .disabled(!hasSelectedTrackCandidate || isWorking)
            }
            .padding(.horizontal, trackPickerContentHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(minHeight: trackPickerBottomBarHeight)
            .background(.regularMaterial)
        }
    }

    private var trackPickerBottomSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(maxWidth: .infinity)
            .frame(height: 0.5)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func trackPickerRow(for candidate: ChatViewModel.UntrackedSessionCandidate) -> some View {
        let isSelected = selectedTrackCandidateSessionKey == candidate.sessionKey

        Button {
            selectedTrackCandidateSessionKey = candidate.sessionKey
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected
                                ? Color.primary.opacity(0.8)
                                : Color.primary.opacity(colorScheme == .dark ? 0.25 : 0.18),
                            lineWidth: isSelected ? 0 : 1.5
                        )
                        .background(
                            Circle()
                                .fill(isSelected ? Color.primary : Color.clear)
                        )
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(colorScheme == .dark ? .black : .white)
                    }
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    highlightedTrackPickerDisplayName(for: candidate)
                        .font(.clawline(.uiLabel, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    highlightedTrackPickerSessionKey(for: candidate)
                        .font(.clawline(.timestamp, design: .monospaced))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: trackPickerRowCornerRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06)
                            : Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.02)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: trackPickerRowCornerRadius, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.14)
                            : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04),
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: trackPickerRowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func highlightedTrackPickerDisplayName(for candidate: ChatViewModel.UntrackedSessionCandidate) -> Text {
        highlightedText(
            candidate.displayName,
            query: trackSearchQuery,
            defaultColor: .primary,
            highlightColor: trackPickerMatchHighlightColor
        )
    }

    private func highlightedTrackPickerSessionKey(for candidate: ChatViewModel.UntrackedSessionCandidate) -> Text {
        let snippet = sessionKeySnippet(candidate.sessionKey, query: trackSearchQuery)
        return highlightedText(
            snippet.text,
            highlightedRange: snippet.highlightedRange,
            defaultColor: .secondary,
            highlightColor: trackPickerMatchHighlightColor
        )
    }

    private func highlightedText(
        _ text: String,
        query: String,
        defaultColor: Color,
        highlightColor: Color
    ) -> Text {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            let range = text.range(of: normalized, options: .caseInsensitive)
        else {
            return Text(text).foregroundColor(defaultColor)
        }
        return highlightedText(
            text,
            highlightedRange: range,
            defaultColor: defaultColor,
            highlightColor: highlightColor
        )
    }

    private func highlightedText(
        _ text: String,
        highlightedRange: Range<String.Index>?,
        defaultColor: Color,
        highlightColor: Color
    ) -> Text {
        var attributed = AttributedString(text)
        attributed.foregroundColor = defaultColor

        guard let highlightedRange,
            let attributedRange = Range(highlightedRange, in: attributed)
        else {
            return Text(attributed)
        }

        attributed[attributedRange].foregroundColor = highlightColor
        attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
        return Text(attributed)
    }

    private func sessionKeySnippet(_ sessionKey: String, query: String) -> (text: String, highlightedRange: Range<String.Index>?) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            let matchRange = sessionKey.range(of: normalized, options: .caseInsensitive)
        else {
            let shortened = shortenedTrackSessionKey(sessionKey)
            return (shortened, nil)
        }

        let lowerOffset = sessionKey.distance(from: sessionKey.startIndex, to: matchRange.lowerBound)
        let upperOffset = sessionKey.distance(from: sessionKey.startIndex, to: matchRange.upperBound)
        let snippetStartOffset = max(0, lowerOffset - 8)
        let snippetEndOffset = min(sessionKey.count, upperOffset + 8)
        let snippetStart = sessionKey.index(sessionKey.startIndex, offsetBy: snippetStartOffset)
        let snippetEnd = sessionKey.index(sessionKey.startIndex, offsetBy: snippetEndOffset)
        let needsLeadingEllipsis = snippetStartOffset > 0
        let needsTrailingEllipsis = snippetEndOffset < sessionKey.count
        let coreSnippet = String(sessionKey[snippetStart..<snippetEnd])
        let snippetText = "\(needsLeadingEllipsis ? "…" : "")\(coreSnippet)\(needsTrailingEllipsis ? "…" : "")"
        let highlightStartOffset = (needsLeadingEllipsis ? 1 : 0) + sessionKey.distance(from: snippetStart, to: matchRange.lowerBound)
        let highlightEndOffset = highlightStartOffset + sessionKey.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
        let snippetHighlightStart = snippetText.index(snippetText.startIndex, offsetBy: highlightStartOffset)
        let snippetHighlightEnd = snippetText.index(snippetText.startIndex, offsetBy: highlightEndOffset)
        return (snippetText, snippetHighlightStart..<snippetHighlightEnd)
    }

    private func shortenedTrackSessionKey(_ sessionKey: String) -> String {
        guard sessionKey.count > 34 else { return sessionKey }
        let start = sessionKey.prefix(18)
        let end = sessionKey.suffix(12)
        return "\(start)…\(end)"
    }
}

private extension View {
    @ViewBuilder
    func streamRowContextMenu(
        isPresented: Bool,
        renameEnabled: Bool,
        removalEnabled: Bool,
        removalTitle: String,
        removalImage: String,
        onRename: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        if isPresented {
            contextMenu {
                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(!renameEnabled)

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label(removalTitle, systemImage: removalImage)
                }
                .disabled(!removalEnabled)
            }
        } else {
            self
        }
    }
}

enum StreamSelectorLayout {
    struct SelectionHighlightStyle: Equatable {
        let fillOpacity: CGFloat
        let strokeOpacity: CGFloat
        let strokeLineWidth: CGFloat
    }

    struct PopupVerticalLayout: Equatable {
        let containerHeight: CGFloat
        let listViewportHeight: CGFloat
        let actionBarHeight: CGFloat
    }

    struct PopupHeightFrame: Equatable {
        let fixedHeight: CGFloat?
        let minHeight: CGFloat?
        let idealHeight: CGFloat?
        let maxHeight: CGFloat?
    }

    static func dotStatesBySession(
        streams: [StreamSession],
        lookup: StreamDotStateLookup
    ) -> [String: StreamDotState] {
        Dictionary(uniqueKeysWithValues: streams.map { stream in
            (stream.sessionKey, lookup(stream.sessionKey))
        })
    }

    static func selectionHighlightStyle(
        isSelected: Bool,
        isDark: Bool,
        isSpatial: Bool
    ) -> SelectionHighlightStyle {
        guard isSelected else {
            return SelectionHighlightStyle(fillOpacity: 0, strokeOpacity: 0, strokeLineWidth: 0)
        }
        if isSpatial {
            return SelectionHighlightStyle(fillOpacity: 0.24, strokeOpacity: 0.40, strokeLineWidth: 1)
        }
        return SelectionHighlightStyle(fillOpacity: isDark ? 0.16 : 0.08, strokeOpacity: 0, strokeLineWidth: 0)
    }

    static func popupWidth(
        longestItemWidth: CGFloat,
        minimumPopoverWidth: CGFloat,
        baselineIdealPopoverWidth: CGFloat,
        maximumPopoverWidth: CGFloat,
        rowHorizontalInset: CGFloat,
        rowContentSpacing: CGFloat,
        leadingDotDiameter: CGFloat,
        trailingAccessoryReserve: CGFloat
    ) -> CGFloat {
        let chromeWidth = (rowHorizontalInset * 2)
            + leadingDotDiameter
            + rowContentSpacing
            + trailingAccessoryReserve
        let contentDrivenWidth = longestItemWidth + chromeWidth
        let idealWidth = max(baselineIdealPopoverWidth, contentDrivenWidth)
        return min(maximumPopoverWidth, max(minimumPopoverWidth, idealWidth))
    }

    static func popupContainerHeight(
        idealContainerHeight: CGFloat,
        allocatedContainerHeight: CGFloat,
        isSpatial: Bool
    ) -> CGFloat {
        isSpatial ? allocatedContainerHeight : idealContainerHeight
    }

    static func popupHeightFrame(
        idealContainerHeight: CGFloat,
        minimumPopoverHeight: CGFloat,
        isSpatial: Bool
    ) -> PopupHeightFrame {
        guard !isSpatial else {
            return PopupHeightFrame(
                fixedHeight: nil,
                minHeight: nil,
                idealHeight: nil,
                maxHeight: nil
            )
        }
        return PopupHeightFrame(
            fixedHeight: idealContainerHeight,
            minHeight: min(minimumPopoverHeight, idealContainerHeight),
            idealHeight: idealContainerHeight,
            maxHeight: idealContainerHeight
        )
    }

    static func filter(streams: [StreamSession], query: String) -> [StreamSession] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return streams }
        return streams.filter { stream in
            matchesStreamName(stream.displayName, query: normalized)
        }
    }

    static func matchesStreamName(_ displayName: String, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return displayName.localizedCaseInsensitiveContains(normalized)
    }

    static func matchesTrackCandidate(displayName: String, sessionKey: String, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return displayName.localizedCaseInsensitiveContains(normalized)
            || sessionKey.localizedCaseInsensitiveContains(normalized)
    }

    static func resolvedSelection(
        preferredSessionKey: String?,
        activeSessionKey: String,
        sessionKeys: [String]
    ) -> String? {
        guard !sessionKeys.isEmpty else { return nil }
        if let preferredSessionKey, sessionKeys.contains(preferredSessionKey) {
            return preferredSessionKey
        }
        if sessionKeys.contains(activeSessionKey) {
            return activeSessionKey
        }
        return sessionKeys.first
    }

    static func selectionAfterMoving(
        currentSessionKey: String?,
        sessionKeys: [String],
        step: Int
    ) -> String? {
        guard !sessionKeys.isEmpty else { return nil }
        guard step != 0 else {
            return resolvedSelection(
                preferredSessionKey: currentSessionKey,
                activeSessionKey: "",
                sessionKeys: sessionKeys
            )
        }
        let currentIndex = currentSessionKey.flatMap { sessionKeys.firstIndex(of: $0) }
        let startingIndex = currentIndex ?? (step > 0 ? -1 : sessionKeys.count)
        let targetIndex = min(sessionKeys.count - 1, max(0, startingIndex + step))
        return sessionKeys[targetIndex]
    }

    static func activationTarget(
        selectedSessionKey: String?,
        didActivateSelection: Bool
    ) -> String? {
        guard !didActivateSelection else { return nil }
        return selectedSessionKey
    }

    static func listContentHeight(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        outerVerticalPadding: CGFloat
    ) -> CGFloat {
        let rows = max(1, itemCount + (showsCreateInlineRow ? 1 : 0))
        let interRowSpacing = CGFloat(max(0, rows - 1)) * rowSpacing
        return CGFloat(rows) * rowHeight + interRowSpacing + (outerVerticalPadding * 2)
    }

    static func containerHeight(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        functionBarHeight: CGFloat,
        outerVerticalPadding: CGFloat,
        maxAvailableHeight: CGFloat,
        minimumPopoverHeight: CGFloat
    ) -> CGFloat {
        let desired = desiredHeight(
            itemCount: itemCount,
            showsCreateInlineRow: showsCreateInlineRow,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            functionBarHeight: functionBarHeight,
            outerVerticalPadding: outerVerticalPadding
        )
        // Hard ceiling: never ask the popover system for more than the caller's budget.
        // When the budget is smaller than our preferred minimum (e.g., a very short
        // spatial window), clamp to the budget so the popup fits inside the available
        // space instead of requesting a minimum the popover system cannot honor —
        // which would silently crop the popup body on visionOS.
        let cap = max(0, maxAvailableHeight)
        let preferredFloor = min(minimumPopoverHeight, cap)
        let desiredWithinBudget = min(desired, cap)
        return max(preferredFloor, desiredWithinBudget)
    }

    static func popupVerticalLayout(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        actionBarHeight: CGFloat,
        outerVerticalPadding: CGFloat,
        maxAvailableHeight: CGFloat,
        minimumPopoverHeight: CGFloat
    ) -> PopupVerticalLayout {
        let containerHeight = containerHeight(
            itemCount: itemCount,
            showsCreateInlineRow: showsCreateInlineRow,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            functionBarHeight: actionBarHeight,
            outerVerticalPadding: outerVerticalPadding,
            maxAvailableHeight: maxAvailableHeight,
            minimumPopoverHeight: minimumPopoverHeight
        )
        return PopupVerticalLayout(
            containerHeight: containerHeight,
            listViewportHeight: listViewportHeight(
                containerHeight: containerHeight,
                actionBarReservedHeight: actionBarHeight
            ),
            actionBarHeight: actionBarHeight
        )
    }

    /// Adaptive height for the stream list viewport given an actual allocated container height.
    ///
    /// This is used by the popup to shrink the scrollable list viewport when the popover
    /// system allocates less vertical space than the popup's ideal height, so list rows and
    /// the bottom toolbar stay inside the visible popup bounds.
    static func listViewportHeight(
        containerHeight: CGFloat,
        actionBarReservedHeight: CGFloat
    ) -> CGFloat {
        max(0, containerHeight - actionBarReservedHeight)
    }

    static func isOverflowing(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        functionBarHeight: CGFloat,
        outerVerticalPadding: CGFloat,
        maxAvailableHeight: CGFloat,
        minimumPopoverHeight: CGFloat
    ) -> Bool {
        let desired = desiredHeight(
            itemCount: itemCount,
            showsCreateInlineRow: showsCreateInlineRow,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            functionBarHeight: functionBarHeight,
            outerVerticalPadding: outerVerticalPadding
        )
        let cap = max(minimumPopoverHeight, maxAvailableHeight)
        return desired > cap + 0.5
    }

    private static func desiredHeight(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        functionBarHeight: CGFloat,
        outerVerticalPadding: CGFloat
    ) -> CGFloat {
        let listHeight = listContentHeight(
            itemCount: itemCount,
            showsCreateInlineRow: showsCreateInlineRow,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            outerVerticalPadding: outerVerticalPadding
        )
        return listHeight + functionBarHeight
    }
}
