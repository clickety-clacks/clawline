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

    init(auth: any AuthManaging, connection: any ConnectionServicing, device: any DeviceIdentifying) {
        _viewModel = State(initialValue: PairingViewModel(
            auth: auth,
            connection: connection,
            device: device
        ))
    }

    // Concentric padding for bottom button
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
        GeometryReader { geometry in
            VStack {
                Spacer()

                // Bottom-anchored content
                VStack(alignment: .leading, spacing: 0) {
                    // App icon
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(.tint)
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
                    .padding(.bottom, 24)

                    // State-specific content
                    switch viewModel.state {
                    case .idle, .enteringName, .enteringAddress, .waitingForApproval:
                        inputScrollView(width: geometry.size.width - (concentricPadding * 2))
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
    }

    private var subtitleText: String {
        switch viewModel.state {
        case .enteringAddress:
            return "Enter server address"
        case .waitingForApproval:
            return "Awaiting approval"
        default:
            return "Connect to get started"
        }
    }

    private func inputScrollView(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Page 0: Name input
                    nameInputRow
                        .frame(width: width)
                        .id(0)

                    // Page 1: Address input
                    addressInputRow
                        .frame(width: width)
                        .id(1)

                    // Page 2: Waiting for approval
                    waitingInputRow
                        .frame(width: width)
                        .id(2)
                }
            }
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .onChange(of: viewModel.currentPage) { _, newPage in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newPage, anchor: .leading)
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
                    .submitLabel(.next)
                    .onSubmit {
                        viewModel.submitName()
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: inputHeight)
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
            .background(Color.accentColor)
            .clipShape(Circle())
            .opacity(viewModel.isNameValid ? 1 : 0.4)
            .disabled(!viewModel.isNameValid)
        }
        .background(.clear)
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
                    .onSubmit {
                        Task { await viewModel.submitAddress() }
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: inputHeight)
            .glassEffect(.regular, in: Capsule())

            // Send button to submit
            Button {
                Task { await viewModel.submitAddress() }
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
        .background(.clear)
    }

    private var waitingInputRow: some View {
        HStack(spacing: 12) {
            // Status bubble with text and spinner
            HStack(spacing: 12) {
                Text("Waiting for owner")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Spacer()

                ProgressView()
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .frame(height: inputHeight)
            .glassEffect(.regular, in: Capsule())

            // X button to cancel
            Button {
                viewModel.cancelPairing()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: inputHeight, height: inputHeight)
            .background(Color.accentColor, in: Circle())
        }
        .background(.clear)
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
            viewModel.state = .idle
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
