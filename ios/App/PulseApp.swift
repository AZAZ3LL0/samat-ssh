import DesignSystem
import SwiftUI
import os

@main struct PulseApp: App {
    private let environment: AppEnvironment?

    init() {
        do {
            environment = try AppEnvironment.live()
        } catch {
            // A broken store must not crash the app on every launch; say so instead.
            Logger(subsystem: "dev.azaz3ll0.pulse", category: "app")
                .error("cannot open the app store: \(error.localizedDescription, privacy: .public)")
            environment = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let environment {
                ServerListView()
                    .environment(environment)
                    .modelContainer(environment.container)
            } else {
                EmptyState(
                    title: String(localized: "Pulse cannot start"),
                    message: String(localized: "The local cache is damaged. Reinstall the app to reset it."),
                    systemImage: "externaldrive.badge.exclamationmark"
                )
            }
        }
    }
}
