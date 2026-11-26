import Foundation

public enum DefaultRouteParseStatus: String, Equatable, Sendable {
    case parsed, noDefaultRoute, emptyOutput, missingInterface, ambiguousInterface, invalidInterface, outputLimit, invalidRouteFlags
}
public struct DefaultRouteParseResult: Equatable, Sendable {
    public let status: DefaultRouteParseStatus
    public let interfaceName: String?
}
public enum DefaultRouteParser {
    public static func inspect(_ output: String) -> DefaultRouteParseResult {
        func failure(_ status: DefaultRouteParseStatus) -> DefaultRouteParseResult {
            .init(status: status, interfaceName: nil)
        }
        guard output.utf8.count <= 65_536 else { return failure(.outputLimit) }
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return failure(.emptyOutput) }
        // Only an exact diagnostic from the bounded, C-locale default-route
        // query establishes absence. Empty output alone remains unknown.
        if ["not in table", "route: not in table",
            "route: writing to routing socket: not in table"].contains(trimmedOutput) {
            return failure(.noDefaultRoute)
        }
        // Do not accept a contradictory route plus a no-route diagnostic.
        if trimmedOutput.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasSuffix("not in table")
        }) { return failure(.missingInterface) }
        var values: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("flags:") {
                let flags = trimmed.dropFirst("flags:".count)
                    .split(whereSeparator: { $0 == "<" || $0 == ">" || $0 == "," || $0.isWhitespace })
                if flags.contains("REJECT") || flags.contains("BLACKHOLE") { return failure(.invalidRouteFlags) }
            }
            guard let separator = trimmed.firstIndex(of: ":"),
                  trimmed[..<separator].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            values.append(String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
        }
        guard !values.isEmpty else { return failure(.missingInterface) }
        guard values.count == 1 else { return failure(.ambiguousInterface) }
        guard let name = values.first, (1...32).contains(name.utf8.count),
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { return failure(.invalidInterface) }
        return .init(status: .parsed, interfaceName: name)
    }
    public static func interfaceName(_ output: String) -> String? { inspect(output).interfaceName }
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


/// A route-table candidate, not proof of where a packet went or its billing scope.
public enum ObservedRouteKind: String, CaseIterable, Sendable {
    case directLinkCandidate, gatewayCandidate, unknown
}

public struct RoutePathEvidence: Equatable, Sendable {
    public let interfaceName: String
    public let kind: ObservedRouteKind
    // Ephemeral next hop only; do not encode, log or display it.
    fileprivate let nextHop: String?
}

public enum RoutePathParser {
    public static func inspect(_ output: String) -> RoutePathEvidence? {
        guard let name = DefaultRouteParser.interfaceName(output),
              name != "lo0", !TunnelEvidence.isTunnelCandidate(name) else { return nil }
        var flagRows: [Set<String>] = []
        var gateways: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("flags:") {
                flagRows.append(Set(value.dropFirst(6).split(whereSeparator: {
                    $0 == "<" || $0 == ">" || $0 == "," || $0.isWhitespace
                }).map(String.init)))
            } else if value.hasPrefix("gateway:") {
                gateways.append(String(value.dropFirst(8)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard flagRows.count == 1, let flags = flagRows.first, flags.contains("UP"),
              flags.isDisjoint(with: ["REJECT", "BLACKHOLE", "LOCAL", "LLINFO", "MULTICAST", "BROADCAST"]),
              gateways.count <= 1 else { return nil }
        let hop = gateways.first
        if flags.contains("GATEWAY") {
            guard let hop, !hop.isEmpty, hop.utf8.count <= 128 else { return nil }
            return .init(interfaceName: name, kind: .gatewayCandidate, nextHop: hop)
        }
        return .init(interfaceName: name, kind: .directLinkCandidate, nextHop: hop)
    }

    public static func classify(before: RoutePathEvidence?, after: RoutePathEvidence?,
                                flowInterface: String, tunnelOverlap: Bool) -> ObservedRouteKind {
        guard !tunnelOverlap, let before, let after, before == after,
              before.interfaceName == flowInterface else { return .unknown }
        return before.kind
    }
}
