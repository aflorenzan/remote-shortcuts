import Foundation

/// A tiny IPv4/IPv6 CIDR matcher used for the source-address allow-list.
///
/// Written by hand rather than pulled from a package: the whole point of this
/// project is that no third-party code sits in the request path.
public struct CIDR: Equatable, CustomStringConvertible {
    private let network: [UInt8]
    private let prefixLength: Int
    public let description: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addressPart = String(parts[0])

        guard let bytes = CIDR.parseAddress(addressPart) else { return nil }

        let maxPrefix = bytes.count * 8
        var prefix = maxPrefix
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), parsed >= 0, parsed <= maxPrefix else { return nil }
            prefix = parsed
        }

        self.network = CIDR.mask(bytes, prefixLength: prefix)
        self.prefixLength = prefix
        self.description = parts.count == 2 ? trimmed : addressPart
    }

    public func contains(_ address: String) -> Bool {
        guard let bytes = CIDR.parseAddress(address), bytes.count == network.count else { return false }
        return CIDR.mask(bytes, prefixLength: prefixLength) == network
    }

    // MARK: - Parsing

    /// Returns 4 bytes for IPv4, 16 for IPv6. Handles zone IDs (`fe80::1%en0`)
    /// and IPv4-mapped IPv6 (`::ffff:192.168.1.4`), which is what
    /// Network.framework hands us on a dual-stack listener.
    static func parseAddress(_ raw: String) -> [UInt8]? {
        var address = raw
        if let percent = address.firstIndex(of: "%") {
            address = String(address[address.startIndex..<percent])
        }
        if address.hasPrefix("[") && address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        if address.lowercased().hasPrefix("::ffff:"), address.contains(".") {
            address = String(address.dropFirst("::ffff:".count))
        }

        if address.contains(":") {
            var storage = in6_addr()
            guard inet_pton(AF_INET6, address, &storage) == 1 else { return nil }
            return withUnsafeBytes(of: &storage) { Array($0) }
        }

        var storage = in_addr()
        guard inet_pton(AF_INET, address, &storage) == 1 else { return nil }
        return withUnsafeBytes(of: &storage) { Array($0) }
    }

    static func mask(_ bytes: [UInt8], prefixLength: Int) -> [UInt8] {
        var out = bytes
        for index in 0..<out.count {
            let bitsConsumed = index * 8
            if bitsConsumed >= prefixLength {
                out[index] = 0
            } else if prefixLength - bitsConsumed < 8 {
                let keep = prefixLength - bitsConsumed
                out[index] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
        }
        return out
    }

    public static func isLoopback(_ address: String) -> Bool {
        guard let bytes = parseAddress(address) else { return false }
        if bytes.count == 4 { return bytes[0] == 127 }
        // ::1
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
}
