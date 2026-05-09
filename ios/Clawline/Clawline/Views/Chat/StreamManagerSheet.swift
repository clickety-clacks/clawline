//
//  StreamManagerSheet.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI
import UIKit

struct StreamManagerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings

    @Bindable var viewModel: ChatViewModel
    let streams: [StreamSession]
    let dotStatesBySession: [String: StreamDotState]
    let searchFocusRequestID: Int?
    let maxAvailableHeight: CGFloat
    let maxAvailableWidth: CGFloat
    let onSelectStream: (String) -> Void
    let onRequestTrackPicker: () -> Void
    let onConsumeSearchFocusRequest: () -> Void

    @State private var draftName = ""
    @State private var searchQuery = ""
    @State private var activeEditor: EditorMode?
    @State private var isWorking = false
    @State private var removingSessionKeys: Set<String> = []
    @State private var pendingCreateRows: [PendingCreateRow] = []
    @State private var pendingRemovalStream: StreamSession?
    @State private var selectedStreamSessionKey: String?
    @State private var didActivateSelection = false
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

    private func listViewportHeight(containerHeight: CGFloat) -> CGFloat {
        StreamSelectorLayout.listViewportHeight(
            containerHeight: containerHeight,
            actionBarReservedHeight: actionBarReservedHeight
        )
    }

    private var cappedContainerHeight: CGFloat {
        StreamSelectorLayout.containerHeight(
            itemCount: listItemCount,
            showsCreateInlineRow: false,
            rowHeight: listRowHeight,
            rowSpacing: listRowSpacing,
            functionBarHeight: actionBarReservedHeight,
            outerVerticalPadding: listOuterVerticalPadding,
            maxAvailableHeight: maxAvailableHeight,
            minimumPopoverHeight: minimumPopoverHeight
        )
    }

    var body: some View {
        let _ = settings.fontScaleChangeSequence
        GeometryReader { geometry in
            // Trust the allocated size. If the popover system gives us less than our ideal,
            // the List viewport shrinks to match instead of overflowing into the popup chrome.
            let containerHeight = geometry.size.height
            VStack(spacing: 0) {
                List {
                    ForEach(filteredStreams) { stream in
                        rowContent(for: stream)
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
                .frame(height: listViewportHeight(containerHeight: containerHeight))
                .clipShape(Rectangle())
                .disabled(isWorking)

                bottomActionBar
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(
            minWidth: minimumPopoverWidth,
            idealWidth: idealPopoverWidth,
            maxWidth: maximumPopoverWidth
        )
        .frame(
            // Clamp the floor to the capped height so we never produce an inconsistent
            // (minHeight > maxHeight) frame when the window is shorter than our preferred minimum.
            minHeight: min(minimumPopoverHeight, cappedContainerHeight),
            idealHeight: cappedContainerHeight,
            maxHeight: cappedContainerHeight,
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
        .onAppear {
            syncSelectionWithFilteredStreams()
            handleSearchFocusRequest(searchFocusRequestID)
        }
        .onDisappear {
            resetInlineEditing()
            searchQuery = ""
            isSearchFieldFocused = false
            selectedStreamSessionKey = nil
            didActivateSelection = false
        }
        .onChange(of: searchFocusRequestID) { _, requestID in
            handleSearchFocusRequest(requestID)
        }
        .onChange(of: searchQuery) { _, _ in
            syncSelectionWithFilteredStreams()
        }
        .onChange(of: streams.map(\.sessionKey)) { _, _ in
            syncSelectionWithFilteredStreams()
        }
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

    @ViewBuilder
    private func rowContent(for stream: StreamSession) -> some View {
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
                HStack(spacing: 10) {
                    let isActive = stream.sessionKey == viewModel.uiSelectedSessionKey
                    let dotState = dotStatesBySession[stream.sessionKey] ?? .inactive
                    Circle()
                        .fill(
                            StreamDotColor.resolve(
                                isActive: isActive,
                                dotState: dotState,
                                colorScheme: colorScheme
                            )
                        )
                        .frame(width: 8, height: 8)
                        .shadow(
                            color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                            radius: isActive ? StreamDotColor.activeOuterGlowRadius(colorScheme: colorScheme) : 0
                        )
                        .shadow(
                            color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                            radius: isActive ? StreamDotColor.activeInnerGlowRadius(colorScheme: colorScheme) : 0
                        )
                    Text(stream.displayName)
                        .font(.clawline(.subsectionHeader).weight(isActive ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isRemovingStream(stream.sessionKey) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isRemovingStream(stream.sessionKey))
        }
    }

    private func rowBackground(for stream: StreamSession) -> Color {
        guard selectedStreamSessionKey == stream.sessionKey else { return .clear }
        return Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08)
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

enum StreamSelectorLayout {
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

    /// Adaptive height for the stream list viewport given an actual allocated container height.
    ///
    /// This is used by the popup to shrink the scrollable list viewport when the popover
    /// system allocates less vertical space than the popup's ideal height, so list content
    /// never overflows into the popup chrome or past the visible popup bounds.
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
