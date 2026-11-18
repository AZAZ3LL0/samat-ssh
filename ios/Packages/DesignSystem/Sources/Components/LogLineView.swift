import SwiftUI

/// Syslog severity of a log line. Cases mirror the `level` enum of `LogEntry` in the contract.
public enum LogLevelStyle: String, Sendable, CaseIterable {
    case emerg, alert, crit, err, warning, notice, info, debug

    /// Syslog keywords, the same in every language.
    var label: String {
        switch self {
        case .warning: "WARN"
        default: rawValue.uppercased()
        }
    }

    var color: Color {
        switch self {
        case .emerg, .alert, .crit, .err: DS.Palette.critical
        case .warning: DS.Palette.warning
        case .notice, .info: .secondary
        case .debug: DS.Palette.inactive
        }
    }
}

/// One log line: time, level, stream and message, with `highlight` marked case-insensitively.
public struct LogLineView: View {
    let timestamp: Date
    let level: LogLevelStyle?
    let stream: String?
    let message: String
    let highlight: String?

    public init(ts timestamp: Date, level: LogLevelStyle?, stream: String?, message: String, highlight: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.stream = stream
        self.message = message
        self.highlight = highlight
    }

    public var body: some View {
        (prefix + Text(Self.highlighted(message, matching: highlight)))
            .font(DS.Typography.log)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prefix: Text {
        var text = Text(timestamp, format: Self.timeFormat).foregroundStyle(.secondary) + Text(" ")
        if let level {
            text = text + Text(level.label).foregroundStyle(level.color).bold() + Text(" ")
        }
        // stdout is the normal case; only stderr deserves a mark.
        if let stream, stream != "stdout" {
            text = text + Text(stream).foregroundStyle(DS.Palette.warning) + Text(" ")
        }
        return text
    }

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .standard)
        .hour(.twoDigits(amPM: .omitted))

    /// Marks every case-insensitive occurrence of `query` in `message`.
    nonisolated static func highlighted(_ message: String, matching query: String?) -> AttributedString {
        var result = AttributedString(message)
        guard let query, !query.isEmpty else { return result }
        var searchStart = result.startIndex
        while let range = result[searchStart...].range(of: query, options: .caseInsensitive) {
            result[range].backgroundColor = DS.Palette.warning.opacity(0.35)
            result[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return result
    }
}

#Preview {
    let now = Date.now
    VStack(spacing: DS.Spacing.xs) {
        LogLineView(ts: now, level: .info, stream: "stdout", message: "GET /health 200 1ms", highlight: nil)
        LogLineView(ts: now, level: .warning, stream: nil, message: "Slow query: 1.2s", highlight: "slow")
        LogLineView(ts: now, level: .err, stream: "stderr", message: "connection refused", highlight: "refused")
        LogLineView(ts: now, level: nil, stream: nil, message: "plain line without metadata", highlight: nil)
    }
    .padding()
}
