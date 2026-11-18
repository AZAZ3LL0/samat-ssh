import AgentKit
import SwiftUI
import Testing

@testable import Pulse

@MainActor @Suite struct ServerTabRegistryTests {
    private func agent(apiVersion: Int = 2, features: [AgentFeature]) -> AgentInfo {
        AgentInfo(
            agentVersion: "0.1.0", apiVersion: apiVersion, minClientApiVersion: 1, hostname: "h", features: features)
    }

    private func tab(_ id: String, feature: AgentFeature? = nil, apiVersion: Int = 1) -> ServerTab {
        ServerTab(
            id: id,
            title: "Tab",
            systemImage: "circle",
            requiredFeature: feature,
            requiredApiVersion: apiVersion,
            makeView: { _ in AnyView(EmptyView()) }
        )
    }

    @Test func registryListsOverviewProjectsLogsAndInfo() {
        #expect(ServerTabRegistry.all.map(\.id) == ["overview", "projects", "logs", "info"])
    }

    @Test func registryIdsAreUnique() {
        let ids = ServerTabRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func hidesTabsWhoseFeatureTheAgentLacks() {
        let tabs = [tab("a", feature: .hostMetrics), tab("b", feature: .projects), tab("c")]
        let visible = ServerTabRegistry.visible(tabs, for: agent(features: [.hostMetrics]))
        #expect(visible.map(\.id) == ["a", "c"])
    }

    @Test func hidesTabsNeedingNewerAgent() {
        let tabs = [tab("old", apiVersion: 1), tab("current", apiVersion: 2), tab("future", apiVersion: 3)]
        let visible = ServerTabRegistry.visible(tabs, for: agent(apiVersion: 2, features: []))
        #expect(visible.map(\.id) == ["old", "current"])
    }

    @Test func keepsRegistryOrder() {
        let all = AgentFeature.allCases
        #expect(ServerTabRegistry.visible(for: agent(features: all)).map(\.id) == ServerTabRegistry.all.map(\.id))
    }

    @Test func demoAgentShowsOverviewAndInfo() {
        let demo = agent(features: [.hostMetrics])
        #expect(ServerTabRegistry.visible(for: demo).map(\.id) == ["overview", "info"])
    }
}
