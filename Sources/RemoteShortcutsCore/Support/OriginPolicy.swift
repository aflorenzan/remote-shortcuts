import Foundation

/// Decides whether a source address may talk to this server.
///
/// Split out of the request path so it can be tested directly. It is worth
/// testing: the rule below reads as a detail, and getting it wrong locked a
/// Mac out of its own service — which, once `preflight` began working through
/// the service, meant the install could not grant any macOS permission at all.
public enum OriginPolicy {
    public enum Decision: Equatable {
        case allowed
        /// `reason` is for the log, `message` for the client.
        case refused(reason: String, message: String)
    }

    public static func decide(address: String, configuration: Configuration) -> Decision {
        if configuration.loopbackOnly {
            return CIDR.isLoopback(address)
                ? .allowed
                : .refused(
                    reason: "Rejected non-loopback request",
                    message: "This server only accepts connections from localhost."
                )
        }

        guard !configuration.allowedOrigins.isEmpty else { return .allowed }
        if CIDR.isLoopback(address) { return .allowed }

        // The machine the server runs on is never locked out of it.
        //
        // A connection whose source address is the address the server bound to
        // came from this same host — a remote peer's packets carry the remote
        // peer's address. Without this, the ordinary configuration (bind to the
        // LAN address, allow only n8n's) makes `doctor` and `preflight` 403,
        // and those are the only route to granting the service its permissions.
        // Forging this means completing a TCP handshake from a spoofed address,
        // and still needing the token.
        if address == configuration.host { return .allowed }

        if configuration.allowedOrigins.contains(where: { $0.contains(address) }) {
            return .allowed
        }
        return .refused(
            reason: "Rejected request, not in allowed_origins",
            message: "Source address \(address) is not in 'allowed_origins'."
        )
    }
}
