import Foundation

/// Explicit session preference, not inferred from process names or command lines.
/// Focus mode never changes macOS power settings or network configuration.
public struct WorkflowPowerGuard: Equatable, Sendable {
    public private(set) var focusEnabled = false
    public private(set) var systemSleeping = false
    public private(set) var displaySleeping = false
    public private(set) var generation: UInt64 = 0

    public init() {}
    public var allowsOptionalProbes: Bool { !focusEnabled && !systemSleeping }
    public var allowsSampling: Bool { !systemSleeping }

    public mutating func setFocus(_ enabled: Bool) {
        guard focusEnabled != enabled else { return }
        focusEnabled = enabled
        generation &+= 1
    }
    @discardableResult
    public mutating func systemSleep() -> Bool {
        guard !systemSleeping else { return false }
        systemSleeping = true
        generation &+= 1
        return true
    }
    @discardableResult
    public mutating func systemWake() -> Bool {
        guard systemSleeping else { return false }
        systemSleeping = false
        generation &+= 1
        return true
    }
    public mutating func setDisplaySleeping(_ sleeping: Bool) {
        displaySleeping = sleeping
    }

    public var statusText: String {
        if systemSleeping { return "系統休眠；流量採樣暫停" }
        if focusEnabled { return "重要工作模式 · 保留流量監控與用量提醒，暫停額外探測" }
        if displaySleeping { return "螢幕休眠；本機監控持續" }
        return "一般監控模式"
    }
}
