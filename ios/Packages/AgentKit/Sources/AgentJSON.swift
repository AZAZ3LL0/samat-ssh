import Foundation

/// JSON coding for everything AgentKit decodes outside the generated client:
/// WebSocket envelopes and fixtures. Times are RFC 3339 with milliseconds.
enum AgentJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = (try? fractional.parse(text)) ?? (try? whole.parse(text)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an RFC 3339 time: \(text)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractional))
        }
        return encoder
    }()

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// Re-decodes a value through JSON, e.g. an untyped envelope payload into its schema type.
    static func convert<T: Decodable>(_ value: some Encodable, to type: T.Type) throws -> T {
        try decoder.decode(type, from: encoder.encode(value))
    }
}
