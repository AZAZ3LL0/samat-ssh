import AgentKit
import SwiftUI

/// A tab of the server screen. A feature adds one element to `ServerTabRegistry.all`
/// and never touches the screen layout.
struct ServerTab: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let systemImage: String
    /// Hidden when the agent does not report this feature.
    let requiredFeature: AgentFeature?
    /// Hidden when the agent speaks an older core version.
    let requiredApiVersion: Int
    let makeView: @MainActor (ServerContext) -> AnyView
}

@MainActor enum ServerTabRegistry {
    /// Overview, Projects and Logs are placeholders until their slices (S0.6, S2.2, S3.1)
    /// replace `makeView`; Info shows `AgentInfo` until S5.1.
    static let all: [ServerTab] = [
        ServerTab(
            id: "overview",
            title: "Overview",
            systemImage: "gauge.with.dots.needle.33percent",
            requiredFeature: .hostMetrics,
            requiredApiVersion: 1,
            makeView: { _ in AnyView(UpcomingTab(systemImage: "gauge.with.dots.needle.33percent")) }
        ),
        ServerTab(
            id: "projects",
            title: "Projects",
            systemImage: "shippingbox",
            requiredFeature: .projects,
            requiredApiVersion: 1,
            makeView: { _ in AnyView(UpcomingTab(systemImage: "shippingbox")) }
        ),
        ServerTab(
            id: "logs",
            title: "Logs",
            systemImage: "text.alignleft",
            requiredFeature: .journald,
            requiredApiVersion: 1,
            makeView: { _ in AnyView(UpcomingTab(systemImage: "text.alignleft")) }
        ),
        ServerTab(
            id: "info",
            title: "Info",
            systemImage: "info.circle",
            requiredFeature: nil,
            requiredApiVersion: 1,
            makeView: { context in AnyView(AgentInfoTab(context: context)) }
        ),
    ]

    /// Tabs the agent can serve, in registry order.
    static func visible(_ tabs: [ServerTab] = all, for info: AgentInfo) -> [ServerTab] {
        tabs.filter { tab in
            let hasFeature = tab.requiredFeature.map(info.features.contains) ?? true
            return hasFeature && info.apiVersion >= tab.requiredApiVersion
        }
    }
}
