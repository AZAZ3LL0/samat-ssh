import SwiftUI

// Token names follow tech.md §10 verbatim (`DS`, `Spacing.xs`, `Palette.ok`); short names are the point.
// swiftlint:disable identifier_name type_name

/// Design tokens. Features take spacing, colors, fonts and thresholds from here, never literals.
public enum DS {
    public enum Spacing {
        public static let xs = 4.0
        public static let s = 8.0
        public static let m = 12.0
        public static let l = 16.0
        public static let xl = 24.0
    }

    public enum Radius {
        public static let s = 6.0
        public static let m = 10.0
        public static let l = 16.0
    }

    /// Colors from `Colors.xcassets`, each with a light and a dark variant.
    public enum Palette {
        public static let ok = color("ok")
        public static let warning = color("warning")
        public static let critical = color("critical")
        public static let inactive = color("inactive")
        public static let accent = color("accent")
        public static let chartCPU = color("chartCPU")
        public static let chartMemory = color("chartMemory")
        public static let chartDisk = color("chartDisk")
        public static let chartNetRx = color("chartNetRx")
        public static let chartNetTx = color("chartNetTx")

        private static func color(_ name: String) -> Color {
            Color(name, bundle: .module)
        }
    }

    public enum Typography {
        public static let metricValue: Font = .system(.title2, design: .rounded).monospacedDigit()
        public static let metricLabel: Font = .caption
        public static let log: Font = .system(.footnote, design: .monospaced)
    }

    /// Limits for a `0..1` ratio: at or above `warning` a value turns orange, at or above `critical` red.
    public enum Thresholds {
        public static let warning = 0.75
        public static let critical = 0.90

        public static func severity(of ratio: Double?) -> Severity {
            guard let ratio, ratio.isFinite else { return .unknown }
            if ratio >= critical { return .critical }
            if ratio >= warning { return .warning }
            return .ok
        }
    }

    public enum Severity: Sendable, CaseIterable {
        case ok, warning, critical, unknown

        public var color: Color {
            switch self {
            case .ok: Palette.ok
            case .warning: Palette.warning
            case .critical: Palette.critical
            case .unknown: Palette.inactive
            }
        }
    }
}

// swiftlint:enable identifier_name type_name
