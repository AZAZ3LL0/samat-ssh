import Foundation

/// The only place that turns API units into text: bytes, bytes per second, `0..1` ratios,
/// seconds and dates. An unknown value (`nil`, negative or not finite) renders as `placeholder`.
public enum DSFormat {
    public static let placeholder = "—"

    /// Memory and disk sizes in binary units, as `free` and `df -h` show them.
    public static func bytes(_ value: Int64?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value, value >= 0 else { return placeholder }
        return value.formatted(.byteCount(style: .memory, spellsOutZero: false).locale(locale))
    }

    /// Throughput in decimal units per second, as network speeds are quoted.
    public static func bps(_ value: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return placeholder }
        let style = ByteCountFormatStyle(style: .decimal, spellsOutZero: false, locale: locale)
        let amount = Int64(value.rounded()).formatted(style)
        // The resource carries the locale, so the unit follows it rather than the device language.
        let resource = LocalizedStringResource(
            "\(amount)/s",
            locale: locale,
            bundle: .atURL(Bundle.module.bundleURL),
            comment: "Bytes per second"
        )
        return String(localized: resource)
    }

    /// A `0..1` ratio as a whole percent, halves rounded up. Percentages exist only here, never in the API or features.
    public static func ratio(_ value: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value, value.isFinite, value >= 0 else { return placeholder }
        return value.formatted(
            .percent.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero).locale(locale)
        )
    }

    /// Uptime-style duration with the two largest units: "3d 4h", "5m 12s".
    public static func duration(seconds: Int?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let seconds, seconds >= 0 else { return placeholder }
        let style = Duration.UnitsFormatStyle(
            allowedUnits: [.days, .hours, .minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 2
        )
        return Duration.seconds(seconds).formatted(style.locale(locale))
    }

    /// How long ago `date` was, for "updated 5 min ago" labels.
    public static func relative(_ date: Date?, now: Date = .now, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date else { return placeholder }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        // Clock skew between the phone and the agent must not render as "in 2 sec".
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
