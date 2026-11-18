import SwiftUI

/// Look of a project status. Cases mirror the `status` enum of `Project` in the contract;
/// features map the generated value to this style.
public enum ProjectStatusStyle: String, Sendable, CaseIterable {
    case running, stopped, degraded, restarting, unknown

    public var title: String {
        switch self {
        case .running: String(localized: "Running", bundle: .module)
        case .stopped: String(localized: "Stopped", bundle: .module)
        case .degraded: String(localized: "Degraded", bundle: .module)
        case .restarting: String(localized: "Restarting", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }

    public var color: Color {
        switch self {
        case .running: DS.Palette.ok
        case .degraded, .restarting: DS.Palette.warning
        case .stopped: DS.Palette.critical
        case .unknown: DS.Palette.inactive
        }
    }

    var systemImage: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .restarting: "arrow.clockwise.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

public struct StatusBadge: View {
    let status: ProjectStatusStyle

    public init(status: ProjectStatusStyle) {
        self.status = status
    }

    public var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(DS.Typography.metricLabel.weight(.medium))
            .foregroundStyle(status.color)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .background(status.color.opacity(0.15), in: Capsule())
    }
}

#Preview {
    VStack(alignment: .leading, spacing: DS.Spacing.s) {
        ForEach(ProjectStatusStyle.allCases, id: \.self) { StatusBadge(status: $0) }
    }
    .padding()
}
