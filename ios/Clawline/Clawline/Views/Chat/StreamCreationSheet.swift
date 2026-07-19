//
//  StreamCreationSheet.swift
//  Clawline
//
//  T-B (ticket T1750): the tightbeam-only new-chat creation sheet. The name-only
//  create gains optional harness / model / host / archetype choices populated
//  from GET /api/org-options (fetched on demand into ChatViewModel.orgOptions).
//  All four choices are optional; a plain name-only create still works exactly as
//  before (the gateway applies defaults). The server validates placement and
//  either returns the stream or a named refusal whose message is surfaced here
//  verbatim. On openclaw the sheet never presents — the "+" affordance keeps its
//  name-only direct create (see StreamCreationLaunchPolicy).
//

import SwiftUI

/// Decides whether the stream-creation affordance opens the placement sheet or
/// performs the legacy name-only direct create. Tightbeam gets the sheet;
/// openclaw is unchanged.
enum StreamCreationLaunchPolicy {
    static func usesCreationSheet(isTightbeamServer: Bool) -> Bool {
        isTightbeamServer
    }
}

/// Constrains the host picker to an archetype's allowed placements. With no
/// archetype the full assimilated host set is offered; a `where` of `["*"]`
/// means any listed host; otherwise only assimilated hosts named in `where`
/// (preserving the assimilated ordering) are offered.
enum StreamCreationHostConstraint {
    static func allowedHosts(hosts: [String], archetype: OrgOptions.Archetype?) -> [String] {
        guard let archetype else { return hosts }
        if archetype.where.contains("*") { return hosts }
        return hosts.filter { archetype.where.contains($0) }
    }
}

struct StreamCreationSheet: View {
    @Bindable var viewModel: ChatViewModel
    let defaultName: String

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selectedHarness: String?
    @State private var selectedModel: String?
    @State private var selectedHost: String?
    @State private var selectedArchetype: String?
    @State private var isWorking = false
    @State private var refusalMessage: String?

    init(viewModel: ChatViewModel, defaultName: String) {
        self.viewModel = viewModel
        self.defaultName = defaultName
        _name = State(initialValue: defaultName)
    }

    private var orgOptions: OrgOptions {
        viewModel.orgOptions ?? OrgOptions.empty
    }

    private var modelOptions: [OrgOptions.HarnessModel] {
        guard let selectedHarness else { return [] }
        return orgOptions.models[selectedHarness] ?? []
    }

    private var selectedArchetypeObject: OrgOptions.Archetype? {
        guard let selectedArchetype else { return nil }
        return orgOptions.archetypes.first { $0.name == selectedArchetype }
    }

    private var allowedHosts: [String] {
        StreamCreationHostConstraint.allowedHosts(
            hosts: orgOptions.hosts,
            archetype: selectedArchetypeObject
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(false)
                        .submitLabel(.done)
                        .onSubmit { if canCreate { Task { await create() } } }
                }

                Section {
                    Picker("Harness", selection: $selectedHarness) {
                        Text("Default").tag(String?.none)
                        ForEach(orgOptions.harnesses, id: \.self) { harness in
                            Text(harness).tag(String?.some(harness))
                        }
                    }
                    .disabled(orgOptions.harnesses.isEmpty)

                    if !modelOptions.isEmpty {
                        Picker("Model", selection: $selectedModel) {
                            Text("Default").tag(String?.none)
                            ForEach(modelOptions, id: \.ref) { model in
                                Text(model.name ?? model.ref).tag(String?.some(model.ref))
                            }
                        }
                    }

                    Picker("Archetype", selection: $selectedArchetype) {
                        Text("Default").tag(String?.none)
                        ForEach(orgOptions.archetypes, id: \.name) { archetype in
                            Text(archetype.name).tag(String?.some(archetype.name))
                        }
                    }
                    .disabled(orgOptions.archetypes.isEmpty)

                    Picker("Host", selection: $selectedHost) {
                        Text("Default").tag(String?.none)
                        ForEach(allowedHosts, id: \.self) { host in
                            Text(host).tag(String?.some(host))
                        }
                    }
                    .disabled(allowedHosts.isEmpty)
                } header: {
                    Text("Placement")
                }

                if let refusalMessage {
                    Section {
                        Text(refusalMessage)
                            .font(.clawline(.secondaryLabel))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(!canCreate)
                    }
                }
            }
            .onChange(of: selectedHarness) { _, _ in reconcileModelSelection() }
            .onChange(of: selectedArchetype) { _, _ in reconcileHostSelection() }
        }
    }

    /// A harness switch invalidates any model chosen for the previous harness.
    private func reconcileModelSelection() {
        guard let selectedModel else { return }
        if !modelOptions.contains(where: { $0.ref == selectedModel }) {
            self.selectedModel = nil
        }
    }

    /// An archetype switch can narrow the host set; drop a host it no longer allows.
    private func reconcileHostSelection() {
        guard let selectedHost else { return }
        if !allowedHosts.contains(selectedHost) {
            self.selectedHost = nil
        }
    }

    private func create() async {
        isWorking = true
        refusalMessage = nil
        let outcome = await viewModel.createStream(
            displayName: name,
            harness: selectedHarness,
            model: selectedModel,
            host: selectedHost,
            archetype: selectedArchetype
        )
        isWorking = false
        switch outcome {
        case .created:
            dismiss()
        case .failed(let message):
            // Surface the server's refusal rule verbatim; nothing to show for an
            // empty-name guard (message == nil).
            if let message, !message.isEmpty {
                refusalMessage = message
            }
        }
    }
}
