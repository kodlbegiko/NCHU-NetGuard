import Foundation

/// Default-route evidence is not a reachability or per-flow routing guarantee.
public enum DefaultRouteParser {
    public static func interfaceName(_ output: String) -> String? {
        guard output.utf8.count <= 65_536 else { return nil }
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface:") else { return nil }
            return String(trimmed.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
        }
        guard values.count == 1, let name = values.first, (1...32).contains(name.utf8.count),
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { return nil }
        return name
    }
}

/// Separate observed route families. Never selects a billing interface or
/// combines counters. Missing evidence is not evidence of an absent route.
public struct DualStackEvidence: Equatable, Sendable {
    public let ipv4Interface: String?
    public let ipv6Interface: String?
    public let observedAt: TimeInterval

    public init(ipv4Interface: String?, ipv6Interface: String?, observedAt: TimeInterval) {
        self.ipv4Interface = ipv4Interface
        self.ipv6Interface = ipv6Interface
        self.observedAt = observedAt
    }

    public func isFresh(at uptime: TimeInterval) -> Bool {
        observedAt.isFinite && observedAt >= 0 && uptime.isFinite &&
            uptime >= observedAt && uptime - observedAt <= 60
    }

    public func description(at uptime: TimeInterval) -> String {
        guard isFresh(at: uptime) else { return "IPv4／IPv6 預設路由尚未量測或已過期" }
        let v4 = ipv4Interface ?? "未確認"
        let v6 = ipv6Interface ?? "未確認"
        let split = ipv4Interface != nil && ipv6Interface != nil && ipv4Interface != ipv6Interface
        return "IPv4：\(v4) · IPv6：\(v6)" + (split ? "；觀測到不同介面" : "")
    }

    public func tunnelDescription(at uptime: TimeInterval, candidates: [String]) -> String {
        guard isFresh(at: uptime) else {
            return TunnelEvidence.description(defaultInterface: "", candidates: candidates)
        }
        if ipv4Interface.map(TunnelEvidence.isTunnelCandidate) == true ||
            ipv6Interface.map(TunnelEvidence.isTunnelCandidate) == true {
            return "至少一個協定的預設路由指向疑似隧道；VPN 歸屬及涵蓋範圍未確認"
        }
        return TunnelEvidence.description(defaultInterface: "", candidates: candidates)
    }
}

/// Address-family presence only, without retaining or displaying addresses.
/// Link-local IPv6 is intentionally not evidence of external IPv6 connectivity.
public struct InterfaceAddressEvidence: Equatable, Sendable {
    public var hasIPv4 = false
    public var hasIPv6 = false
    public var hasNonLinkLocalIPv6 = false

    public init() {}
    public mutating func observeIPv4() { hasIPv4 = true }
    public mutating func observeIPv6(linkLocal: Bool) {
        hasIPv6 = true
        if !linkLocal { hasNonLinkLocalIPv6 = true }
    }

    public var description: String {
        let v4 = hasIPv4 ? "IPv4 位址已觀測" : "IPv4 未確認"
        let v6 = hasNonLinkLocalIPv6 ? "非 link-local IPv6 位址已觀測" :
            (hasIPv6 ? "僅觀測到 link-local IPv6" : "IPv6 未確認")
        return v4 + " · " + v6
    }
}
