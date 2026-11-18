import AgentKit
import DesignSystem
import SwiftUI

/// Stands in for a feature tab until its slice lands.
struct UpcomingTab: View {
    let systemImage: String

    var body: some View {
        EmptyState(
            title: String(localized: "Coming soon"),
            message: String(localized: "This tab arrives in a later update."),
            systemImage: systemImage
        )
    }
}

/// What the agent reported about itself; replaced by the system info screen in S5.1.
struct AgentInfoTab: View {
    let context: ServerContext

    var body: some View {
        if let info = context.info {
            List {
                LabeledContent("Hostname", value: info.hostname)
                LabeledContent("Agent version", value: info.agentVersion)
                LabeledContent("API version", value: String(info.apiVersion))
                Section("Features") {
                    ForEach(info.features, id: \.self) { feature in
                        Text(verbatim: feature.rawValue)
                            .font(DS.Typography.log)
                    }
                }
            }
        } else {
            ProgressView()
        }
    }
}
