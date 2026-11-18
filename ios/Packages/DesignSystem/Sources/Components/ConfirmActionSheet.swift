import LocalAuthentication
import SwiftUI

/// Proves the device owner is present before a destructive action.
public protocol OwnerAuthenticator: Sendable {
    /// Returns normally on success; throws `LAError` or any other error on failure.
    func authenticate(reason: String) async throws
}

/// Face ID, Touch ID or the device passcode through `LAContext`.
public struct DeviceOwnerAuthenticator: OwnerAuthenticator {
    public init() {}

    public func authenticate(reason: String) async throws {
        // `.deviceOwnerAuthentication` falls back to the passcode, so a failed Face ID does not lock the user out.
        let context = LAContext()
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

/// The decision logic of `ConfirmActionSheet`: the action runs only after the owner is confirmed.
@Observable @MainActor final class ConfirmActionModel {
    enum Phase: Equatable {
        case idle, authenticating, running, done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private let reason: String
    private let requiresBiometrics: Bool
    private let authenticator: any OwnerAuthenticator
    private let onConfirm: @MainActor () async -> Void

    init(
        reason: String,
        requiresBiometrics: Bool,
        authenticator: any OwnerAuthenticator,
        onConfirm: @escaping @MainActor () async -> Void
    ) {
        self.reason = reason
        self.requiresBiometrics = requiresBiometrics
        self.authenticator = authenticator
        self.onConfirm = onConfirm
    }

    var isBusy: Bool { phase == .authenticating || phase == .running }

    func confirm() async {
        guard !isBusy, phase != .done else { return }
        if requiresBiometrics {
            phase = .authenticating
            do {
                try await authenticator.authenticate(reason: reason)
            } catch {
                phase = Self.failure(for: error)
                return
            }
        }
        phase = .running
        await onConfirm()
        phase = .done
    }

    private static func failure(for error: any Error) -> Phase {
        switch (error as? LAError)?.code {
        case .userCancel, .appCancel, .systemCancel:
            .idle
        case .passcodeNotSet:
            .failed(String(localized: "Set a device passcode to confirm this action.", bundle: .module))
        default:
            .failed(String(localized: "Authentication failed. The action did not run.", bundle: .module))
        }
    }
}

/// Confirmation for start, stop, restart and reboot. Present it in a `.sheet`; with
/// `requiresBiometrics` the action runs only after Face ID or the device passcode.
public struct ConfirmActionSheet: View {
    let title: String
    let message: String
    let destructive: Bool
    @State private var model: ConfirmActionModel
    @Environment(\.dismiss) private var dismiss

    public init(
        title: String,
        message: String,
        destructive: Bool,
        requiresBiometrics: Bool,
        authenticator: any OwnerAuthenticator = DeviceOwnerAuthenticator(),
        onConfirm: @escaping @MainActor () async -> Void
    ) {
        self.title = title
        self.message = message
        self.destructive = destructive
        _model = State(
            initialValue: ConfirmActionModel(
                reason: title,
                requiresBiometrics: requiresBiometrics,
                authenticator: authenticator,
                onConfirm: onConfirm
            )
        )
    }

    public var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if case .failed(let text) = model.phase {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.critical)
                    .multilineTextAlignment(.center)
            }
            Button(role: destructive ? .destructive : nil) {
                Task {
                    await model.confirm()
                    if model.phase == .done { dismiss() }
                }
            } label: {
                Group {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text(title)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(destructive ? DS.Palette.critical : DS.Palette.accent)
            .controlSize(.large)
            .disabled(model.isBusy)
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) { dismiss() }
                .disabled(model.isBusy)
        }
        .padding(DS.Spacing.xl)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(model.isBusy)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ConfirmActionSheet(
            title: "Restart web",
            message: "The compose project web restarts. Requests fail for a few seconds.",
            destructive: true,
            requiresBiometrics: false,
            onConfirm: { try? await Task.sleep(for: .seconds(1)) }
        )
    }
}
