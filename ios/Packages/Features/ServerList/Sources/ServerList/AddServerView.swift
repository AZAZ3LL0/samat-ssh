import AgentKit
import DesignSystem
import Persistence
import SwiftUI

/// Sheet that adds a server by host and port. `onPaired` gets the id of the saved server.
public struct AddServerView: View {
    @State private var model: AddServerModel
    @Environment(\.dismiss) private var dismiss
    private let onPaired: (UUID) -> Void

    public init(model: AddServerModel, onPaired: @escaping (UUID) -> Void) {
        _model = State(initialValue: model)
        self.onPaired = onPaired
    }

    public var body: some View {
        NavigationStack {
            Form {
                switch model.step {
                case .address, .paired:
                    addressSection
                case .verify(let probe):
                    verifySection(probe)
                case .code(let probe):
                    codeSection(probe)
                }
                if model.saveFailed {
                    Text("The server paired, but the app could not save it. Try again.", bundle: .module)
                        .foregroundStyle(DS.Palette.critical)
                }
            }
            // Cancel stays live: a probe of a silent host waits for the full timeout.
            .disabled(model.isWorking)
            .navigationTitle(Text("Add server", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
            }
            .onChange(of: model.step) { _, step in
                if case .paired(let id) = step {
                    onPaired(id)
                    dismiss()
                }
            }
        }
    }

    private var addressSection: some View {
        Section {
            TextField(String(localized: "Host or IP address", bundle: .module), text: $model.host)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("addServer.host")
            TextField(String(localized: "Port", bundle: .module), text: $model.port)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("addServer.port")
            if let error = model.error {
                ErrorBanner(error: error)
            }
            actionButton(String(localized: "Connect", bundle: .module), enabled: model.canConnect) {
                await model.connect()
            }
            .accessibilityIdentifier("addServer.connect")
        } footer: {
            Text("The agent listens on port 7443 unless its config.yaml says otherwise.", bundle: .module)
        }
    }

    private func verifySection(_ probe: AgentProbe) -> some View {
        Group {
            Section {
                Text(probe.fingerprint)
                    .font(DS.Typography.log)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("addServer.fingerprint")
                LabeledContent(String(localized: "Hostname", bundle: .module), value: probe.info.hostname)
                LabeledContent(String(localized: "Agent version", bundle: .module), value: probe.info.agentVersion)
            } header: {
                Text("Fingerprint", bundle: .module)
            } footer: {
                Text(
                    "Run sudo pulse-agent pair on the server. Go on only if its fingerprint is exactly the same.",
                    bundle: .module
                )
            }
            Section {
                Button(String(localized: "Fingerprints match", bundle: .module)) { model.confirmFingerprint() }
                Button(String(localized: "They differ", bundle: .module), role: .destructive) {
                    model.rejectFingerprint()
                }
            } footer: {
                Text(
                    "A different fingerprint means another machine answered. Check the address and the network.",
                    bundle: .module
                )
            }
        }
    }

    private func codeSection(_ probe: AgentProbe) -> some View {
        Section {
            TextField(String(localized: "Name", bundle: .module), text: $model.name, prompt: Text(probe.info.hostname))
                .accessibilityIdentifier("addServer.name")
            TextField(String(localized: "Pairing code", bundle: .module), text: $model.code)
                .font(DS.Typography.log)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("addServer.code")
            if let error = model.error {
                if error == .unauthorized {
                    // The agent answers the same for unknown, expired and used codes.
                    Text("The code is wrong, expired or already used. Run pulse-agent pair again.", bundle: .module)
                        .foregroundStyle(DS.Palette.critical)
                } else {
                    ErrorBanner(error: error)
                }
            }
            actionButton(String(localized: "Pair", bundle: .module), enabled: model.canPair) {
                await model.pair()
            }
            .accessibilityIdentifier("addServer.pair")
        } footer: {
            Text("The code from pulse-agent pair works once, for 10 minutes.", bundle: .module)
        }
    }

    private func actionButton(_ title: String, enabled: Bool, run: @escaping () async -> Void) -> some View {
        Button {
            Task { await run() }
        } label: {
            HStack {
                Text(title)
                if model.isWorking {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(!enabled)
    }
}

#Preview {
    if let container = try? PulseStore.makeContainer(inMemory: true) {
        AddServerView(
            model: AddServerModel(
                pairing: FakeAgentPairing(), secrets: InMemorySecretStore(),
                context: container.mainContext, deviceName: "iPhone"),
            onPaired: { _ in }
        )
    }
}
