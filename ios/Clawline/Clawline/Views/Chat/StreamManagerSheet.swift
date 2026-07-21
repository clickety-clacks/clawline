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
    @Environment(\.displayScale) private var displayScale
    @Environment(\.settingsManager) private var settings

    @Bindable var viewModel: ChatViewModel
    let streams: [StreamSession]
    let dotStateLookup: StreamDotStateLookup
    let searchFocusRequestID: Int?
    let maxAvailableHeight: CGFloat
    let maxAvailableWidth: CGFloat
    /// Active popup presentation identity from the focus coordinator.
    /// Carries R1136-ARCH-05 identity into child focus reports so the parent
    /// can decide policy without children holding long-lived focus counters.
    let presentationID: UInt
    /// True only while the popup focus coordinator permits the shortcut
    /// key-command bridge to take first responder. Drives R1136-ARCH-06 / E6:
    /// the hidden bridge must stand down during dismissal and composer
    /// restoration so it cannot opportunistically grab first responder.
    let isShortcutOwnershipActive: Bool
    let onSelectStream: (String) -> Void
    let onRequestTrackPicker: () -> Void
    let onConsumeSearchFocusRequest: () -> Void
    let onShortcutOwnershipChange: ([String]) -> Void
    /// R1136-ARCH-06: child focus reporting. StreamManagerSheet reports actual
    /// search-focus applied/resigned events back to the focus coordinator with
    /// the active presentation ID. Children report; the parent decides policy.
    let onSearchFocusApplied: (UInt) -> Void
    let onSearchFocusResigned: (UInt) -> Void
    /// Reports that SwiftUI has torn down the popup presentation for this ID.
    let onPresentationEnded: (UInt) -> Void

    @State private var draftName = ""
    @State private var searchQuery = ""
    @State private var activeEditor: EditorMode?
    @State private var isWorking = false
    @State private var resolvedHardwareKeyboardShortcutsAvailable = false
    @State private var removingSessionKeys: Set<String> = []
    @State private var pendingCreateRows: [PendingCreateRow] = []
    @State private var pendingRemovalStream: StreamSession?
    @State private var isPresentingCreationSheet = false
    @State private var selectedStreamSessionKey: String?
    @State private var didActivateSelection = false
    @State private var isSearchFieldFocusEnabled = false
    @State private var localSearchFocusRequestID = 0
    @State private var isSearchFieldFocused = false
    @State private var popoverWidthCache: PopoverWidthCache?
    @State private var rowHighlightCache: [RowHighlightCacheKey: StreamSelectorLayout.SelectionHighlightStyle] = [:]
    @FocusState private var focusedEditor: EditorMode?

    private struct PopoverWidthCacheKey: Hashable {
        let streamNames: [String]
        let pendingNames: [String]
        let maximumWidthPixels: Int
        let showsShortcutLabels: Bool
        let fontScaleChangeSequence: Int
    }

    private struct PopoverWidthCache: Equatable {
        let key: PopoverWidthCacheKey
        let width: CGFloat
    }

    private struct RowHighlightCacheKey: Hashable {
        let sessionKey: String
        let isSelected: Bool
        let colorScheme: ColorScheme
        let isSpatial: Bool
    }

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

    private func idealPopoverWidth(
        filteredStreams: [StreamSession],
        filteredPendingCreateRows: [PendingCreateRow]
    ) -> CGFloat {
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
            trailingAccessoryReserve: StreamSelectorLayout.popupTrailingAccessoryReserve(
                baseReserve: rowTrailingAccessoryReserve,
                shortcutLabelWidth: shortcutLabelReservedWidth,
                showsShortcutLabels: selectorShortcutsAvailable
            )
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

    private var selectorShortcutBridgeShouldOwnFirstResponder: Bool {
        isShortcutOwnershipActive
            && selectorShortcutsAvailable
            && searchFocusRequestID == nil
            && !isSearchFieldFocused
    }

    private var shouldRenderSearchTextField: Bool {
        isSearchFieldFocusEnabled
            || StreamPopupSearchPresentationFocusPolicy
                .shouldRenderSearchTextFieldOnInitialPresentation(searchFocusRequestID: searchFocusRequestID)
    }

    private var activeSearchFocusRequestID: Int? {
        searchFocusRequestID ?? (localSearchFocusRequestID > 0 ? localSearchFocusRequestID : nil)
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
        // Hoisted once per body evaluation; the filter chain and shortcut map
        // must not be re-derived per row (O(N^2)) or per width measurement.
        let filteredStreams = self.filteredStreams
        let filteredPendingCreateRows = self.filteredPendingCreateRows
        let selectableShortcutKeys = selectableShortcutSessionKeys(
            shortcutsAvailable: selectorShortcutsAvailable,
            filteredSessionKeys: filteredStreams.map(\.sessionKey)
        )
        let listItemCount = filteredStreams.count + filteredPendingCreateRows.count
        let popoverWidthCacheKey = PopoverWidthCacheKey(
            streamNames: filteredStreams.map(\.displayName),
            pendingNames: filteredPendingCreateRows.map(\.displayName),
            maximumWidthPixels: Int((maximumPopoverWidth * displayScale).rounded()),
            showsShortcutLabels: selectorShortcutsAvailable,
            fontScaleChangeSequence: settings.fontScaleChangeSequence
        )
        let idealWidth = popoverWidthCache?.key == popoverWidthCacheKey
            ? popoverWidthCache?.width ?? baselineIdealPopoverWidth
            : idealPopoverWidth(
                filteredStreams: filteredStreams,
                filteredPendingCreateRows: filteredPendingCreateRows
            )
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
            minimumPopoverHeight: minimumPopoverHeight
        )
        let rowDotStates = StreamSelectorLayout.dotStatesBySession(
            streams: filteredStreams,
            lookup: dotStateLookup
        )
        GeometryReader { geometry in
            let containerHeight = StreamSelectorLayout.popupContainerHeight(
                allocatedContainerHeight: geometry.size.height
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
                            dotState: rowDotStates[stream.sessionKey] ?? .inactive,
                            selectableShortcutKeys: selectableShortcutKeys
                        )
                    }

                    ForEach(filteredPendingCreateRows) { pendingRow in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.primary.opacity(0.18))
                                .frame(width: rowDotDiameter, height: rowDotDiameter)
                                .frame(
                                    width: StreamSelectorLayout.popupStatusDotSlotWidth(dotDiameter: rowDotDiameter),
                                    height: listRowHeight,
                                    alignment: .center
                                )
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
            idealWidth: idealWidth,
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
        .modifier(
            StreamManagerSheetLifecycleModifier(
                searchFocusRequestID: searchFocusRequestID,
                isSearchFieldFocused: isSearchFieldFocused,
                presentationID: presentationID,
                onAppear: { [self] in handleAppearance() },
                onDisappear: { [self] in handleDisappearance() },
                onSearchFocusRequestIDChange: { [self] requestID in handleSearchFocusRequest(requestID) },
                onSearchFocusChange: { [self] focused in reportSearchFocus(focused) }
            )
        )
        .onAppear {
            refreshStreamManagerCaches(
                key: popoverWidthCacheKey,
                filteredStreams: filteredStreams,
                filteredPendingCreateRows: filteredPendingCreateRows
            )
        }
        .onChange(of: popoverWidthCacheKey) { _, key in
            refreshStreamManagerCaches(
                key: key,
                filteredStreams: filteredStreams,
                filteredPendingCreateRows: filteredPendingCreateRows
            )
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
#if (os(iOS) || os(visionOS)) && !targetEnvironment(macCatalyst) && canImport(GameController)
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            refreshShortcutAvailabilityAndPublish()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            refreshShortcutAvailabilityAndPublish()
        }
#endif
        .alert(
            pendingRemovalTitle,
            isPresented: pendingRemovalPresented,
            presenting: pendingRemovalStream
        ) { stream in
            Button("Cancel", role: .cancel) {}
            Button(removalActionTitle(for: stream), role: .destructive) {
                pendingRemovalStream = nil
                Task { await removeStream(stream) }
            }
        }
        .sheet(isPresented: $isPresentingCreationSheet) {
            StreamCreationSheet(viewModel: viewModel, defaultName: nextStreamDefaultName)
        }
        // The creation sheet is a Tightbeam-only affordance. If the shared gate
        // closes while it is open (disconnect, or a feature set without
        // "tightbeam"), it must stop being actionable rather than continue to
        // offer placement creation against an ungated server.
        .onChange(of: viewModel.isTightbeamServer) { _, isTightbeam in
            if !isTightbeam { isPresentingCreationSheet = false }
        }
    }


    private var pendingRemovalPresented: Binding<Bool> {
        Binding(
            get: { pendingRemovalStream != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemovalStream = nil
                }
            }
        )
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
                addStream()
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
            isSearchFieldFocused: isSearchFieldFocused,
            shouldOwnFirstResponder: selectorShortcutBridgeShouldOwnFirstResponder
        )
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var searchField: some View {
        if shouldRenderSearchTextField {
            StreamSelectorSearchField(
                text: $searchQuery,
                focusRequestID: activeSearchFocusRequestID,
                isFocused: $isSearchFieldFocused,
                onMoveSelection: { step in
                    moveSelection(step: step)
                },
                onSubmit: {
                    selectHighlightedStream()
                },
                onDigit: { input in
                    handleSelectorShortcutDigit(input)
                }
            )
        } else {
            Button {
                isSearchFieldFocusEnabled = true
                localSearchFocusRequestID &+= 1
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
    private func streamRow(
        for stream: StreamSession,
        dotState: StreamDotState,
        selectableShortcutKeys: [String]
    ) -> some View {
        rowContent(for: stream, dotState: dotState, selectableShortcutKeys: selectableShortcutKeys)
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
    private func rowContent(
        for stream: StreamSession,
        dotState: StreamDotState,
        selectableShortcutKeys: [String]
    ) -> some View {
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
                    .frame(
                        width: StreamSelectorLayout.popupStatusDotSlotWidth(dotDiameter: rowDotDiameter),
                        height: listRowHeight,
                        alignment: .center
                    )
                    Text(stream.displayName)
                        .font(.clawline(.subsectionHeader).weight(isActive ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isRemovingStream(stream.sessionKey) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                    shortcutLabel(for: stream, selectableShortcutKeys: selectableShortcutKeys)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isRemovingStream(stream.sessionKey))
            .accessibilityHint(
                accessibilityShortcutLabel(for: stream, selectableShortcutKeys: selectableShortcutKeys)
                    .map { "Shortcut \($0)" } ?? ""
            )
        }
    }

    @ViewBuilder
    private func shortcutLabel(for stream: StreamSession, selectableShortcutKeys: [String]) -> some View {
        if let label = shortcutLabelText(for: stream, selectableShortcutKeys: selectableShortcutKeys) {
            Text(label)
                .font(.clawline(.secondaryLabel))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: shortcutLabelReservedWidth, alignment: .trailing)
                .accessibilityLabel(StreamSelectorShortcutMap.accessibilityLabel(forShortcutLabel: label))
        }
    }


    private func refreshStreamManagerCaches(
        key: PopoverWidthCacheKey,
        filteredStreams: [StreamSession],
        filteredPendingCreateRows: [PendingCreateRow]
    ) {
        if popoverWidthCache?.key != key {
            popoverWidthCache = PopoverWidthCache(
                key: key,
                width: idealPopoverWidth(
                    filteredStreams: filteredStreams,
                    filteredPendingCreateRows: filteredPendingCreateRows
                )
            )
        }
        rowHighlightCache = Dictionary(uniqueKeysWithValues: filteredStreams.map { stream in
            let key = RowHighlightCacheKey(
                sessionKey: stream.sessionKey,
                isSelected: selectedStreamSessionKey == stream.sessionKey,
                colorScheme: colorScheme,
                isSpatial: Self.isSpatialPlatform
            )
            return (
                key,
                StreamSelectorLayout.selectionHighlightStyle(
                    isSelected: key.isSelected,
                    isDark: key.colorScheme == .dark,
                    isSpatial: key.isSpatial
                )
            )
        })
    }

    private func rowBackground(for stream: StreamSession) -> some View {
        let key = RowHighlightCacheKey(
            sessionKey: stream.sessionKey,
            isSelected: selectedStreamSessionKey == stream.sessionKey,
            colorScheme: colorScheme,
            isSpatial: Self.isSpatialPlatform
        )
        let highlight = rowHighlightCache[key]
            ?? StreamSelectorLayout.selectionHighlightStyle(
                isSelected: key.isSelected,
                isDark: key.colorScheme == .dark,
                isSpatial: key.isSpatial
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

    private var nextStreamDefaultName: String {
        let existingCount = streams.count + pendingCreateRows.count
        return "Stream \(existingCount + 1)"
    }

    /// Routes the "+" affordance: tightbeam opens the placement creation sheet;
    /// openclaw keeps the legacy name-only direct create unchanged.
    private func addStream() {
        if StreamCreationLaunchPolicy.usesCreationSheet(isTightbeamServer: viewModel.isTightbeamServer) {
            viewModel.loadOrgOptionsIfNeeded()
            isPresentingCreationSheet = true
        } else {
            addStreamDirectly()
        }
    }

    private func addStreamDirectly() {
        let name = nextStreamDefaultName
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
        localSearchFocusRequestID &+= 1
        syncSelectionWithFilteredStreams()
    }

    private func handleSearchFocusRequest(_ requestID: Int?) {
        guard requestID != nil else { return }
        isSearchFieldFocusEnabled = true
        localSearchFocusRequestID = requestID ?? localSearchFocusRequestID
        syncSelectionWithFilteredStreams()
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

    private func handleAppearance() {
        refreshShortcutAvailabilityAndPublish()
        syncSelectionWithFilteredStreams()
        handleInitialSearchFocus(searchFocusRequestID)
    }

    private func handleDisappearance() {
        onShortcutOwnershipChange([])
        // R1136-ARCH-06: report focus resign on teardown so the parent's
        // transaction reflects actual search-field state, not a stale
        // acknowledgement that outlives the popup.
        if isSearchFieldFocused {
            onSearchFocusResigned(presentationID)
        }
        onPresentationEnded(presentationID)
        resetInlineEditing()
        searchQuery = ""
        isSearchFieldFocused = false
        isSearchFieldFocusEnabled = false
        selectedStreamSessionKey = nil
        didActivateSelection = false
    }

    /// R1136-ARCH-06: child focus reporting. StreamManagerSheet reports actual
    /// search-focus applied/resigned events to the parent focus coordinator
    /// with the active presentation ID. Children report; the parent decides
    /// policy (e.g., whether the shortcut bridge may take first responder).
    private func reportSearchFocus(_ focused: Bool) {
        if focused {
            onSearchFocusApplied(presentationID)
        } else {
            onSearchFocusResigned(presentationID)
        }
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

    private func handleSelectorShortcutDigit(_ characters: String) -> Bool {
        guard let intent = StreamSelectorShortcutActivation.intent(
            characters: characters,
            modifiers: []
        ),
              case .notificationAssignedOpen(let slot) = intent,
              StreamSelectorShortcutMap.sessionKey(
                forSlot: slot,
                selectableSessionKeys: selectableShortcutSessionKeys
              ) != nil else {
            return false
        }
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: intent)
        return true
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
        selectableShortcutSessionKeys(
            shortcutsAvailable: shortcutsAvailable,
            filteredSessionKeys: filteredStreamSessionKeys
        )
    }

    private func selectableShortcutSessionKeys(
        shortcutsAvailable: Bool,
        filteredSessionKeys: [String]
    ) -> [String] {
        let renamingSessionKey: String? = {
            guard case .renaming(let sessionKey) = activeEditor else { return nil }
            return sessionKey
        }()
        return StreamSelectorShortcutMap.selectableSessionKeys(
            filteredSessionKeys: filteredSessionKeys,
            shortcutsAvailable: shortcutsAvailable,
            isWorking: isWorking,
            removingSessionKeys: removingSessionKeys,
            renamingSessionKey: renamingSessionKey
        )
    }

    private func shortcutLabelText(for stream: StreamSession, selectableShortcutKeys: [String]) -> String? {
        guard selectorShortcutsAvailable,
              let slot = StreamSelectorShortcutMap.slot(
                forSessionKey: stream.sessionKey,
                selectableSessionKeys: selectableShortcutKeys
              ) else { return nil }
        return StreamSelectorShortcutMap.shortcutLabel(forSlot: slot)
    }

    private func accessibilityShortcutLabel(for stream: StreamSession, selectableShortcutKeys: [String]) -> String? {
        shortcutLabelText(for: stream, selectableShortcutKeys: selectableShortcutKeys)
            .map(StreamSelectorShortcutMap.accessibilityLabel(forShortcutLabel:))
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

/// Extracts the focus/lifecycle modifiers from `StreamManagerSheet.body` so the
/// body's view tree stays under the SwiftUI type-checker's complexity budget.
/// Carries the popup presentation identity (`R1136-ARCH-05`) into the search
/// focus reports so the parent focus coordinator can decide policy.
private struct StreamManagerSheetLifecycleModifier: ViewModifier {
    let searchFocusRequestID: Int?
    let isSearchFieldFocused: Bool
    let presentationID: UInt
    let onAppear: () -> Void
    let onDisappear: () -> Void
    let onSearchFocusRequestIDChange: (Int?) -> Void
    let onSearchFocusChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
            .onChange(of: searchFocusRequestID) { _, requestID in
                onSearchFocusRequestIDChange(requestID)
            }
            .onChange(of: isSearchFieldFocused) { _, focused in
                onSearchFocusChange(focused)
            }
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

private struct StreamSelectorSearchField: UIViewRepresentable {
    @Binding var text: String
    let focusRequestID: Int?
    @Binding var isFocused: Bool
    let onMoveSelection: (Int) -> Void
    let onSubmit: () -> Void
    let onDigit: (String) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> SearchTextField {
        let textField = SearchTextField()
        textField.delegate = context.coordinator
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.font = .clawline(.uiLabel)
        textField.placeholder = "Filter..."
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.returnKeyType = .go
        textField.clearButtonMode = .never
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        context.coordinator.configure(textField)
        return textField
    }

    func updateUIView(_ uiView: SearchTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.configure(uiView)
        uiView.onMoveSelection = onMoveSelection
        uiView.onSubmit = onSubmit
        uiView.onDigit = onDigit
        if uiView.text != text {
            uiView.text = text
        }
        uiView.applyFocusRequestIfNeeded(focusRequestID)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func configure(_ textField: SearchTextField) {
            textField.onFocusChange = { [weak self] focused in
                self?.isFocused.wrappedValue = focused
            }
        }

        @objc func textDidChange(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isFocused.wrappedValue = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isFocused.wrappedValue = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            (textField as? SearchTextField)?.onSubmit?()
            return false
        }
    }

    final class SearchTextField: UITextField {
        var onMoveSelection: ((Int) -> Void)?
        var onSubmit: (() -> Void)?
        var onDigit: ((String) -> Bool)?
        var onFocusChange: ((Bool) -> Void)?
        private var appliedFocusRequestID: Int?

        override var keyCommands: [UIKeyCommand]? {
            let commands: [UIKeyCommand] = [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(moveUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveDown)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(submit))
            ]
            return commands
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyPendingFocusRequestIfPossible()
        }

        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
            if becameFirstResponder {
                onFocusChange?(true)
            }
            return becameFirstResponder
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                onFocusChange?(false)
            }
            return resigned
        }

        func applyFocusRequestIfNeeded(_ requestID: Int?) {
            guard let requestID else { return }
            let shouldApply = appliedFocusRequestID != requestID || (window != nil && !isFirstResponder)
            appliedFocusRequestID = requestID
            guard shouldApply, window != nil else { return }
            _ = becomeFirstResponder()
        }

        private func applyPendingFocusRequestIfPossible() {
            guard appliedFocusRequestID != nil, window != nil, !isFirstResponder else { return }
            _ = becomeFirstResponder()
        }

        @objc private func moveUp() {
            onMoveSelection?(-1)
        }

        @objc private func moveDown() {
            onMoveSelection?(1)
        }

        @objc private func submit() {
            onSubmit?()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let press = presses.first,
                  presses.count == 1,
                  let input = press.key?.charactersIgnoringModifiers,
                  input.count == 1,
                  input.rangeOfCharacter(from: .decimalDigits) != nil,
                  onDigit?(input) == true else {
                super.pressesBegan(presses, with: event)
                return
            }
        }
    }
}

private struct StreamSelectorShortcutKeyCommandBridge: UIViewRepresentable {
    let selectableSessionKeys: [String]
    let isSearchFieldFocused: Bool
    /// R1136-ARCH-06 / E6: parent-owned permit. The hidden key-command bridge
    /// may only take first responder when the popup focus coordinator says
    /// selector shortcuts own input AND the search field is not currently
    /// focused. During dismissal and composer restoration this is false, so
    /// the bridge cannot opportunistically grab first responder.
    let shouldOwnFirstResponder: Bool

    func makeUIView(context: Context) -> KeyCommandView {
        let view = KeyCommandView()
        view.selectableSessionKeys = selectableSessionKeys
        view.isSearchFieldFocused = isSearchFieldFocused
        view.shouldOwnFirstResponder = shouldOwnFirstResponder
        return view
    }

    func updateUIView(_ uiView: KeyCommandView, context: Context) {
        uiView.selectableSessionKeys = selectableSessionKeys
        uiView.isSearchFieldFocused = isSearchFieldFocused
        uiView.shouldOwnFirstResponder = shouldOwnFirstResponder
        uiView.refreshKeyCommandsIfNeeded()
        uiView.reconcileFirstResponderOwnership()
    }

    final class KeyCommandView: UIView {
        var selectableSessionKeys: [String] = []
        var isSearchFieldFocused = false
        var shouldOwnFirstResponder = false
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
            reconcileFirstResponderOwnership()
        }

        func reconcileFirstResponderOwnership() {
            guard shouldOwnFirstResponder, !isSearchFieldFocused else {
                if isFirstResponder {
                    resignFirstResponder()
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.shouldOwnFirstResponder,
                      !self.isSearchFieldFocused else { return }
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

struct StreamPopupRowStatusDot: View {
    let isActive: Bool
    let dotState: StreamDotState
    let colorScheme: ColorScheme

    var body: some View {
        Image(systemName: "circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(
                StreamDotColor.resolve(
                    isActive: isActive,
                    dotState: dotState,
                    colorScheme: colorScheme
                )
            )
            .frame(width: 8, height: 8)
            .fixedSize()
            .accessibilityHidden(true)
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
    @State private var trackPickerHighlightCache: [TrackPickerHighlightCacheKey: TrackPickerHighlightCacheValue] = [:]
    @FocusState private var isTrackSearchFieldFocused: Bool

    private struct TrackPickerHighlightCacheKey: Hashable {
        let sessionKey: String
        let displayName: String
        let query: String
        let colorScheme: ColorScheme
    }

    private struct TrackPickerHighlightCacheValue {
        let displayName: AttributedString
        let sessionKeySnippet: AttributedString
    }

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
        let trackHighlightCacheKey = filteredTrackCandidates.map {
            TrackPickerHighlightCacheKey(
                sessionKey: $0.sessionKey,
                displayName: $0.displayName,
                query: trackSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                colorScheme: colorScheme
            )
        }
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
        .onAppear { refreshTrackPickerHighlightCache() }
        .onChange(of: trackHighlightCacheKey) { _, _ in refreshTrackPickerHighlightCache() }
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
        let highlightedText = trackPickerHighlightedText(for: candidate)

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
                    Text(highlightedText.displayName)
                        .font(.clawline(.uiLabel, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Text(highlightedText.sessionKeySnippet)
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

    private func refreshTrackPickerHighlightCache() {
        trackPickerHighlightCache = Dictionary(uniqueKeysWithValues: filteredTrackCandidates.map { candidate in
            let key = trackPickerHighlightCacheKey(for: candidate)
            return (key, makeTrackPickerHighlightValue(for: candidate))
        })
    }

    private func trackPickerHighlightedText(for candidate: ChatViewModel.UntrackedSessionCandidate) -> TrackPickerHighlightCacheValue {
        let key = trackPickerHighlightCacheKey(for: candidate)
        return trackPickerHighlightCache[key] ?? makeTrackPickerHighlightValue(for: candidate)
    }

    private func trackPickerHighlightCacheKey(for candidate: ChatViewModel.UntrackedSessionCandidate) -> TrackPickerHighlightCacheKey {
        TrackPickerHighlightCacheKey(
            sessionKey: candidate.sessionKey,
            displayName: candidate.displayName,
            query: trackSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            colorScheme: colorScheme
        )
    }

    private func makeTrackPickerHighlightValue(for candidate: ChatViewModel.UntrackedSessionCandidate) -> TrackPickerHighlightCacheValue {
        let snippet = sessionKeySnippet(candidate.sessionKey, query: trackSearchQuery)
        return TrackPickerHighlightCacheValue(
            displayName: highlightedAttributedString(
                candidate.displayName,
                query: trackSearchQuery,
                defaultColor: .primary,
                highlightColor: trackPickerMatchHighlightColor
            ),
            sessionKeySnippet: highlightedAttributedString(
                snippet.text,
                highlightedRange: snippet.highlightedRange,
                defaultColor: .secondary,
                highlightColor: trackPickerMatchHighlightColor
            )
        )
    }

    private func highlightedAttributedString(
        _ text: String,
        query: String,
        defaultColor: Color,
        highlightColor: Color
    ) -> AttributedString {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            let range = text.range(of: normalized, options: .caseInsensitive)
        else {
            var attributed = AttributedString(text)
            attributed.foregroundColor = defaultColor
            return attributed
        }
        return highlightedAttributedString(
            text,
            highlightedRange: range,
            defaultColor: defaultColor,
            highlightColor: highlightColor
        )
    }

    private func highlightedAttributedString(
        _ text: String,
        highlightedRange: Range<String.Index>?,
        defaultColor: Color,
        highlightColor: Color
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = defaultColor

        guard let highlightedRange,
            let attributedRange = Range(highlightedRange, in: attributed)
        else {
            return attributed
        }

        attributed[attributedRange].foregroundColor = highlightColor
        attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
        return attributed
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

    static func popupStatusDotSlotWidth(dotDiameter: CGFloat) -> CGFloat {
        dotDiameter
    }

    static func popupTrailingAccessoryReserve(
        baseReserve: CGFloat,
        shortcutLabelWidth: CGFloat,
        showsShortcutLabels: Bool
    ) -> CGFloat {
        showsShortcutLabels ? baseReserve + shortcutLabelWidth : baseReserve
    }

    static func popupContainerHeight(allocatedContainerHeight: CGFloat) -> CGFloat {
        allocatedContainerHeight
    }

    static func popupHeightFrame(
        idealContainerHeight: CGFloat,
        minimumPopoverHeight: CGFloat
    ) -> PopupHeightFrame {
        return PopupHeightFrame(
            fixedHeight: nil,
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
