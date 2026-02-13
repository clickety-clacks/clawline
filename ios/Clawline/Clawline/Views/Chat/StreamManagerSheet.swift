//
//  StreamManagerSheet.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI

struct StreamManagerSheet: View {
    @Bindable var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    let maxAvailableHeight: CGFloat
    let onSelectStream: (String) -> Void

    @State private var draftName = ""
    @State private var activeEditor: EditorMode?
    @State private var isWorking = false
    @State private var deletingSessionKeys: Set<String> = []
    @State private var pendingCreateRows: [PendingCreateRow] = []
    @FocusState private var focusedEditor: EditorMode?

    private enum EditorMode: Hashable {
        case renaming(String)
    }

    private struct PendingCreateRow: Identifiable, Hashable {
        let id: UUID
        let displayName: String
    }

    private let listRowHeight: CGFloat = 52
    private let listRowSpacing: CGFloat = 8
    private let functionBarHeight: CGFloat = 58
    private let listOuterVerticalPadding: CGFloat = 16
    private let minimumPopoverHeight: CGFloat = 140
    private let popupCornerRadius: CGFloat = 20

    private var listItemCount: Int {
        viewModel.orderedStreams.count + pendingCreateRows.count
    }

    private var allowsListScrolling: Bool {
        StreamSelectorLayout.isOverflowing(
            itemCount: listItemCount,
            showsCreateInlineRow: false,
            rowHeight: listRowHeight,
            rowSpacing: listRowSpacing,
            functionBarHeight: functionBarHeight,
            outerVerticalPadding: listOuterVerticalPadding,
            maxAvailableHeight: maxAvailableHeight,
            minimumPopoverHeight: minimumPopoverHeight
        )
    }

    private var cappedContainerHeight: CGFloat {
        StreamSelectorLayout.containerHeight(
            itemCount: listItemCount,
            showsCreateInlineRow: false,
            rowHeight: listRowHeight,
            rowSpacing: listRowSpacing,
            functionBarHeight: functionBarHeight,
            outerVerticalPadding: listOuterVerticalPadding,
            maxAvailableHeight: maxAvailableHeight,
            minimumPopoverHeight: minimumPopoverHeight
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(viewModel.orderedStreams) { stream in
                    rowContent(for: stream)
                        .frame(minHeight: listRowHeight, alignment: .center)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                beginRenaming(stream)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .disabled(!canPerformRenameAction(for: stream))
                            .tint(canPerformRenameAction(for: stream) ? .blue : Color.gray.opacity(0.35))

                            Button {
                                Task { await deleteStream(stream) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(!canPerformDeleteAction(for: stream))
                            .tint(canPerformDeleteAction(for: stream) ? .red : Color.gray.opacity(0.35))
                        }
                }

                ForEach(pendingCreateRows) { pendingRow in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 8, height: 8)
                        Text(pendingRow.displayName)
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .frame(minHeight: listRowHeight, alignment: .center)
                    .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)
            .listRowSpacing(listRowSpacing)
            .scrollDisabled(!allowsListScrolling)
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .padding(.vertical, listOuterVerticalPadding)
            .disabled(isWorking)

            // Keep add affordance vertically centered regardless of keyboard/layout changes.
            ZStack {
                Button {
                    addStreamDirectly()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.primary)
                    .frame(width: 44, height: 44, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(activeEditor != nil)
                .accessibilityLabel("Add stream")
                .accessibilityHint("Creates a new stream")
            }
            .frame(maxWidth: .infinity)
            .frame(height: functionBarHeight, alignment: .center)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        .frame(height: cappedContainerHeight)
#if !os(visionOS)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
#endif
        .background(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .onChange(of: isPresented) { _, presented in
            if !presented {
                resetInlineEditing()
            }
        }
    }

    @ViewBuilder
    private func rowContent(for stream: StreamSession) -> some View {
        if activeEditor == .renaming(stream.sessionKey) {
            TextField("Stream name", text: $draftName)
                .font(.system(size: 28))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .focused($focusedEditor, equals: .renaming(stream.sessionKey))
                .onSubmit {
                    Task { await renameStream(stream) }
                }
        } else {
            Button {
                onSelectStream(stream.sessionKey)
                isPresented = false
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(stream.sessionKey == viewModel.activeSessionKey ? Color.accentColor : Color.primary.opacity(0.25))
                        .frame(width: 8, height: 8)
                    Text(stream.displayName)
                        .font(.system(size: 28, weight: stream.sessionKey == viewModel.activeSessionKey ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isDeletingStream(stream.sessionKey) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isDeletingStream(stream.sessionKey))
            .contentShape(Rectangle())
        }
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
        deletingSessionKeys.removeAll()
        pendingCreateRows.removeAll()
    }

    private func canPerformRenameAction(for stream: StreamSession) -> Bool {
        guard !isWorking else { return false }
        guard !isDeletingStream(stream.sessionKey) else { return false }
        guard activeEditor != .renaming(stream.sessionKey) else { return false }
        return viewModel.canRenameStream(sessionKey: stream.sessionKey)
    }

    private func canPerformDeleteAction(for stream: StreamSession) -> Bool {
        guard !isWorking else { return false }
        guard !isDeletingStream(stream.sessionKey) else { return false }
        guard activeEditor != .renaming(stream.sessionKey) else { return false }
        return viewModel.canDeleteStream(sessionKey: stream.sessionKey)
    }

    private func isDeletingStream(_ sessionKey: String) -> Bool {
        deletingSessionKeys.contains(sessionKey)
    }

    private func addStreamDirectly() {
        let existingCount = viewModel.orderedStreams.count + pendingCreateRows.count
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

    private func renameStream(_ stream: StreamSession) async {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        let succeeded = await viewModel.renameStream(sessionKey: stream.sessionKey, displayName: trimmed)
        isWorking = false
        guard succeeded else { return }
        resetInlineEditing()
    }

    private func deleteStream(_ stream: StreamSession) async {
        guard !isDeletingStream(stream.sessionKey) else { return }
        deletingSessionKeys.insert(stream.sessionKey)
        let succeeded = await viewModel.deleteStream(sessionKey: stream.sessionKey)
        if !succeeded {
            deletingSessionKeys.remove(stream.sessionKey)
        }
        if activeEditor == .renaming(stream.sessionKey) {
            resetInlineEditing()
        }
    }
}

enum StreamSelectorLayout {
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
        let cap = max(minimumPopoverHeight, maxAvailableHeight)
        return min(desired, cap)
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
        let rows = max(1, itemCount + (showsCreateInlineRow ? 1 : 0))
        let interRowSpacing = CGFloat(max(0, rows - 1)) * rowSpacing
        let listHeight = CGFloat(rows) * rowHeight + interRowSpacing + (outerVerticalPadding * 2)
        return listHeight + functionBarHeight
    }
}
