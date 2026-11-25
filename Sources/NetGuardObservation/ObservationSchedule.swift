import Foundation

/// Scheduling of optional probes only. Never changes the accounting cadence.
public struct ObservationSchedule: Sendable {
    private var lastRoute: TimeInterval?
    private var lastPing: TimeInterval?
    private var lastApps: TimeInterval?
    private var routeDirty = true
    public init() {}
    public mutating func networkChanged() { routeDirty = true }
    public mutating func reset() { self = Self() }
    private func due(_ last: TimeInterval?, now: TimeInterval, interval: Double) -> Bool {
        guard now.isFinite, now >= 0 else { return false }
        guard let last else { return true }
        return now < last || now - last >= interval
    }
    public mutating func takeRoute(now: TimeInterval, visible: Bool) -> Bool {
        let interval = routeDirty ? 2.0 : (visible ? 10.0 : 30.0)
        guard due(lastRoute, now: now, interval: interval) else { return false }
        lastRoute = now
        routeDirty = false
        return true
    }
    public mutating func takePing(now: TimeInterval, visible: Bool, busy: Bool,
                                  allowed: Bool) -> Bool {
        guard allowed, visible, due(lastPing, now: now, interval: busy ? 15 : 45) else { return false }
        lastPing = now
        return true
    }
    public mutating func takeApps(now: TimeInterval, visible: Bool, busy: Bool,
                                  allowed: Bool, backgroundEnabled: Bool = false) -> Bool {
        let interval: TimeInterval = visible ? (busy ? 10 : 25) : (busy ? 20 : 35)
        guard allowed, visible || backgroundEnabled, due(lastApps, now: now, interval: interval) else { return false }
        lastApps = now
        return true
    }
}

/// An interface name is evidence of a possible tunnel, not proof of a VPN
/// provider, encryption, routing coverage, or an active commercial VPN.
public enum TunnelEvidence {
    public static func isTunnelCandidate(_ name: String) -> Bool {
        ["utun", "tun", "tap", "ppp", "ipsec"].contains { prefix in
            guard name.hasPrefix(prefix) else { return false }
            let suffix = name.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
    public static func description(defaultInterface: String, candidates: [String]) -> String {
        if isTunnelCandidate(defaultInterface) {
            return "預設路由指向疑似隧道介面；VPN 歸屬未確認"
        }
        if candidates.contains(where: isTunnelCandidate) {
            return "觀測到疑似隧道介面；不代表 VPN 正在承載流量"
        }
        return "未觀測到隧道跡象；不能排除 VPN"
    }
}
