#if DEBUG
    import DesignSystem
    import Persistence
    import SwiftData
    import SwiftUI

    /// Developer tools, compiled into Debug and Demo builds only.
    struct DebugMenu: View {
        @Environment(\.modelContext) private var modelContext
        @Query private var settings: [AppSettings]
        @State private var showsShowcase = false

        var body: some View {
            Menu {
                Button("Design system", systemImage: "paintpalette") { showsShowcase = true }
                Toggle("Demo mode", systemImage: "sparkles", isOn: demoMode)
            } label: {
                Label("Debug", systemImage: "ladybug")
            }
            .sheet(isPresented: $showsShowcase) {
                NavigationStack {
                    DesignSystemShowcase()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsShowcase = false }
                            }
                        }
                }
            }
        }

        private var demoMode: Binding<Bool> {
            Binding {
                settings.first?.demoModeEnabled ?? false
            } set: { enabled in
                try? AppSettings.current(in: modelContext).demoModeEnabled = enabled
            }
        }
    }
#endif
