import AgentKit
import SwiftUI

/// The pieces of the overview's `ServerTab`. `ServerTab` lives in the app, which
/// packages cannot see, so `ServerTabRegistry` assembles the tab from these.
public enum OverviewTab {
    public static let id = "overview"
    public static let systemImage = "gauge.with.dots.needle.33percent"
    public static let requiredFeature: AgentFeature = .hostMetrics
    /// Core version that introduced `GET /v1/metrics/host` and `metrics.host`.
    public static let requiredApiVersion = 1

    @MainActor public static func makeView(_ context: ServerContext) -> some View {
        OverviewView(context: context)
    }
}
