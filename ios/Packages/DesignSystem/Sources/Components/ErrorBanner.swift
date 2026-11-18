import AgentKit
import SwiftUI

/// A failed request in user terms. The text comes from the app's localization per `AgentError`;
/// the agent's own `message` is for logs and never shown.
public struct ErrorBanner: View {
    let error: AgentError
    let retry: (() -> Void)?

    public init(error: AgentError, retry: (() -> Void)? = nil) {
        self.error = error
        self.retry = retry
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.critical)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(Self.message(for: error))
                    .font(.subheadline)
                if case .server(_, let requestId) = error {
                    // Lets the user match the failure with the agent's log.
                    Text("Request ID: \(requestId)", bundle: .module)
                        .font(DS.Typography.metricLabel)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if let retry {
                Button(String(localized: "Retry", bundle: .module), action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(DS.Spacing.m)
        .background(DS.Palette.critical.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.m))
        .accessibilityElement(children: .combine)
    }

    public nonisolated static func message(for error: AgentError) -> String {
        switch error {
        case .unreachable:
            String(localized: "The server is unreachable.", bundle: .module)
        case .timeout:
            String(localized: "The server did not respond in time.", bundle: .module)
        case .unauthorized, .server(.unauthorized, _):
            String(localized: "This device lost access. Pair the server again.", bundle: .module)
        case .pinMismatch:
            String(localized: "The server certificate changed. Pair the server again.", bundle: .module)
        case .incompatibleAgent(let agent, let required):
            String(
                localized: "Update the agent: it speaks API version \(agent), the app needs \(required).",
                bundle: .module
            )
        case .incompatibleClient(let min):
            String(localized: "Update the app: the agent needs API version \(min) or newer.", bundle: .module)
        case .decoding:
            String(localized: "The agent sent an unexpected response.", bundle: .module)
        case .server(let code, _):
            message(for: code)
        }
    }

    // One case per ErrorCode; the exhaustive switch makes a new code fail to build until it has text.
    // swiftlint:disable:next cyclomatic_complexity
    private nonisolated static func message(for code: ErrorCode) -> String {
        switch code {
        case .invalidRequest:
            String(localized: "The agent rejected the request.", bundle: .module)
        case .unauthorized:
            String(localized: "This device lost access. Pair the server again.", bundle: .module)
        case .forbidden:
            String(localized: "This device is not allowed to do that.", bundle: .module)
        case .notFound:
            String(localized: "The server no longer has this item.", bundle: .module)
        case .conflict:
            String(localized: "The request conflicts with the current state of the server.", bundle: .module)
        case .idempotencyConflict:
            String(localized: "This request was already sent with different data.", bundle: .module)
        case .actionNotAllowed:
            String(localized: "The agent config does not allow this action.", bundle: .module)
        case .unsupported:
            String(localized: "This server does not support it.", bundle: .module)
        case .upstreamUnavailable:
            String(localized: "Docker, systemd or journald is unavailable on the server.", bundle: .module)
        case .rateLimited:
            String(localized: "Too many attempts. Try again in a few minutes.", bundle: .module)
        case ._internal:
            String(localized: "The agent failed to handle the request.", bundle: .module)
        }
    }
}

#Preview {
    VStack(spacing: DS.Spacing.m) {
        ErrorBanner(error: .unreachable, retry: {})
        ErrorBanner(error: .server(.upstreamUnavailable, requestId: "req-42"), retry: {})
        ErrorBanner(error: .pinMismatch, retry: nil)
    }
    .padding()
}
