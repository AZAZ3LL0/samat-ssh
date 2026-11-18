import SwiftUI

/// A screen or section with nothing to show yet, with an optional way forward.
public struct EmptyState: View {
    let title: String
    let message: String?
    let systemImage: String
    let action: (title: String, run: () -> Void)?

    public init(
        title: String,
        message: String? = nil,
        systemImage: String,
        action: (title: String, run: () -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview("With action") {
    EmptyState(
        title: "No servers",
        message: "Add a server to see its load.",
        systemImage: "server.rack",
        action: (title: "Add server", run: {})
    )
}

#Preview("Plain") {
    EmptyState(title: "No logs", message: nil, systemImage: "doc.text.magnifyingglass")
}
