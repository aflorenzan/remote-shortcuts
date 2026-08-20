import Foundation

/// Errors that map cleanly onto HTTP status codes.
///
/// Messages are written for the human wiring up the automation. They never
/// include stack traces, file paths outside the sandbox, or secrets.
public enum APIError: Error, CustomStringConvertible {
    case badRequest(String)
    case unauthorized(String)
    case forbidden(String)
    case notFound(String)
    case methodNotAllowed(String)
    case payloadTooLarge(String)
    case tooManyRequests(String, retryAfterSeconds: Int)
    case unprocessable(String)
    case timeout(String)
    case permissionDenied(service: String, detail: String)
    case upstreamFailure(String)
    case internalError(String)

    public var status: HTTPStatus {
        switch self {
        case .badRequest: return .badRequest
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .notFound: return .notFound
        case .methodNotAllowed: return .methodNotAllowed
        case .payloadTooLarge: return .payloadTooLarge
        case .tooManyRequests: return .tooManyRequests
        case .unprocessable: return .unprocessableEntity
        case .timeout: return .gatewayTimeout
        case .permissionDenied: return .forbidden
        case .upstreamFailure: return .badGateway
        case .internalError: return .internalServerError
        }
    }

    public var code: String {
        switch self {
        case .badRequest: return "bad_request"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .notFound: return "not_found"
        case .methodNotAllowed: return "method_not_allowed"
        case .payloadTooLarge: return "payload_too_large"
        case .tooManyRequests: return "too_many_requests"
        case .unprocessable: return "unprocessable_entity"
        case .timeout: return "timeout"
        case .permissionDenied: return "permission_denied"
        case .upstreamFailure: return "upstream_failure"
        case .internalError: return "internal_error"
        }
    }

    public var message: String {
        switch self {
        case let .badRequest(m), let .unauthorized(m), let .forbidden(m), let .notFound(m),
             let .methodNotAllowed(m), let .payloadTooLarge(m),
             let .unprocessable(m), let .timeout(m), let .upstreamFailure(m), let .internalError(m):
            return m
        case let .tooManyRequests(m, _):
            return m
        case let .permissionDenied(service, detail):
            return "macOS has not granted access to \(service). \(detail)"
        }
    }

    public var description: String { "\(code): \(message)" }

    /// Response headers this error implies. A 429 without `Retry-After` leaves
    /// the client guessing, and every HTTP library knows how to read it.
    public var headers: [String: String] {
        switch self {
        case let .tooManyRequests(_, retryAfter):
            return ["Retry-After": String(max(1, retryAfter))]
        default:
            return [:]
        }
    }

    /// Extra hint surfaced in the JSON error payload — usually the exact
    /// System Settings pane the user needs to open.
    public var hint: String? {
        switch self {
        case let .permissionDenied(service, _):
            // Every route named here grants the *service*.
            //
            // macOS attributes a privacy grant to the responsible process, so a
            // prompt raised directly by a CLI in a terminal grants the terminal
            // app and does nothing for the LaunchAgent. `preflight` is listed
            // because it no longer prompts itself — it asks the service to.
            return "Grant it to the service, not to your terminal: POST /v1/system/permissions/request while watching for the prompt (this is what 'remote-shortcuts preflight' does), or open System Settings → Privacy & Security → \(service) and enable 'Remote Shortcuts'. Then: remote-shortcuts doctor"
        default:
            return nil
        }
    }
}
