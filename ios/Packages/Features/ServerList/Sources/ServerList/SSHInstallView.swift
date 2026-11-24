import AgentKit
import DesignSystem
import Persistence
import SwiftUI

/// Installs the agent over SSH and pairs with it. `onPaired` gets the id of the saved server.
public struct SSHInstallView: View {
    @State private var model: SSHInstallModel
    private let onPaired: (UUID) -> Void

    public init(model: SSHInstallModel, onPaired: @escaping (UUID) -> Void) {
        _model = State(initialValue: model)
        self.onPaired = onPaired
    }

    public var body: some View {
        Form {
            switch model.step {
            case .form, .paired:
                formSection
            case .hostKey(let key):
                hostKeySection(key)
            case .ready(let facts):
                readySection(facts)
            }
        }
        .disabled(model.isWorking)
        .navigationTitle(Text("Install over SSH", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.step) { _, step in
            if case .paired(let id) = step { onPaired(id) }
        }
        .onDisappear {
            Task { await model.cancel() }
        }
    }

    private var formSection: some View {
        Section {
            TextField(String(localized: "Host or IP address", bundle: .module), text: $model.host)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("sshInstall.host")
            TextField(String(localized: "SSH port", bundle: .module), text: $model.port)
                .keyboardType(.numberPad)
            TextField(String(localized: "User", bundle: .module), text: $model.user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("sshInstall.user")
            // No password content type: iOS would offer to save the SSH password, which the app never keeps.
            SecureField(String(localized: "Password", bundle: .module), text: $model.password)
                .accessibilityIdentifier("sshInstall.password")
            TextField(
                String(localized: "Or paste a private key", bundle: .module), text: $model.privateKey, axis: .vertical
            )
            .font(DS.Typography.log)
            .lineLimit(3...6)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if !model.privateKey.isEmpty {
                SecureField(String(localized: "Key passphrase", bundle: .module), text: $model.passphrase)
            }
            errorView
            actionButton(String(localized: "Connect", bundle: .module), enabled: model.canConnect) {
                await model.readHostKey()
            }
            .accessibilityIdentifier("sshInstall.connect")
        } footer: {
            Text(
                """
                The password or key is used once for this install and \
                never saved. The app then logs in with its own key.
                """,
                bundle: .module)
        }
    }

    private func hostKeySection(_ key: SSHPublicKey) -> some View {
        Group {
            Section {
                Text(key.fingerprint)
                    .font(DS.Typography.log)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("sshInstall.fingerprint")
                LabeledContent(String(localized: "Key type", bundle: .module), value: key.algorithm)
            } header: {
                Text("Host key", bundle: .module)
            } footer: {
                Text(
                    """
                    Run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the server. Go \
                    on only if the fingerprint is exactly the same.
                    """,
                    bundle: .module)
            }
            Section {
                actionButton(String(localized: "Fingerprints match", bundle: .module), enabled: true) {
                    await model.trustHostKey()
                }
                .accessibilityIdentifier("sshInstall.trust")
                Button(String(localized: "They differ", bundle: .module), role: .destructive) {
                    model.rejectHostKey()
                }
            }
        }
    }

    private func readySection(_ facts: ServerFacts) -> some View {
        Section {
            LabeledContent(String(localized: "System", bundle: .module), value: facts.systemName)
            LabeledContent(String(localized: "Architecture", bundle: .module), value: facts.architecture)
            LabeledContent(
                String(localized: "Runs as", bundle: .module), value: facts.viaSudo ? "sudo" : "root")
            if !facts.supportedSystem {
                Text(
                    "Pulse supports Ubuntu 22.04, 24.04 and Debian 12. The agent may work here, without guarantees.",
                    bundle: .module
                )
                .foregroundStyle(DS.Palette.warning)
            }
            errorView
            actionButton(String(localized: "Install", bundle: .module), enabled: !model.isWorking) {
                await model.install()
            }
            .accessibilityIdentifier("sshInstall.install")
        } footer: {
            Text(
                """
                Installs the latest pulse-agent release, adds this app's \
                key to authorized_keys and pairs with the agent.
                """,
                bundle: .module)
        }
    }

    @ViewBuilder private var errorView: some View {
        if case .agent(let error) = model.error {
            ErrorBanner(error: error)
        } else if let error = model.error {
            Text(Self.message(error)).foregroundStyle(DS.Palette.critical)
        }
    }

    private func actionButton(_ title: String, enabled: Bool, run: @escaping () async -> Void) -> some View {
        Button {
            Task { await run() }
        } label: {
            HStack {
                Text(title)
                if let phase = model.phase {
                    Spacer()
                    Text(Self.message(phase)).foregroundStyle(.secondary)
                    ProgressView()
                }
            }
        }
        .disabled(!enabled)
    }

    static func message(_ phase: SSHInstallModel.Phase) -> String {
        switch phase {
        case .connecting: String(localized: "Connecting…", bundle: .module)
        case .checking: String(localized: "Checking the server…", bundle: .module)
        case .installing: String(localized: "Installing…", bundle: .module)
        case .authorizing: String(localized: "Adding the key…", bundle: .module)
        case .pairing: String(localized: "Pairing…", bundle: .module)
        }
    }

    static func message(_ error: SSHError) -> String {
        switch error {
        case .unreachable: String(localized: "The server does not answer on this port.", bundle: .module)
        case .timeout: String(localized: "The server did not answer in time.", bundle: .module)
        case .authenticationFailed: String(localized: "The server refused the user, password or key.", bundle: .module)
        case .hostKeyMismatch:
            String(localized: "The server presented another host key. Start over.", bundle: .module)
        case .invalidPrivateKey:
            String(localized: "The private key cannot be read, or the passphrase is wrong.", bundle: .module)
        case .disconnected: String(localized: "The connection dropped. Try again.", bundle: .module)
        }
    }

    static func message(_ error: SSHInstallError) -> String {
        switch error {
        case .ssh(let error): message(error)
        case .unsupportedArchitecture(let machine):
            String(localized: "pulse-agent has no build for \(machine).", bundle: .module)
        case .sudoRefused:
            String(localized: "sudo refused the password. The user needs sudo rights.", bundle: .module)
        case .keyNeedsPasswordlessSudo:
            String(localized: "A key login needs passwordless sudo. Log in with the password instead.", bundle: .module)
        case .commandFailed(let message): String(localized: "Install failed: \(message)", bundle: .module)
        case .invalidPairOutput:
            String(localized: "pulse-agent pair printed something unexpected. Update the agent.", bundle: .module)
        case .saveFailed:
            String(localized: "The server paired, but the app could not save it. Try again.", bundle: .module)
        case .agent(let error): String(describing: error)
        }
    }
}

#Preview {
    if let container = try? PulseStore.makeContainer(inMemory: true) {
        NavigationStack {
            SSHInstallView(
                model: SSHInstallModel(
                    connector: DemoSSHServer.connector(), pairing: FakeAgentPairing(), secrets: InMemorySecretStore(),
                    context: container.mainContext, deviceName: "iPhone"),
                onPaired: { _ in }
            )
        }
    }
}
