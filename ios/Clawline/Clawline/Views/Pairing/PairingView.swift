//
//  PairingView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit

struct PairingView: View {
    @State private var viewModel: PairingViewModel
    @Environment(\.scenePhase) private var scenePhase

    private enum FocusedField {
        case name, address
    }
    @FocusState private var focusedField: FocusedField?

    init(auth: any AuthManaging, connection: any ConnectionServicing, device: any DeviceIdentifying) {
        _viewModel = State(initialValue: PairingViewModel(
            auth: auth,
            connection: connection,
            device: device
        ))
    }

    var body: some View {
        // GeometryReader needed for inputScrollView width calculation
        GeometryReader { geometry in
            // Avoid reaching into UIKit's key window/safeAreaInsets from SwiftUI layout. On cold start
            // (esp. after reinstall when we route straight into pairing), that can create an
            // AttributeGraph layout cycle and render as a black screen. GeometryReader's safe area
            // is a stable SwiftUI-owned dependency.
            let hasRoundedCorners = geometry.safeAreaInsets.bottom > 0
            let deviceCornerRadius: CGFloat = hasRoundedCorners ? 50 : 0
            let concentricPadding: CGFloat = max(deviceCornerRadius - 24, 8)  // 48pt button height / 2 = 24

            VStack {
                Spacer(minLength: 50)

                // Content anchored above the input bar
                VStack(spacing: 0) {
                    // App icon
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.clawline(.sectionHeader))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 24)

                    // Title and subtitle
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Clawline")
                            .font(.clawline(.sectionHeader))
                            .tracking(1)

                        Text(subtitleText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)

                    // State-specific content
                    switch viewModel.state {
                    case .idle, .enteringName, .enteringAddress, .waitingForApproval(_, _):
                        inputScrollView()
                            .frame(height: inputHeight)
                    case .success:
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, alignment: .center)
                    case .error(let message):
                        errorContent(message: message)
                    }
                }
                .padding(.horizontal, concentricPadding)
                .padding(.bottom, concentricPadding)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            viewModel.retryPendingIfNeeded()
        }
    }

    private var subtitleText: String {
        switch viewModel.state {
        case .enteringAddress:
            return "Enter server address"
        case .waitingForApproval(_, _):
            return "Awaiting approval"
        default:
            return "Connect to get started"
        }
    }

    private func inputScrollView() -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    nameInputRow
                        .containerRelativeFrame(.horizontal)
                        .opacity(viewModel.currentPage == 0 ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.currentPage)
                        .id(0)

                    addressInputRow
                        .containerRelativeFrame(.horizontal)
                        .opacity(viewModel.currentPage == 1 ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.currentPage)
                        .id(1)

                    waitingInputRow
                        .containerRelativeFrame(.horizontal)
                        .opacity(viewModel.currentPage == 2 ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.currentPage)
                        .id(2)
                }
            }
            .scrollDisabled(true)
            .scrollClipDisabled()
            .onAppear {
                // Scroll to correct page when view appears (e.g., returning from error state)
                proxy.scrollTo(viewModel.currentPage, anchor: .leading)
            }
            .onChange(of: viewModel.currentPage) { _, newPage in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newPage, anchor: .leading)
                }
                // Auto-focus the appropriate field after page transition
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    switch newPage {
                    case 0: focusedField = .name
                    case 1: focusedField = .address
                    default: focusedField = nil
                    }
                }
            }
        }
    }

    private let inputHeight: CGFloat = 48

    private var nameInputRow: some View {
        HStack(spacing: 12) {
            // Text field with person icon
            HStack(spacing: 12) {
                Image(systemName: "person")
                    .font(.clawline(.uiLabel))
                    .foregroundStyle(.secondary)

                TextField("Your name", text: $viewModel.nameInput)
                    .font(.clawline(.uiLabel))
                    .textFieldStyle(.plain)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .name)
                    .onSubmit {
                        viewModel.submitName()
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity)
#if os(visionOS)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.3))
            )
#else
            .glassEffect(.regular, in: Capsule())
#endif

            // Checkmark to proceed to address
            Button {
                viewModel.submitName()
            } label: {
                Image(systemName: "checkmark")
                    .font(.clawline(.uiLabel).weight(.semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .frame(width: inputHeight, height: inputHeight)
            .background(Color.accentColor, in: Circle())
            .opacity(viewModel.isNameValid ? 1 : 0.4)
            .disabled(!viewModel.isNameValid)
        }
    }

    private var addressInputRow: some View {
        HStack(spacing: 12) {
            // Back button
            Button {
                viewModel.goBackToName()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.clawline(.uiLabel).weight(.semibold))
            }
            .buttonStyle(.plain)
            .frame(width: inputHeight, height: inputHeight)
#if os(visionOS)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.3))
            )
#else
            .glassEffect(.regular.interactive(), in: Circle())
#endif

            // Text field with server icon
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.clawline(.uiLabel))
                    .foregroundStyle(.secondary)

                TextField("Server address", text: $viewModel.addressInput)
                    .font(.clawline(.uiLabel))
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .address)
                    .onSubmit {
                        viewModel.submitAddress()
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity)
#if os(visionOS)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.3))
            )
#else
            .glassEffect(.regular, in: Capsule())
#endif

            // Send button to submit
            Button {
                viewModel.submitAddress()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.clawline(.uiLabel).weight(.semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .frame(width: inputHeight, height: inputHeight)
            .background(Color.accentColor, in: Circle())
            .opacity(viewModel.isAddressValid ? 1 : 0.4)
            .disabled(!viewModel.isAddressValid)
        }
    }

    private var waitingInputRow: some View {
        let isStalled: Bool = {
            if case .waitingForApproval(_, let stalled) = viewModel.state {
                return stalled
            }
            return false
        }()

        return HStack(spacing: 12) {
            if isStalled {
                // Back button to return to address entry when pairing is stalled.
                Button {
                    viewModel.cancelPairing()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.clawline(.uiLabel).weight(.semibold))
                }
                .buttonStyle(.plain)
                .frame(width: inputHeight, height: inputHeight)
#if os(visionOS)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.3))
                )
#else
                .glassEffect(.regular.interactive(), in: Circle())
#endif
                .accessibilityLabel("Back to server address")
            }

            // Status bubble with text and spinner
            HStack(alignment: .center, spacing: 12) {
                if isStalled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This might take a while, check back soon")
                            .font(.clawline(.uiLabel))
                            .foregroundStyle(.secondary)
                        Text("Tap retry to resubmit the request.")
                            .font(.clawline(.secondaryLabel))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "clock.arrow.circlepath")
                        .font(.clawline(.subsectionHeader))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ask your agent to approve registration…")
                        .font(.clawline(.uiLabel))
                        .foregroundStyle(.secondary)

                    Spacer()

                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity)
#if os(visionOS)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.3))
            )
#else
            .glassEffect(.regular, in: Capsule())
#endif

            if isStalled {
                Button {
                    viewModel.retryPendingPairing()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(width: inputHeight, height: inputHeight)
                .background(Color.accentColor, in: Circle())
                .accessibilityLabel("Retry pairing request")
            } else {
                // X button to cancel
                Button {
                    viewModel.cancelPairing()
                } label: {
                    Image(systemName: "xmark")
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(width: inputHeight, height: inputHeight)
                .background(Color.red, in: Circle())
            }
        }
    }

    private func errorContent(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.clawline(.subsectionHeader))
                .foregroundStyle(.red)

            Text(message)
                .font(.clawline(.uiLabel))
                .foregroundStyle(.secondary)
        }
        .onTapGesture {
            viewModel.dismissError()
        }
    }
}

// MARK: - Previews

@Observable
private final class PreviewAuthManager: AuthManaging {
    var isAuthenticated = false
    var currentUserId: String?
    var token: String?
    var isAdmin: Bool = false
    func storeCredentials(token: String, userId: String) {}
    func updateAdminStatus(_ isAdmin: Bool) {}
    func refreshAdminStatusFromToken() {}
    func clearCredentials() {}
}

private final class PreviewConnectionService: ConnectionServicing {
    func requestPairing(serverURL: URL, claimedName: String, deviceId: String) async throws -> PairingResult {
        try await Task.sleep(forDuration: .seconds(2))
        return .success(token: "preview-token", userId: claimedName)
    }
}

private struct PreviewDeviceIdentifier: DeviceIdentifying {
    var deviceId: String { "preview-device-id" }
}

#Preview("Name Entry") {
    PairingView(
        auth: PreviewAuthManager(),
        connection: PreviewConnectionService(),
        device: PreviewDeviceIdentifier()
    )
}

#Preview("Error State") {
    PairingView(
        auth: PreviewAuthManager(),
        connection: PreviewConnectionService(),
        device: PreviewDeviceIdentifier()
    )
}
