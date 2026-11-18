import AgentAPI
import Foundation
import OpenAPIRuntime

public typealias AgentInfo = Components.Schemas.AgentInfo
public typealias AgentFeature = Components.Schemas.AgentFeature
public typealias HostMetrics = Components.Schemas.HostMetrics
public typealias ErrorCode = Components.Schemas.ErrorCode

/// Every failure at the AgentKit boundary. Features show text from their own
/// localization per case; `ErrorCode.message` from the agent is never shown.
public enum AgentError: Error, Sendable, Equatable {
    case unreachable, timeout, unauthorized, pinMismatch
    case incompatibleAgent(agent: Int, required: Int)
    case incompatibleClient(min: Int)
    case server(ErrorCode, requestId: String)
    case decoding

    /// Errors that a retry cannot fix: the user has to pair again.
    var isFatal: Bool {
        self == .unauthorized || self == .pinMismatch
    }

    /// Maps an `Error` response of the agent.
    init(status: Int, body: Components.Schemas._Error?) {
        if status == 401 {
            self = .unauthorized
        } else if let body {
            self = .server(body.code, requestId: body.requestId)
        } else {
            self = .decoding
        }
    }

    /// Maps a transport or decoding failure. `pinRejected` tells a TLS failure
    /// caused by the pin apart from an ordinary cancellation.
    init(_ error: any Error, pinRejected: Bool) {
        if let error = error as? AgentError {
            self = error
            return
        }
        if pinRejected {
            self = .pinMismatch
            return
        }
        switch error {
        case let error as ClientError:
            self.init(error.underlyingError, pinRejected: false)
        case is DecodingError:
            self = .decoding
        case let error as URLError where error.code == .timedOut:
            self = .timeout
        default:
            self = .unreachable
        }
    }
}

/// Version gate between the app and an agent, `tech.md` 6.1.
public enum AgentCompatibility {
    /// Core version the app is built against; equals `info.version` of `api/openapi.yaml`.
    public static let clientApiVersion = 2

    /// - Parameter requiredApiVersion: the newest core version a feature of the app needs.
    public static func check(
        _ info: AgentInfo,
        requiredApiVersion: Int = clientApiVersion
    ) throws(AgentError) {
        if info.minClientApiVersion > clientApiVersion {
            throw .incompatibleClient(min: info.minClientApiVersion)
        }
        if info.apiVersion < requiredApiVersion {
            throw .incompatibleAgent(agent: info.apiVersion, required: requiredApiVersion)
        }
    }
}
