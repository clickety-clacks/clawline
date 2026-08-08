//
//  StreamCreationSheet.swift
//  Clawline
//
//  T-B (ticket T1750): the tightbeam-only new-chat creation sheet. The name-only
//  create gains optional harness / model / host / archetype choices populated
//  from GET /api/org-options (fetched on demand into ChatViewModel.orgOptions,
//  read here via ChatViewModel.orgOptionsState so loading/empty/failed render
//  honestly instead of a frozen picker). All four choices are optional; a plain
//  name-only create still works exactly as before (the gateway applies
//  defaults). The server validates placement and returns the stream or a named
//  refusal; a placement-rule refusal is surfaced verbatim, but a catalog
//  staleness/routing refusal is humanized (ChatViewModel.humaneCreateRefusalMessage)
//  rather than leaking raw substrate text. On openclaw the sheet never presents —
//  the "+" affordance keeps its name-only direct create (see StreamCreationLaunchPolicy).
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

    /// The loaded catalog, or nil while loading/failed. Callers that need a
    /// concrete `OrgOptions` to read arrays off of (host/archetype narrowing)
    /// fall back to `.empty`; callers that need to tell "no data yet" apart
    /// from "loaded and genuinely empty" read this directly.
    private var loadedOrgOptions: OrgOptions? {
        if case .loaded(let options) = viewModel.orgOptionsState { return options }
        return nil
    }

    private var orgOptions: OrgOptions {
        loadedOrgOptions ?? OrgOptions.empty
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
                    switch viewModel.orgOptionsState {
                    case .loading:
                        HStack {
                            ProgressView()
                            Text("Loading placement options…")
                                .foregroundStyle(.secondary)
                        }
                    case .failed:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Couldn't load placement options.")
                                .foregroundStyle(.secondary)
                            Button("Retry") { viewModel.retryOrgOptionsLoad() }
                        }
                    case .loaded:
                        placementPickers
                    }
                } header: {
                    Text("Placement")
                } footer: {
                    if case .failed = viewModel.orgOptionsState {
                        Text("You can still create with default placement.")
                            .font(.clawline(.secondaryLabel))
                    }
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
            .onAppear { viewModel.loadOrgOptionsIfNeeded() }
        }
    }

    /// The four placement axes once the catalog has loaded. Each axis renders
    /// its own honest empty state instead of a silently `.disabled` picker —
    /// a genuinely empty axis (e.g. a codex-only install with no models) means
    /// there is nothing to select, not that the control is broken.
    @ViewBuilder
    private var placementPickers: some View {
        placementAxis(
            title: "Harness",
            options: orgOptions.harnesses,
            emptyMessage: "No harnesses available — onboarding needed.",
            selection: $selectedHarness
        )

        if !modelOptions.isEmpty {
            Picker("Model", selection: $selectedModel) {
                Text("Default").tag(String?.none)
                ForEach(modelOptions, id: \.ref) { model in
                    Text(model.name).tag(String?.some(model.ref))
                }
            }
        } else if selectedHarness != nil {
            placementEmptyRow(title: "Model", message: "No models available for this harness — onboarding needed.")
        }

        placementAxis(
            title: "Archetype",
            options: orgOptions.archetypes.map(\.name),
            emptyMessage: "No archetypes available — onboarding needed.",
            selection: $selectedArchetype
        )

        placementAxis(
            title: "Host",
            options: allowedHosts,
            emptyMessage: "No hosts available — onboarding needed.",
            selection: $selectedHost
        )
    }

    @ViewBuilder
    private func placementAxis(
        title: String,
        options: [String],
        emptyMessage: String,
        selection: Binding<String?>
    ) -> some View {
        if options.isEmpty {
            placementEmptyRow(title: title, message: emptyMessage)
        } else {
            Picker(title, selection: selection) {
                Text("Default").tag(String?.none)
                ForEach(options, id: \.self) { value in
                    Text(value).tag(String?.some(value))
                }
            }
        }
    }

    private func placementEmptyRow(title: String, message: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(message)
                .font(.clawline(.secondaryLabel))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
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
