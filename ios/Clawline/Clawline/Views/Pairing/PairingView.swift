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

    // Device corner radius for concentric alignment.
    // Face ID devices have ~50pt corner radius, home button devices have 0.
    private var deviceCornerRadius: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    private var concentricPadding: CGFloat {
        max(deviceCornerRadius - 24, 8)  // 48pt button height / 2 = 24
    }

    var body: some View {
        // GeometryReader needed for inputScrollView width calculation
        GeometryReader { geometry in
            VStack {
                Spacer()

                // Bottom-anchored content
                VStack(spacing: 0) {
                    // App icon
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 24)

                    // Title and subtitle
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Clawline")
                            .font(.system(size: 38, weight: .light))
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
                        // Subtract horizontal padding from width since inputScrollView sizes
                        // its content to fill the width, but padding is applied outside it
                        inputScrollView(width: geometry.size.width - (2 * concentricPadding))
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

    private func inputScrollView(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    nameInputRow
                        .frame(width: width)
                        .opacity(viewModel.currentPage == 0 ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.currentPage)
                        .id(0)

                    addressInputRow
                        .frame(width: width)
                        .opacity(viewModel.currentPage == 1 ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.currentPage)
                        .id(1)

                    waitingInputRow
                        .frame(width: width)
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
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)

                TextField("Your name", text: $viewModel.nameInput)
                    .font(.body)
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
            .glassEffect(.regular, in: Capsule())

            // Checkmark to proceed to address
            Button {
                viewModel.submitName()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
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
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: inputHeight, height: inputHeight)
            .glassEffect(.regular.interactive(), in: Circle())

            // Text field with server icon
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)

                TextField("Server address", text: $viewModel.addressInput)
                    .font(.body)
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
            .glassEffect(.regular, in: Capsule())

            // Send button to submit
            Button {
                viewModel.submitAddress()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
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
            // Status bubble with text and spinner
            HStack(alignment: .center, spacing: 12) {
                if isStalled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This might take a while, check back soon")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text("Tap retry to resubmit the request.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Waiting for owner")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Spacer()

                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: Capsule())

            if isStalled {
                Button {
                    viewModel.retryPendingPairing()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: inputHeight, height: inputHeight)
                .background(Color.accentColor, in: Circle())
                .accessibilityLabel("Retry pairing request")
            } else {
                // X button to cancel
                Button {
                    viewModel.cancelPairing()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: inputHeight, height: inputHeight)
                .background(Color.red, in: Circle())
            }
        }
    }

    private func errorContent(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)

            Text(message)
                .font(.body)
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
    func storeCredentials(token: String, userId: String) {}
    func clearCredentials() {}
}

private final class PreviewConnectionService: ConnectionServicing {
    func requestPairing(serverURL: URL, claimedName: String, deviceId: String) async throws -> PairingResult {
        try await Task.sleep(for: .seconds(2))
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
