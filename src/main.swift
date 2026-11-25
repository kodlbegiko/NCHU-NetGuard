import Cocoa
import Foundation
import WebKit
import SwiftUI
import IOKit
import SystemConfiguration

// MARK: - 歷史紀錄模型與管理器
struct DayTrafficRecord {
    var total: Double
    var dl: Double?
    var ul: Double?
}

// Main-thread manager; cached history avoids a database query per UI tick.
class TrafficHistoryManager {
    static let shared = TrafficHistoryManager()
    private var store: HistoryStore?
    private var cache: [String: DayTrafficRecord] = [:]
    private var initialized = false
    private(set) var healthy = true

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let directory = home.appendingPathComponent("Library/Application Support/NCHU-NetGuard", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let database = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
            let legacy = home.appendingPathComponent(".nchu_traffic_history.json")
            // Keep legacy source intact. Import cannot overwrite newer SQLite rows.
            if FileManager.default.fileExists(atPath: legacy.path) {
                do { try database.importLegacy(Data(contentsOf: legacy)) }
                catch { healthy = false }
            }
            store = database
            try refreshCache()
        } catch {
            healthy = false
        }
    }

    private func refreshCache() throws {
        guard let store else { throw HistoryStoreError.database("unavailable") }
        cache = Dictionary(uniqueKeysWithValues: try store.recent(limit: 366).map {
            ($0.day, DayTrafficRecord(total: Double($0.total), dl: $0.download.map(Double.init),
                                      ul: $0.upload.map(Double.init)))
        })
    }

    func loadHistory() -> [String: DayTrafficRecord] {
        initialize()
        return cache
    }

    func analyticsRecords() throws -> [HistoryDay] {
        initialize()
        guard let store else { throw HistoryStoreError.database("unavailable") }
        return try store.recent(limit: 366)
    }

    @discardableResult
    func recordDay(date: String, dl: Double, ul: Double) -> Bool {
        initialize()
        guard let store else { healthy = false; return false }
        guard dl.isFinite, ul.isFinite, dl >= 0, ul >= 0,
              dl.rounded(.towardZero) == dl, ul.rounded(.towardZero) == ul,
              dl + ul <= 9_007_199_254_740_991 else { healthy = false; return false }
        do {
            try store.upsert(HistoryDay(day: date, total: UInt64(dl + ul),
                                       download: UInt64(dl), upload: UInt64(ul)))
            try refreshCache()
            return true
        } catch {
            healthy = false
            return false
        }
    }
}

// MARK: - HTTPS 憑證處理器 (支援校園內網伺服器安全存取)
// Use URLSession's default certificate and hostname validation.

    // MARK: - JavaScript 訊息處理器
class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var app: RealtimeTrafficApp?
    init(app: RealtimeTrafficApp) { self.app = app }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.isFileURL == true,
              message.frameInfo.request.url?.standardizedFileURL == Bundle.main.url(forResource: "popover", withExtension: "html")?.standardizedFileURL,
              let action = message.body as? String else { return }
        DispatchQueue.main.async { [weak self] in
            switch action {
            case "toggleFocusMode":
                self?.app?.toggleFocusMode()
            case "refresh":
                self?.app?.manualRefresh()
            case "openTop100":
                self?.app?.openTop100()
            case "openIPMS":
                self?.app?.openIPMS()
            case "showMenu":
                self?.app?.showContextMenu()
            case "toggleLidGuard":
                self?.app?.handleToggleLidGuard()
            case "toggleIdleGuard":
                self?.app?.handleToggleIdleGuard()
            case "toggleWifiFailover":
                self?.app?.handleToggleWifiFailover()
            case "switchToWifi":
                self?.app?.handleManualSwitchToWifi()
            case "restoreWired":
                self?.app?.handleRestoreWired()
            case "panicFreeze":
                self?.app?.handlePanicFreeze()
            case "toggleSplitRouting":
                self?.app?.handleToggleSplitRouting()
            case "toggleMidnightSchedule":
                self?.app?.handleToggleMidnightSchedule()
            case "toggleP2PShield":
                self?.app?.handleToggleP2PShield()
            case "killP2PApp":
                self?.app?.handleKillP2PApp()
            case "checkBlocklistNow":
                self?.app?.handleCheckBlocklistNow()
            case "openIpBlock":
                self?.app?.openIpBlock()
            case "toggleSpeedAutoSwitch":
                self?.app?.handleToggleSpeedAutoSwitch()
            case "runSpeedRaceNow":
                self?.app?.handleRunSpeedRaceNow()
            default:
                break
            }
        }
    }
}

// MARK: - 主應用程式
class RealtimeTrafficApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var nativePanelEnabled = false
    let quickPanelModel = QuickPanelModel()
    var historyWindowController: NSWindowController?
    var settingsWindowController: NSWindowController?
    var managementWindowController: NSWindowController?
    let managementModel = ManagementModel()
    let settingsModel = NetGuardSettingsModel()
    var activeSpeedMeasured = false
    
    var secondTimer: Timer?
    var serverSyncTimer: Timer?
    var pingTimer: Timer?
    var appInspectTimer: Timer?
    
    // 跨日追蹤狀態（獨立分開統計：1.有線宿網、2.興大校園Wi-Fi、3.外部網路/熱點，三者互不干擾污染）
    var currentDateString: String = ""
    var dormTodayInBytes: Double = 0.0
    var dormTodayOutBytes: Double = 0.0
    var wifiTodayInBytes: Double = 0.0
    var wifiTodayOutBytes: Double = 0.0
    var extTodayInBytes: Double = 0.0
    var extTodayOutBytes: Double = 0.0
    
    // 向後相容屬性
    var todayInBytes: Double {
        get { return isCampusWifi ? wifiTodayInBytes : dormTodayInBytes }
        set { if isCampusWifi { wifiTodayInBytes = newValue } else { dormTodayInBytes = newValue } }
    }
    var todayOutBytes: Double {
        get { return isCampusWifi ? wifiTodayOutBytes : dormTodayOutBytes }
        set { if isCampusWifi { wifiTodayOutBytes = newValue } else { dormTodayOutBytes = newValue } }
    }
    
    // 網路環境模式 (0: 自動偵測, 1: 強制興大有線宿網, 2: 強制興大校園Wi-Fi, 3: 強制外部網路/自由模式)
    var networkModeOverride: Int = 0
    
    // 是否為興大校園無線網路 (NCHU Wi-Fi: 每日下載上限 10GB / 上傳 5GB / 總額 15GB，超量限速不斷網)
    var isCampusWifi: Bool {
        if networkModeOverride == 2 { return true }
        if networkModeOverride != 0 { return false }
        return sampledScopes[activeInterface] == .campusWifi
    }
    
    // 是否為興大二村有線宿網 (每日下載上限 7GB / 上傳 4GB / 總額 11GB，超量斷網鎖卡)
    var isDormNetwork: Bool {
        if networkModeOverride == 1 { return true }
        if networkModeOverride != 0 { return false }
        return sampledScopes[activeInterface] == .dorm
    }
    
    // 是否屬於受興大流量配額管控之網路 (有線宿網或校園Wi-Fi)
    var isQuotaRestricted: Bool {
        return isDormNetwork || isCampusWifi
    }
    
    // 動態配額計算 (根據當前連線網路自動套用官方上限)
    var totalQuotaBytes: Double {
        if isCampusWifi {
            return 15.0 * 1024 * 1024 * 1024 // 興大校園 Wi-Fi 總額 15 GB
        } else {
            return 11.0 * 1024 * 1024 * 1024 // 興大有線宿網 總額 11 GB
        }
    }
    
    var dlQuotaBytes: Double {
        if isCampusWifi {
            return 10.0 * 1024 * 1024 * 1024 // 興大校園 Wi-Fi 下載 10 GB
        } else {
            return 7.0 * 1024 * 1024 * 1024 // 興大有線宿網 下載 7 GB
        }
    }
    
    var ulQuotaBytes: Double {
        if isCampusWifi {
            return 5.0 * 1024 * 1024 * 1024 // 興大校園 Wi-Fi 上傳 5 GB
        } else {
            return 4.0 * 1024 * 1024 * 1024 // 興大有線宿網 上傳 4 GB
        }
    }
    
    var networkTypeName: String {
        if isCampusWifi {
            return "興大校園 Wi-Fi (NCHU)"
        } else if isDormNetwork {
            return "興大二村 宿網 (有線)"
        } else if currentIP.hasPrefix("172.20.10.") {
            return "iPhone 個人熱點"
        } else {
            return sampledScopes[activeInterface] == .external ? "外部網路（估計）" : "網路歸屬未確認"
        }
    }
    
    // 警報等級追蹤
    var alertTierSent: Int = 0
    var isAlertEnabled: Bool = true
    
    // 實時狀態與網速計算
    var activeInterface: String = ""
    var currentIP: String = ""
    var isConnected: Bool = false
    var pingLatencyMs: Double = -1
    var networkQuality = NetworkQualityWindow()
    var lastPingUptime: TimeInterval?
    var appProbeInFlight = false
    var appProbeTimestamp: TimeInterval?
    var consecutivePingFailures: Int = 0
    
    var lastRawIBytes: UInt64 = 0
    var lastRawOBytes: UInt64 = 0
    var lastTimestamp: TimeInterval = 0
    
    var scopedAccumulator = ScopedCounterAccumulator()
    var lastSampleUptime: TimeInterval?
    var sampledScopes: [String: NetworkScope] = [:]
    var unattributedInBytes: Double = 0
    var unattributedOutBytes: Double = 0
    var sampleGapCount: Int = 0
    var workflowPowerGuard = WorkflowPowerGuard()
    var predictionEngine = PredictionEngine()
    var predictionScope: NetworkScope = .unknown
    var predictionIdentity = Set<String>()
    var quotaAlertLedger = QuotaAlertLedger()
    var currentDownSpeed: Double = 0
    var currentUpSpeed: Double = 0
    
    var topAppConsumers: [(name: String, bytes: Double)] = []
    var providerObservation: ProviderObservation?
    var providerRequestID = UUID()
    var providerLastAttempt: Date?
    var providerRequestInFlight = false
    var providerStatusText: String {
        guard isDormNetwork, isConnected else { return "校方榜單不適用或網路未確認" }
        guard let observation = providerObservation else { return "校方資料尚未確認" }
        return observation.displayStatus(for: getTodayString(), now: Date())
    }
    var displayMode: Int = 0
    
    // 盒蓋與離座防偷跑流量守護 (Lid & Idle Traffic Guard)
    var isLidGuardEnabled: Bool = true
    var isIdleGuardEnabled: Bool = true
    var isLidCurrentlyClosed: Bool = false
    var isUserCurrentlyIdle: Bool = false
    var isEmergencyBrakeActive: Bool = false
    var pausedPIDs: [pid_t] = []
    
    // 宿網避難與自動切換 Wi-Fi 守護 (Auto Wi-Fi Failover Guard)
    var isAutoWifiFailoverEnabled: Bool = false
    var isWiredTemporarilyDisabled: Bool = false
    var disabledWiredServiceName: String = "USB 10/100/1000 LAN"
    var isSwitchingNetwork: Bool = false
    var failoverCooldownUntil: TimeInterval = 0
    
    // 方向 1: 智慧網路調度與雙軌分流 (Smart Dual-Interface Routing & Split Tunneling)
    var isSplitRoutingEnabled: Bool = false
    var isMidnightScheduleEnabled: Bool = false
    var hasTriggeredMidnightToday: Bool = false
    
    // 雙網卡即時競速與慢速自動切換引擎 (Smart Speed Race & Auto-Switch Engine)
    var isSpeedAutoSwitchEnabled: Bool = false
    var wiredPingMs: Double = 4.0
    var wifiPingMs: Double = 46.3
    var wiredSpeedMbps: Double = 0
    var wifiSpeedMbps: Double = 0
    var wiredReachable: Bool = true
    var wifiReachable: Bool = true
    var isRunningSpeedRace: Bool = false
    var slowNetworkStreak: Int = 0
    var lastSpeedSwitchTime: TimeInterval = 0
    var speedGuardTimer: Timer?
    
    // 方向 2: 違規風險防禦與計中黑名單主動預警 (NCHU Security & Blacklist Early Warning)
    var isP2PShieldAutoKillEnabled: Bool = false
    var isP2PDetected: Bool = false
    var p2pAppName: String = ""
    var hasAlertedCurrentP2P: Bool = false
    
    var isBlacklisted: Bool = false
    var blacklistReason: String = ""
    var lastBlacklistCheckTime: String = "未檢測"
    var hasAlertedBlacklist: Bool = false
    var blacklistCheckTimer: Timer?
    
    let stateFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".nchu_traffic_state.json").path
    }()

    func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        if let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            return prop
        }
        return false
    }

    // 發送 macOS 系統底層「播放/暫停」多媒體鍵 (Key Code 16)，直接硬體級暫停 YouTube / Chrome / Spotify / Safari，完全無需瀏覽器 JS 權限
    func sendSystemMediaPause() {
        func postKey(down: Bool) {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = Int((16 << 16) | ((down ? 0xa : 0xb) << 8))
            if let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent {
                ev.post(tap: .cghidEventTap)
            }
        }
        postKey(down: true)
        postKey(down: false)
    }

    // 檢查系統當前是否正有任何音訊核心持鎖（例如 YouTube 播放、音樂串流阻止休眠）
    func isAudioPlaying() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let out = String(data: data, encoding: .utf8) {
            return out.contains("coreaudiod") && (out.contains("preventuseridlesleep") || out.contains("preventuseridledisplaysleep"))
        }
        return false
    }

    // 取得使用者距離上次敲擊鍵盤或移動滑鼠/觸控板的閒置秒數
    func getSystemIdleSeconds() -> Double {
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // 偵測 Codex 及其電腦操控代理 (SkyComputerUseService / cua_node / CodexBrowser) 是否正在運行
    func isCodexEcosystemActive() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "Codex|SkyComputerUseService|cua_node|cua-repl"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 判斷程序是否享有 Codex 及開發/操控生態系豁免權 (絕不凍結、絕不中斷)
    func isExemptProcessForCodex(cmdOut: String) -> Bool {
        let lower = cmdOut.lowercased()
        let exemptKeywords = [
            "leadops", "ai.leadops",
            "codex", "skycomputeruseservice", "cua_node", "cua-repl", "chatgpt",
            "antigravity", "cursor", "visual studio code", "code helper",
            "node", "python", "git", "gh", "ssh", "docker", "orbstack",
            "playwright", "puppeteer", "chromedriver", "webdriver", "remote-debugging"
        ]
        for kw in exemptKeywords {
            if lower.contains(kw) {
                return true
            }
        }
        return false
    }

    // 設定 Codex 與受控開發工具的「有線宿網 VIP 豁免靜態路由」
    func applyCodexWiredExemptionRoutes(wiredService: String, gateway: String) {
        // Disabled until transactional routing and authorization are implemented.
    }

    func activateLidGuard(reason: String, freezeRenderers: Bool = false) {
        sendSystemNotification(title: "流量防護提醒", body: "\(reason)：請檢查背景傳輸；安全模式不會暫停或終止程式。", isCritical: true)
    }

    func deactivateLidGuard(reason: String) {
        pausedPIDs.removeAll()
    }

    func activateIdleGuard(reason: String) {
        guard isIdleGuardEnabled && !isLidCurrentlyClosed && !workflowPowerGuard.focusEnabled else { return }
        activateLidGuard(reason: reason, freezeRenderers: false)
    }

    func deactivateIdleGuard(reason: String) {
        guard !isLidCurrentlyClosed else { return }
        deactivateLidGuard(reason: reason)
    }

    // 動態解析有線網卡對應的 macOS 網路服務名稱 (例如: "USB 10/100/1000 LAN")
    func getWiredServiceName() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listnetworkserviceorder"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let targetDev = self.activeInterface.hasPrefix("en") ? self.activeInterface : "en6"
        
        // 解析格式: (1) USB 10/100/1000 LAN \n (Hardware Port: ..., Device: en6)
        let lines = out.components(separatedBy: .newlines)
        for i in 0..<lines.count {
            if lines[i].contains("Device: \(targetDev)") || lines[i].contains("Device: en6") {
                if i > 0 {
                    let prevLine = lines[i - 1]
                    if let parenIdx = prevLine.range(of: ") ") {
                        let name = String(prevLine[parenIdx.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty && !name.contains("Wi-Fi") {
                            return name
                        }
                    }
                }
            }
        }
        return self.disabledWiredServiceName
    }

    // 取得所有網路服務名稱清單
    func getAllNetworkServices() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var services: [String] = []
        for line in out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.starts(with: "An asterisk") {
                services.append(trimmed)
            }
        }
        return services
    }

    // 免拔線自動避難切換：切換至校園 Wi-Fi，同時為 Codex 及受控開發軟體保留有線專線豁免權！
    func switchToWifi(reason: String) {
        reportNetworkMutationUnavailable()
    }

    func restoreWiredNetwork(reason: String) {
        reportNetworkMutationUnavailable()
    }

    func applySplitRouting() {
        reportNetworkMutationUnavailable()
    }

    func reportNetworkMutationUnavailable() {
        isSwitchingNetwork = false
        isSplitRoutingEnabled = false
        isAutoWifiFailoverEnabled = false
        isSpeedAutoSwitchEnabled = false
        isMidnightScheduleEnabled = false
        sendSystemNotification(title: "R4.0 安全模式", body: "網路設定修改暫停，請使用 macOS 系統設定手動管理連線。", isCritical: true)
        if popover != nil && popover.isShown { pushDataToWebUI() }
    }

    func getServiceGatewayIP(service: String, fallback: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-getinfo", service]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("router:") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    let gw = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !gw.isEmpty && gw != "none" && gw != "null" {
                        return gw
                    }
                }
            }
        }
        return fallback
    }

    // 探測單一網卡介面的即時延遲 (ms) 與有效傳輸速率 (Mbps)
    // Legacy speed-race controls are unavailable pending a verified, consented
    // interface-specific benchmark. Ordinary latency probes remain available.
    func evaluateDualNetworkSpeedAndSwitch(forceSpeedBurst: Bool = false, manualTrigger: Bool = false) {
        if manualTrigger {
            measurePingLatency()
            if popover != nil && popover.isShown { pushDataToWebUI() }
        }
    }

    func getWiredGatewayIP(service: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-getinfo", service]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.components(separatedBy: .newlines) {
            if line.hasPrefix("Router:") {
                let r = line.replacingOccurrences(of: "Router:", with: "").trimmingCharacters(in: .whitespaces)
                if !r.isEmpty && r != "none" {
                    return r
                }
            }
        }
        
        let pRoute = Process()
        pRoute.executableURL = URL(fileURLWithPath: "/sbin/route")
        pRoute.arguments = ["-n", "get", "default"]
        let rPipe = Pipe()
        pRoute.standardOutput = rPipe
        try? pRoute.run()
        pRoute.waitUntilExit()
        let rOut = String(data: rPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in rOut.components(separatedBy: .newlines) {
            if line.contains("gateway:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    let gw = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !gw.isEmpty && gw.hasPrefix("140.120.") {
                        return gw
                    }
                }
            }
        }
        return "140.120.251.126"
    }

    // MARK: - 方向 2: 違規風險防禦與計中黑名單主動預警 (NCHU Security & Blacklist)
    func checkP2PHazard() {
        let p2pKeywords = ["qbittorrent", "transmission", "bitcomet", "thunder", "xunlei", "folx", "deluge", "utorrent", "bittorrent", "webtorrent", "aria2c", "motrix", "biglybt"]
        var foundP2PName: String? = nil
        
        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            for kw in p2pKeywords {
                if name.contains(kw) || bid.contains(kw) {
                    foundP2PName = app.localizedName ?? kw
                    break
                }
            }
            if foundP2PName != nil { break }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let name = foundP2PName {
                self.isP2PDetected = true
                self.p2pAppName = name
                
                if self.isDormNetwork {
                    if !self.hasAlertedCurrentP2P {
                        self.hasAlertedCurrentP2P = true
                        self.sendSystemNotification(
                            title: "🚨 興大宿網違規風險警告！",
                            body: "偵測到可能具有 P2P 功能的軟體（\(name)），不代表已違規。請確認使用情形。", isCritical: true
                        )

                    }
                }
            } else {
                self.isP2PDetected = false
                self.p2pAppName = ""
                self.hasAlertedCurrentP2P = false
            }
            if self.popover.isShown {
                self.pushDataToWebUI()
            }
        }
    }

    func killCurrentP2PApp() {
        sendSystemNotification(title: "P2P 風險提醒", body: "安全模式不會終止程式；請確認應用程式與傳輸用途後自行關閉。", isCritical: true)
    }

    func checkIpBlocklist() {
        // Provider's legacy HTML has no verified IP-specific parser.
        isBlacklisted = false
        blacklistReason = ""
        lastBlacklistCheckTime = "狀態未知：請開啟計中官方頁面核對"
        if popover != nil && popover.isShown { pushDataToWebUI() }
    }

    @objc func systemWillSleep() {
        guard workflowPowerGuard.systemSleep() else { return }
        networkQuality.reset()
        lastPingUptime = nil
        appProbeTimestamp = nil
        topAppConsumers = []
        savePersistedState()
        scopedAccumulator.reset()
        predictionEngine.reset()
        lastSampleUptime = nil
        sampleGapCount += 1
        pingLatencyMs = -1
        providerObservation = nil
        providerRequestID = UUID()
        providerRequestInFlight = false
    }

    @objc func screensDidSleep() {
        workflowPowerGuard.setDisplaySleeping(true)
    }

    @objc func screensDidWake() {
        workflowPowerGuard.setDisplaySleeping(false)
    }

    @objc func toggleFocusMode() {
        workflowPowerGuard.setFocus(!workflowPowerGuard.focusEnabled)
        if workflowPowerGuard.focusEnabled {
            appProbeTimestamp = nil
            topAppConsumers = []
        }
        providerRequestID = UUID()
        providerRequestInFlight = false
        if popover != nil && popover.isShown { pushDataToWebUI() }
    }

    func getTodayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    func getRelativeDateLabel(targetDateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let targetDate = formatter.date(from: targetDateStr),
              let todayDate = formatter.date(from: currentDateString) else {
            return targetDateStr
        }
        let diff = Calendar.current.dateComponents([.day], from: targetDate, to: todayDate).day ?? 0
        switch diff {
        case 0: return "今日 (進行中)"
        case 1: return "昨日"
        case 2: return "前天"
        default: return "\(diff) 天前"
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🌐 載入中..."
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        currentDateString = getTodayString()
        detectActiveNetworkSync()
        loadPersistedState()
        initHardwareCounters()
        
        setupPopoverUI()
        syncWithTop100Server()
        measurePingLatency()
        inspectTopAppConsumers()
        checkIpBlocklist()
        checkP2PHazard()
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        secondTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickRealtime()
        }
        
        // 僅在面板打開時定期採樣 nettop，避免在背景無謂消耗 CPU 與電量
        appInspectTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.popover.isShown || self.managementWindowController?.window?.isVisible == true {
                self.inspectTopAppConsumers()
            }
        }
        
        // 延遲偵測在面板打開時更新，背景降低頻率至 60 秒
        pingTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.popover.isShown || self.managementWindowController?.window?.isVisible == true {
                self.measurePingLatency()
            }
        }
        
        serverSyncTimer = Timer.scheduledTimer(withTimeInterval: 180.0, repeats: true) { [weak self] _ in
            self?.syncWithTop100Server()
        }
        
        blacklistCheckTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.checkIpBlocklist()
        }
        
        // 每 15 秒背景自動檢測雙網卡延遲與速率，當目前網路太慢時自動切換至較快的網路
        speedGuardTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.evaluateDualNetworkSpeedAndSwitch(forceSpeedBurst: false, manualTrigger: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.evaluateDualNetworkSpeedAndSwitch(forceSpeedBurst: true, manualTrigger: false)
        }
    }

    func setupPopoverUI() {
        popover = NSPopover()
        let availableHeight = NSScreen.main?.visibleFrame.height ?? 650
        let panelHeight = max(280, min(570, availableHeight - 70))
        popover.contentSize = NSSize(width: 380, height: panelHeight)
        popover.behavior = .transient
        if nativePanelEnabled {
            webView = nil
            popover.contentViewController = NSHostingController(rootView: QuickPanel(
                model: quickPanelModel,
                refresh: { [weak self] in self?.manualRefresh() },
                toggleFocus: { [weak self] in self?.toggleFocusMode() },
                toggleAlerts: { [weak self] in self?.handleToggleAlert(); self?.pushDataToWebUI() },
                openHistory: { [weak self] in self?.openHistoryAnalytics() },
                openSettings: { [weak self] in self?.openNativeSettings() },
                openManagement: { [weak self] in self?.openNativeManagement() },
                openAdvanced: { [weak self] in self?.switchPanel(native: false) }
            ))
            return
        }
        
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(ScriptHandler(app: self), name: "nativeApp")
        config.userContentController = controller
        
        let vc = NSViewController()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: panelHeight), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        vc.view = webView
        popover.contentViewController = vc
        
        guard let htmlURL = Bundle.main.url(forResource: "popover", withExtension: "html") else {
            webView.loadHTMLString("<p>NetGuard: missing bundled interface.</p>", baseURL: nil)
            return
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    func updateQuickPanel() {
        let scope = sampledScopes[activeInterface] ?? .unknown
        let compatible = (scope == .dorm && isDormNetwork) || (scope == .campusWifi && isCampusWifi)
        let (_, dl, ul) = getEffectiveUsedBytes()
        _ = TrafficHistoryManager.shared.loadHistory()
        let diagnostic = DiagnosticsEngine.findings(DiagnosticInput(
            connected: isConnected, scope: scope,
            persistenceHealthy: !persistenceBlocked && TrafficHistoryManager.shared.healthy && !persistenceStatus.contains("失敗"),
            sampleGapCount: sampleGapCount,
            providerFresh: providerObservation?.isFresh(for: getTodayString(), now: Date()) == true && providerObservation?.status == .listed
        )).first?.summary ?? "狀態未知"
        let fresh = lastSampleUptime.map { ProcessInfo.processInfo.systemUptime - $0 <= 5 } ?? false
        let speed = activeSpeedMeasured && fresh && workflowPowerGuard.allowsSampling
            ? "↓ " + formatSpeed(currentDownSpeed) + "   ↑ " + formatSpeed(currentUpSpeed) : "未量測"
        let state = QuickPanelState(networkName: scope == .unknown ? "網路歸屬未確認" : networkTypeName,
            connectionKnown: isConnected && workflowPowerGuard.allowsSampling,
            scope: compatible ? scope : .unknown,
            received: dl, sent: ul, receiveLimit: dlQuotaBytes, sendLimit: ulQuotaBytes,
            speedText: speed, diagnostic: diagnostic, forecast: forecastPresentation().message,
            provider: providerStatusText, focusEnabled: workflowPowerGuard.focusEnabled, alertsEnabled: isAlertEnabled)
        if quickPanelModel.state != state { quickPanelModel.state = state }
    }

    func switchPanel(native: Bool, show: Bool = true) {
        guard nativePanelEnabled != native else { return }
        popover?.performClose(nil)
        nativePanelEnabled = native
        setupPopoverUI()
        pushDataToWebUI()
        syncSettingsModel()
        if show, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func openHistoryAnalytics() {
        popover?.performClose(nil)
        let manager = TrafficHistoryManager.shared
        let records: [HistoryDay]
        let healthy: Bool
        do {
            records = try manager.analyticsRecords()
            healthy = manager.healthy
        } catch {
            records = []
            healthy = false
        }
        let content = NSHostingController(rootView: HistoryAnalyticsView(
            records: records, today: getTodayString(), storageHealthy: healthy))
        let controller: NSWindowController
        if let existing = historyWindowController, let window = existing.window {
            controller = existing
            window.contentViewController = content
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "NetGuard · 歷史流量"
            window.contentViewController = content
            window.minSize = NSSize(width: 480, height: 420)
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
            historyWindowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func syncManagementModel() {
        let now = ProcessInfo.processInfo.systemUptime
        let connected = isConnected && workflowPowerGuard.allowsSampling
        let scope = sampledScopes[activeInterface] ?? .unknown
        let rows = topAppConsumers.compactMap { item -> ProcessSampleRow? in
            guard let bytes = UInt64(exactly: item.bytes) else { return nil }
            return ProcessSampleRow(name: item.name, bytes: bytes)
        }
        _ = TrafficHistoryManager.shared.loadHistory()
        let input = DiagnosticInput(connected: connected, scope: scope,
            persistenceHealthy: !persistenceBlocked && TrafficHistoryManager.shared.healthy && !persistenceStatus.contains("失敗"),
            sampleGapCount: sampleGapCount,
            providerFresh: providerObservation?.isFresh(for: getTodayString(), now: Date()) == true && providerObservation?.status == .listed)
        let snapshot = ManagementSnapshot(scopes: sampledScopes, defaultInterface: activeInterface,
            connectionKnown: connected, latencyStatus: networkQuality.state(at: now).description,
            processRows: rows, processAge: appProbeTimestamp.map { now - $0 },
            focusEnabled: workflowPowerGuard.focusEnabled, diagnosticInput: input, providerStatus: providerStatusText)
        if managementModel.snapshot != snapshot { managementModel.snapshot = snapshot }
    }

    @objc func openNativeManagement() {
        popover?.performClose(nil)
        syncManagementModel()
        let controller: NSWindowController
        if let existing = managementWindowController {
            controller = existing
        } else {
            let content = NSHostingController(rootView: ManagementView(
                model: managementModel,
                refresh: { [weak self] in self?.manualRefresh(); self?.syncManagementModel() },
                openProvider: { [weak self] in self?.openTop100() }
            ))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 510),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "NetGuard · 網路管理"
            window.contentViewController = content
            window.minSize = NSSize(width: 460, height: 400)
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
            managementWindowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        measurePingLatency()
        inspectTopAppConsumers()
    }

    func syncSettingsModel() {
        if settingsModel.alertsEnabled != isAlertEnabled { settingsModel.alertsEnabled = isAlertEnabled }
        if settingsModel.focusEnabled != workflowPowerGuard.focusEnabled { settingsModel.focusEnabled = workflowPowerGuard.focusEnabled }
        if settingsModel.nativePreview != nativePanelEnabled { settingsModel.nativePreview = nativePanelEnabled }
        if settingsModel.displayMode != displayMode { settingsModel.displayMode = displayMode }
        if settingsModel.persistenceStatus != persistenceStatus { settingsModel.persistenceStatus = persistenceStatus }
    }

    @objc func openNativeSettings() {
        popover?.performClose(nil)
        syncSettingsModel()
        if let controller = settingsWindowController {
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let content = NSHostingController(rootView: NetGuardSettingsView(
            model: settingsModel,
            setAlerts: { [weak self] enabled in
                guard let self, self.isAlertEnabled != enabled else { return }
                self.handleToggleAlert()
                self.syncSettingsModel()
                if self.popover.isShown { self.pushDataToWebUI() }
            },
            setFocus: { [weak self] enabled in
                guard let self, self.workflowPowerGuard.focusEnabled != enabled else { return }
                self.toggleFocusMode()
                self.syncSettingsModel()
            },
            setNativePreview: { [weak self] enabled in
                self?.switchPanel(native: enabled, show: false)
            },
            setDisplayMode: { [weak self] mode in
                guard let self, (0...4).contains(mode), self.displayMode != mode else { return }
                self.displayMode = mode
                self.savePersistedState()
                self.updateStatusBar()
                self.syncSettingsModel()
            }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "NetGuard · 設定"
        window.contentViewController = content
        window.minSize = NSSize(width: 460, height: 390)
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func toggleNativePanelPreview() {
        switchPanel(native: !nativePanelEnabled)
    }

    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        
        if popover.isShown {
            popover.performClose(sender)
        } else {
            pushDataToWebUI()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // 打開面板時立即採樣最新的最耗流量 App 與 Ping 延遲，零延遲呈現
            inspectTopAppConsumers()
            measurePingLatency()
        }
    }

    func pushDataToWebUI() {
        if nativePanelEnabled {
            updateQuickPanel()
            return
        }
        let (totalUsed, dlUsed, ulUsed) = getEffectiveUsedBytes()
        let remTotal = max(0, totalQuotaBytes - totalUsed)
        let remDl = max(0, dlQuotaBytes - dlUsed)
        let remUl = max(0, ulQuotaBytes - ulUsed)
        
        let remTotalGB = remTotal / (1024 * 1024 * 1024)
        let remDlGB = remDl / (1024 * 1024 * 1024)
        let remUlGB = remUl / (1024 * 1024 * 1024)
        
        let usagePct = min(max((totalUsed / totalQuotaBytes) * 100.0, 0.0), 100.0)
        let dlPct = min(max((dlUsed / dlQuotaBytes) * 100.0, 0.0), 100.0)
        let ulPct = min(max((ulUsed / ulQuotaBytes) * 100.0, 0.0), 100.0)
        
        var appsArray: [[String: String]] = []
        let appSampleFresh = appProbeTimestamp.map { ProcessInfo.processInfo.systemUptime - $0 <= 30 } ?? false
        for item in (appSampleFresh ? topAppConsumers : []).prefix(4) {
            appsArray.append(["name": item.name, "bytes": formatBytes(item.bytes)])
        }

        // 構建極致清楚的歷史對比清單 (包含今天 + 過去數日)
        var histArray: [[String: String]] = []
        let todayShortDate = String(currentDateString.suffix(5))
        
        if isDormNetwork {
            histArray.append([
                "label": "今日 (宿網有線)",
                "date": todayShortDate,
                "total": formatBytes(dormTodayInBytes + dormTodayOutBytes),
                "dl": formatBytes(dormTodayInBytes),
                "ul": formatBytes(dormTodayOutBytes),
                "pct": String(format: "%.1f%%", min((dormTodayInBytes / (7.0 * 1024 * 1024 * 1024)) * 100.0, 100.0))
            ])
            if (wifiTodayInBytes + wifiTodayOutBytes) > 0 {
                histArray.append([
                    "label": "今日 (校園 Wi-Fi)",
                    "date": todayShortDate,
                    "total": formatBytes(wifiTodayInBytes + wifiTodayOutBytes),
                    "dl": formatBytes(wifiTodayInBytes),
                    "ul": formatBytes(wifiTodayOutBytes),
                    "pct": String(format: "%.1f%%", min((wifiTodayInBytes / (10.0 * 1024 * 1024 * 1024)) * 100.0, 100.0))
                ])
            }
        } else if isCampusWifi {
            histArray.append([
                "label": "今日 (校園 Wi-Fi)",
                "date": todayShortDate,
                "total": formatBytes(wifiTodayInBytes + wifiTodayOutBytes),
                "dl": formatBytes(wifiTodayInBytes),
                "ul": formatBytes(wifiTodayOutBytes),
                "pct": String(format: "%.1f%%", min((wifiTodayInBytes / (10.0 * 1024 * 1024 * 1024)) * 100.0, 100.0))
            ])
            if (dormTodayInBytes + dormTodayOutBytes) > 0 {
                histArray.append([
                    "label": "今日 (宿網有線)",
                    "date": todayShortDate,
                    "total": formatBytes(dormTodayInBytes + dormTodayOutBytes),
                    "dl": formatBytes(dormTodayInBytes),
                    "ul": formatBytes(dormTodayOutBytes),
                    "pct": String(format: "%.1f%%", min((dormTodayInBytes / (7.0 * 1024 * 1024 * 1024)) * 100.0, 100.0))
                ])
            }
        } else {
            let extTotal = extTodayInBytes + extTodayOutBytes
            histArray.append([
                "label": "今日 (非宿網/熱點)",
                "date": todayShortDate,
                "total": formatBytes(extTotal),
                "dl": formatBytes(extTodayInBytes),
                "ul": formatBytes(extTodayOutBytes),
                "pct": "自由"
            ])
            if (dormTodayInBytes + dormTodayOutBytes) > 0 {
                histArray.append([
                    "label": "今日 (宿網有線)",
                    "date": todayShortDate,
                    "total": formatBytes(dormTodayInBytes + dormTodayOutBytes),
                    "dl": formatBytes(dormTodayInBytes),
                    "ul": formatBytes(dormTodayOutBytes),
                    "pct": String(format: "%.1f%%", min((dormTodayInBytes / (7.0 * 1024 * 1024 * 1024)) * 100.0, 100.0))
                ])
            }
        }
        
        // 2. 過去歷史紀錄 (按日期降序)
        let history = TrafficHistoryManager.shared.loadHistory()
        for d in history.keys.filter({ $0 != self.currentDateString }).sorted().suffix(5).reversed() {
            if let rec = history[d] {
                let shortDate = String(d.suffix(5))
                let relLabel = getRelativeDateLabel(targetDateStr: d)
                let pct = min(max((rec.total / totalQuotaBytes) * 100.0, 0.0), 100.0)
                histArray.append([
                    "label": relLabel,
                    "date": shortDate,
                    "total": formatBytes(rec.total),
                    "dl": rec.dl.map { formatBytes($0) } ?? "未知",
                    "ul": rec.ul.map { formatBytes($0) } ?? "未知",
                    "pct": String(format: "%.1f%%", pct)
                ])
            }
        }
        
        // 3. 構建近 7 日趨勢柱狀圖與統計分析資料 (由 6 天前到今天)
        var chartDays: [[String: Any]] = []
        let cal = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]
        let todayDate = dateFormatter.date(from: currentDateString) ?? Date()
        var total7DayBytes: Double = 0
        var yesterdayTotalBytes: Double = 0
        var todayCombinedBytes: Double = 0
        var maxBytesVal: Double = 0
        var maxBytesDateLabel: String = ""
        
        for i in (0...6).reversed() {
            guard let d = cal.date(byAdding: .day, value: -i, to: todayDate) else { continue }
            let dateStr = dateFormatter.string(from: d)
            let shortDate = String(dateStr.suffix(5))
            let weekdayIndex = cal.component(.weekday, from: d) - 1
            let weekdayStr = (weekdayIndex >= 0 && weekdayIndex < 7) ? weekdaySymbols[weekdayIndex] : ""
            
            let isToday = (i == 0)
            let dayLabel: String
            if isToday {
                dayLabel = "今天"
            } else if i == 1 {
                dayLabel = "昨天"
            } else {
                dayLabel = "\(weekdayStr)"
            }
            
            let dayTotal: Double
            let dayDl: Double?
            let dayUl: Double?
            
            if isToday {
                let rx = dormTodayInBytes + wifiTodayInBytes + extTodayInBytes + unattributedInBytes
                let tx = dormTodayOutBytes + wifiTodayOutBytes + extTodayOutBytes + unattributedOutBytes
                dayDl = rx
                dayUl = tx
                dayTotal = rx + tx
                todayCombinedBytes = dayTotal
            } else {
                if let rec = history[dateStr] {
                    dayTotal = rec.total
                    dayDl = rec.dl
                    dayUl = rec.ul
                } else {
                    dayTotal = 0
                    dayDl = nil
                    dayUl = nil
                }
                if i == 1 {
                    yesterdayTotalBytes = dayTotal
                }
            }
            
            total7DayBytes += dayTotal
            if dayTotal > maxBytesVal {
                maxBytesVal = dayTotal
                maxBytesDateLabel = isToday ? "今天" : (i == 1 ? "昨天" : shortDate)
            }
            
            let pctOfQuota = (totalQuotaBytes > 0) ? (dayTotal / totalQuotaBytes) * 100.0 : 0.0
            let statusLevel: String
            if pctOfQuota >= 85.0 {
                statusLevel = "danger"
            } else if pctOfQuota >= 60.0 {
                statusLevel = "warning"
            } else {
                statusLevel = "safe"
            }
            
            chartDays.append([
                "date": dateStr,
                "shortDate": shortDate,
                "dayLabel": dayLabel,
                "weekday": weekdayStr,
                "totalBytes": dayTotal,
                "totalGB": String(format: "%.2f", dayTotal / (1024 * 1024 * 1024)),
                "dlStr": dayDl.map { formatBytes($0) } ?? "未知",
                "ulStr": dayUl.map { formatBytes($0) } ?? "未知",
                "totalStr": (isToday || history[dateStr] != nil) ? formatBytes(dayTotal) : "無紀錄",
                "pctOfQuota": String(format: "%.1f", min(pctOfQuota, 140.0)),
                "statusLevel": statusLevel,
                "isToday": isToday
            ])
        }
        
        let recordedDays = chartDays.filter { ($0["totalStr"] as? String) != "無紀錄" }.count
        let avg7DayGB = (total7DayBytes / Double(max(1, recordedDays))) / (1024 * 1024 * 1024)
        var diffVsYesterdayPct = 0.0
        var diffTrend = "flat"
        if yesterdayTotalBytes > 0 {
            diffVsYesterdayPct = ((todayCombinedBytes - yesterdayTotalBytes) / yesterdayTotalBytes) * 100.0
            if diffVsYesterdayPct > 5.0 {
                diffTrend = "up"
            } else if diffVsYesterdayPct < -5.0 {
                diffTrend = "down"
            }
        }
        
        let diffSign = diffVsYesterdayPct >= 0 ? "+" : ""
        let chartData: [String: Any] = [
            "days": chartDays,
            "avg7DayStr": String(format: "%.1f GB（有紀錄日）", avg7DayGB),
            "diffVsYesterdayStr": yesterdayTotalBytes > 0 ? String(format: "%@%.0f%%", diffSign, diffVsYesterdayPct) : "無法比較",
            "diffTrend": diffTrend,
            "maxWeekStr": String(format: "%.1f GB (%@)", maxBytesVal / (1024 * 1024 * 1024), maxBytesDateLabel),
            "quotaGBStr": String(format: "%.0f GB", totalQuotaBytes / (1024 * 1024 * 1024))
        ]
        
        let pingFresh = lastPingUptime.map { ProcessInfo.processInfo.systemUptime - $0 <= 120 } ?? false
        let pingStr = isConnected && pingFresh && pingLatencyMs >= 0 ? String(format: "%.1f ms", pingLatencyMs) : "未量測"
        let speedStr = String(format: "↓ %@   ↑ %@", formatSpeed(currentDownSpeed), formatSpeed(currentUpSpeed))
        let extTotal = extTodayInBytes + extTodayOutBytes
        
        let forecast = forecastPresentation()
        let runoutText = forecast.message
        let riskLevel = forecast.level

        let payload: [String: Any] = [
            "isDorm": isDormNetwork,
            "isCampusWifi": isCampusWifi,
            "isQuotaRestricted": isQuotaRestricted,
            "networkTypeName": networkTypeName,
            "providerStatus": providerStatusText,
            "focusEnabled": workflowPowerGuard.focusEnabled,
            "workflowStatus": workflowPowerGuard.statusText,
            "networkQualityStatus": networkQuality.state(at: ProcessInfo.processInfo.systemUptime).description,
            "appSampleStatus": workflowPowerGuard.focusEnabled ? "重要工作模式：暫停採樣" : (appSampleFresh ? "程序累計快照，非今日用量" : "尚未取得近期採樣"),
            "observationStatus": !isConnected ? "網路未確認，請檢查連線" : (isQuotaRestricted ? "監控中 · 配額為本機估計" : "監控中 · 網路配額未確認"),
            "currentIP": currentIP,
            "activeInterface": activeInterface,
            "unattributedTotalStr": formatBytes(unattributedInBytes + unattributedOutBytes),
            "sampleGapCount": sampleGapCount,
            "persistenceStatus": persistenceStatus,
            "diagnosticSummary": DiagnosticsEngine.findings(DiagnosticInput(
                connected: isConnected, scope: sampledScopes[activeInterface] ?? .unknown,
                persistenceHealthy: !persistenceBlocked && TrafficHistoryManager.shared.healthy && !persistenceStatus.contains("失敗"),
                sampleGapCount: sampleGapCount,
                providerFresh: providerObservation?.isFresh(for: getTodayString(), now: Date()) == true && providerObservation?.status == .listed
            )).first?.summary ?? "狀態未知",
            "observedInterfaces": sampledScopes.keys.sorted().joined(separator: ", "),
            "date": currentDateString,
            "quotaTotalGB": String(format: "%.0f", totalQuotaBytes / (1024 * 1024 * 1024)),
            "quotaDlGB": String(format: "%.0f", dlQuotaBytes / (1024 * 1024 * 1024)),
            "quotaUlGB": String(format: "%.0f", ulQuotaBytes / (1024 * 1024 * 1024)),
            "remTotalStr": String(format: "%.2f", remTotalGB),
            "usagePctStr": String(format: "%.1f%%", usagePct),
            "usedTotalStr": formatBytes(totalUsed),
            "speedStr": speedStr,
            "remDlStr": String(format: "%.2f", remDlGB),
            "dlPctStr": String(format: "%.1f%%", dlPct),
            "usedDlStr": formatBytes(dlUsed),
            "remUlStr": String(format: "%.2f", remUlGB),
            "ulPctStr": String(format: "%.1f%%", ulPct),
            "usedUlStr": formatBytes(ulUsed),
            "dormDlStr": formatBytes(dormTodayInBytes),
            "dormUlStr": formatBytes(dormTodayOutBytes),
            "dormTotalStr": formatBytes(dormTodayInBytes + dormTodayOutBytes),
            "wifiDlStr": formatBytes(wifiTodayInBytes),
            "wifiUlStr": formatBytes(wifiTodayOutBytes),
            "wifiTotalStr": formatBytes(wifiTodayInBytes + wifiTodayOutBytes),
            "extTotalStr": formatBytes(extTotal),
            "extDlStr": formatBytes(extTodayInBytes),
            "extUlStr": formatBytes(extTodayOutBytes),
            "isLidGuardEnabled": isLidGuardEnabled,
            "isIdleGuardEnabled": isIdleGuardEnabled,
            "isAutoWifiFailoverEnabled": isAutoWifiFailoverEnabled,
            "isWiredTemporarilyDisabled": isWiredTemporarilyDisabled,
            "isUserCurrentlyIdle": isUserCurrentlyIdle,
            "isEmergencyBrakeActive": isEmergencyBrakeActive,
            "isPanicActive": !pausedPIDs.isEmpty,
            "isSplitRoutingEnabled": isSplitRoutingEnabled,
            "isMidnightScheduleEnabled": isMidnightScheduleEnabled,
            "isSpeedAutoSwitchEnabled": isSpeedAutoSwitchEnabled,
            "isRunningSpeedRace": isRunningSpeedRace,
            "wiredReachable": wiredReachable,
            "wifiReachable": wifiReachable,
            "wiredPingMs": String(format: "%.1f", wiredPingMs),
            "wifiPingMs": String(format: "%.1f", wifiPingMs),
            "wiredSpeedMbps": String(format: "%.1f", wiredSpeedMbps),
            "wifiSpeedMbps": String(format: "%.1f", wifiSpeedMbps),
            "isP2PShieldAutoKillEnabled": isP2PShieldAutoKillEnabled,
            "isP2PDetected": isP2PDetected,
            "p2pAppName": p2pAppName,
            "isBlacklisted": isBlacklisted,
            "blacklistReason": blacklistReason,
            "lastBlacklistCheckTime": lastBlacklistCheckTime,
            "runoutText": runoutText,
            "riskLevel": riskLevel,
            "latencyStr": pingStr,
            "topApps": appsArray,
            "history": histArray,
            "chartData": chartData
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let js = "if (window.updateStats) { window.updateStats(\(jsonStr)); }"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    @objc func systemDidWake() {
        guard workflowPowerGuard.systemWake() else { return }
        isLidCurrentlyClosed = false
        isUserCurrentlyIdle = false
        isConnected = false
        currentIP = ""
        pingLatencyMs = -1
        initHardwareCounters()
        let generation = workflowPowerGuard.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.workflowPowerGuard.generation == generation,
                  self.workflowPowerGuard.allowsSampling else { return }
            self.detectActiveNetwork {
                self.syncWithTop100Server()
                self.measurePingLatency()
                self.inspectTopAppConsumers()
            }
        }
    }

    var persistenceStatus = "尚未載入"
    var persistenceBlocked = false

    func loadPersistedState() {
        let today = getTodayString()
        let url = URL(fileURLWithPath: stateFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            persistenceStatus = "新紀錄"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let usage = try UsageMigration.decode(data)
            guard usage.date <= today else { throw UsageMigrationError.invalidDate }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            // Import display preferences only, never restore unsafe automation or
            // stale hardware baselines/network identity from legacy storage.
            let mode = json["display_mode"] as? Int ?? 0
            displayMode = (0...4).contains(mode) ? mode : 0
            isAlertEnabled = json["alert_enabled"] as? Bool ?? true
            isLidGuardEnabled = json["lid_guard_enabled"] as? Bool ?? true
            isIdleGuardEnabled = json["idle_guard_enabled"] as? Bool ?? true
            if usage.date == today {
                dormTodayInBytes = Double(usage.dormIn)
                dormTodayOutBytes = Double(usage.dormOut)
                wifiTodayInBytes = Double(usage.wifiIn)
                wifiTodayOutBytes = Double(usage.wifiOut)
                extTodayInBytes = Double(usage.externalIn)
                extTodayOutBytes = Double(usage.externalOut)
                unattributedInBytes = Double(usage.unattributedIn)
                unattributedOutBytes = Double(usage.unattributedOut)
                sampleGapCount = Int(usage.sampleGapCount)
            } else {
                // Preserve the complete original file before replacing a prior day.
                let backup = url.deletingLastPathComponent().appendingPathComponent(
                    ".nchu_traffic_archive-" + usage.date + "-" + UUID().uuidString + ".json")
                try FileManager.default.copyItem(at: url, to: backup)
                let dl = Double(usage.dormIn) + Double(usage.wifiIn) +
                    Double(usage.externalIn) + Double(usage.unattributedIn)
                let ul = Double(usage.dormOut) + Double(usage.wifiOut) +
                    Double(usage.externalOut) + Double(usage.unattributedOut)
                if dl + ul > 0 {
                    TrafficHistoryManager.shared.recordDay(date: usage.date, dl: dl, ul: ul)
                }
            }
            persistenceStatus = "已驗證本機紀錄"
        } catch {
            // Keep invalid/future/unsupported data intact for manual recovery.
            persistenceBlocked = true
            persistenceStatus = "舊紀錄無法驗證，已停止寫入以保護原始檔"
        }
    }

    func savePersistedState() {
        guard !persistenceBlocked else { return }
        let dict: [String: Any] = [
            "schema_version": 1,
            "date": currentDateString,
            "dorm_in": dormTodayInBytes,
            "dorm_out": dormTodayOutBytes,
            "wifi_in": wifiTodayInBytes,
            "wifi_out": wifiTodayOutBytes,
            "ext_in": extTodayInBytes,
            "ext_out": extTodayOutBytes,
            "unattributed_in": unattributedInBytes,
            "unattributed_out": unattributedOutBytes,
            "sample_gap_count": sampleGapCount,
            "today_in": dormTodayInBytes,
            "today_out": dormTodayOutBytes,
            "network_mode_override": networkModeOverride,
            "last_raw_in": NSNumber(value: lastRawIBytes),
            "last_raw_out": NSNumber(value: lastRawOBytes),
            "display_mode": displayMode,
            "alert_enabled": isAlertEnabled,
            "lid_guard_enabled": isLidGuardEnabled,
            "idle_guard_enabled": isIdleGuardEnabled,
            "auto_wifi_failover_enabled": isAutoWifiFailoverEnabled,
            "is_wired_temporarily_disabled": isWiredTemporarilyDisabled,
            "disabled_wired_service_name": disabledWiredServiceName,
            "split_routing_enabled": isSplitRoutingEnabled,
            "is_split_routing_enabled": isSplitRoutingEnabled,
            "midnight_schedule_enabled": isMidnightScheduleEnabled,
            "speed_auto_switch_enabled": isSpeedAutoSwitchEnabled,
            "p2p_shield_auto_kill_enabled": isP2PShieldAutoKillEnabled,
            "is_dorm": isDormNetwork,
            "is_campus_wifi": isCampusWifi,
            "current_ip": currentIP,
            "active_interface": activeInterface
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            do {
                try data.write(to: URL(fileURLWithPath: stateFilePath), options: .atomic)
                persistenceStatus = "本機紀錄已儲存"
            } catch {
                persistenceStatus = "本機紀錄寫入失敗"
            }
        }
    }

    var isDetectingNetwork: Bool = false
    
    private static func discoverDefaultIPv4() -> (interface: String, ip: String) {
        guard case .success(let route) = ProbeRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 2),
              let line = route.components(separatedBy: .newlines).first(where: {
                  $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:")
              }),
              let separator = line.firstIndex(of: ":") else { return ("", "") }
        let name = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 32,
              name.range(of: #"^[a-zA-Z0-9]+$"#, options: .regularExpression) != nil,
              case .success(let address) = ProbeRunner.run("/usr/sbin/ipconfig", ["getifaddr", name], timeout: 2)
        else { return (name, "") }
        let ip = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed = in_addr()
        guard inet_pton(AF_INET, ip, &parsed) == 1 else { return (name, "") }
        return (name, ip)
    }

    private func applyDiscoveredNetwork(interface: String, ip: String) {
        if activeInterface != interface || currentIP != ip {
            networkQuality.reset()
            lastPingUptime = nil
            pingLatencyMs = -1
            providerObservation = nil
            providerRequestID = UUID()
            providerRequestInFlight = false
            providerLastAttempt = nil
        }
        activeInterface = interface
        currentIP = ip
        // A default IPv4 route and address do not prove internet reachability.
        isConnected = !interface.isEmpty && !ip.isEmpty
    }

    func detectActiveNetworkSync() {
        // Start in an unknown state; discovery is performed off the main thread.
        detectActiveNetwork()
    }

    func detectActiveNetwork(completion: (() -> Void)? = nil) {
        guard !isDetectingNetwork, workflowPowerGuard.allowsSampling else { return }
        isDetectingNetwork = true
        let generation = workflowPowerGuard.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let observed = RealtimeTrafficApp.discoverDefaultIPv4()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDetectingNetwork = false
                guard self.workflowPowerGuard.generation == generation,
                      self.workflowPowerGuard.allowsSampling else { return }
                self.applyDiscoveredNetwork(interface: observed.interface, ip: observed.ip)
                completion?()
            }
        }
    }

    func getInterfaceBytes(name: String) -> (ibytes: UInt64, obytes: UInt64)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let ifaName = String(cString: ifa.ifa_name)
            if ifaName == name, let address = ifa.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let raw = ifa.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self)
                return (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
            }
        }
        return nil
    }

    // Read physical Ethernet/Wi-Fi counters only. No VPN/loopback double counting.
    // Interface traffic includes link-local/LAN bytes, not authoritative campus quota.
    func readScopedInterfaces() -> [ScopedInterfaceSample] {
        let devices = SCNetworkInterfaceCopyAll() as NSArray
        var types: [String: String] = [:]
        for item in devices {
            let interface = item as! SCNetworkInterface
            if let name = SCNetworkInterfaceGetBSDName(interface) as String?,
               let kind = SCNetworkInterfaceGetInterfaceType(interface) as String? {
                if kind == (kSCNetworkInterfaceTypeEthernet as String) ||
                    kind == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                    types[name] = kind
                }
            }
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String: [String]] = [:]
        var counters: [String: InterfaceCounters] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            let name = String(cString: item.ifa_name)
            guard types[name] != nil, let address = item.ifa_addr else { continue }
            if address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name, default: []].append(String(cString: host))
                }
            } else if address.pointee.sa_family == UInt8(AF_LINK), let raw = item.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = InterfaceCounters(interfaceID: name,
                    received: UInt64(data.ifi_ibytes), sent: UInt64(data.ifi_obytes))
            }
        }
        return counters.keys.sorted().compactMap { name in
            guard let counter = counters[name], let kind = types[name] else { return nil }
            let ips = addresses[name, default: []].sorted()
            let campus = ips.contains { $0.hasPrefix("140.120.") }
            let hotspot = ips.contains { $0.hasPrefix("172.20.10.") }
            var scope: NetworkScope = .unknown
            // Explicit overrides affect only the currently selected interface.
            if name == activeInterface && networkModeOverride != 0 && !ips.isEmpty {
                switch networkModeOverride {
                case 1: scope = .dorm
                case 2: scope = .campusWifi
                case 3: scope = .external
                default: break
                }
            } else if campus {
                scope = kind == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .campusWifi : .dorm
            } else if hotspot {
                scope = .external
            }
            return ScopedInterfaceSample(counters: counter, scope: scope,
                identity: kind + "|" + ips.joined(separator: ","))
        }
    }

    func initHardwareCounters() {
        predictionEngine.reset()
        predictionScope = .unknown
        predictionIdentity = []
        scopedAccumulator.reset()
        activeSpeedMeasured = false
        let samples = readScopedInterfaces()
        sampledScopes = Dictionary(uniqueKeysWithValues: samples.map { ($0.counters.interfaceID, $0.scope) })
        let uptime = ProcessInfo.processInfo.systemUptime
        _ = scopedAccumulator.ingest(samples, day: currentDateString, uptime: uptime)
        lastSampleUptime = uptime
        currentDownSpeed = 0
        currentUpSpeed = 0
    }

    var pingInFlight = false
    func measurePingLatency() {
        guard workflowPowerGuard.allowsOptionalProbes, !pingInFlight, isConnected else { return }
        pingInFlight = true
        let generation = workflowPowerGuard.generation
        let expectedIP = currentIP
        let expectedInterface = activeInterface
        let target = isQuotaRestricted ? "140.120.1.2" : "1.1.1.1"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = ProbeRunner.run("/sbin/ping", ["-c", "2", "-t", "2", target], timeout: 4)
            var latency: Double?
            if case .success(let out) = outcome,
               let range = out.range(of: "time="),
               let first = out[range.upperBound...].split(separator: " ").first,
               let value = Double(first), value.isFinite, value >= 0 {
                latency = value
            }
            let measured = latency
            DispatchQueue.main.async {
                guard let self else { return }
                self.pingInFlight = false
                guard self.workflowPowerGuard.generation == generation,
                      self.currentIP == expectedIP, self.activeInterface == expectedInterface else { return }
                let uptime = ProcessInfo.processInfo.systemUptime
                self.pingLatencyMs = measured ?? -1
                self.lastPingUptime = measured == nil ? nil : uptime
                self.networkQuality.ingest(latency: measured, uptime: uptime)
            }
        }
    }

    func inspectTopAppConsumers() {
        guard workflowPowerGuard.allowsOptionalProbes, !appProbeInFlight else { return }
        appProbeInFlight = true
        let generation = workflowPowerGuard.generation
        DispatchQueue.global(qos: .background).async { [weak self] in
            let outcome = ProbeRunner.run("/usr/bin/nettop", ["-P", "-L", "1", "-J", "bytes_in,bytes_out"], timeout: 5)
            let observations: [AppTrafficObservation]?
            if case .success(let out) = outcome {
                observations = AppTrafficParser.parse(out)
            } else { observations = nil }
            DispatchQueue.main.async {
                guard let self else { return }
                self.appProbeInFlight = false
                guard self.workflowPowerGuard.generation == generation else { return }
                self.topAppConsumers = (observations ?? []).map { (name: $0.name, bytes: Double($0.bytes)) }
                self.appProbeTimestamp = observations == nil ? nil : ProcessInfo.processInfo.systemUptime
                if self.popover.isShown { self.pushDataToWebUI() }
            }
        }
    }

    func tickRealtime() {
        guard workflowPowerGuard.allowsSampling else { return }
        let todayStr = getTodayString()
        if todayStr != currentDateString {
            if !currentDateString.isEmpty {
                let totalDl = dormTodayInBytes + wifiTodayInBytes + extTodayInBytes + unattributedInBytes
                let totalUl = dormTodayOutBytes + wifiTodayOutBytes + extTodayOutBytes + unattributedOutBytes
                if (totalDl + totalUl) > 0 {
                    if !TrafficHistoryManager.shared.recordDay(date: currentDateString, dl: totalDl, ul: totalUl) {
                        // Preserve the existing daily file when history cannot be saved.
                        let url = URL(fileURLWithPath: stateFilePath)
                        do {
                            if FileManager.default.fileExists(atPath: url.path) {
                                try FileManager.default.copyItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(".nchu_traffic_archive-" + currentDateString + "-" + UUID().uuidString + ".json"))
                            }
                        } catch { persistenceBlocked = true }
                    }
                }
            }
            currentDateString = todayStr
            dormTodayInBytes = 0.0
            dormTodayOutBytes = 0.0
            wifiTodayInBytes = 0.0
            wifiTodayOutBytes = 0.0
            extTodayInBytes = 0.0
            extTodayOutBytes = 0.0
            unattributedInBytes = 0
            unattributedOutBytes = 0
            sampleGapCount = 0
            scopedAccumulator.reset()
            predictionEngine.reset()
            predictionScope = .unknown
            predictionIdentity = []
            lastSampleUptime = nil
            providerObservation = nil
            alertTierSent = 0
            if isWiredTemporarilyDisabled {
                restoreWiredNetwork(reason: "每日 00:00 額度重設")
            }
            if let b = getInterfaceBytes(name: activeInterface) {
                lastRawIBytes = b.ibytes
                lastRawOBytes = b.obytes
            }
            savePersistedState()
            if isDormNetwork {
                syncWithTop100Server()
            }
        }
        
        let now = Date().timeIntervalSince1970
        // 盒蓋動態偵測 (防止接外接螢幕或 displaysleep 0 時背景持續串流)
        if isLidGuardEnabled {
            let lidClosed = isLidClosed()
            if lidClosed && !isLidCurrentlyClosed {
                isLidCurrentlyClosed = true
                activateLidGuard(reason: "筆電盒蓋", freezeRenderers: true)
            } else if !lidClosed && isLidCurrentlyClosed {
                isLidCurrentlyClosed = false
                deactivateLidGuard(reason: "筆電開蓋")
            }
        }
        
        // 離座閒置動態偵測 (防止人離開座位未盒蓋，而背景被串流或下載暗中掏空流量)
        if isIdleGuardEnabled && !isLidCurrentlyClosed {
            let idleSecs = getSystemIdleSeconds()
            if idleSecs >= 600.0 && !isUserCurrentlyIdle { // 閒置超過 10 分鐘
                if !workflowPowerGuard.focusEnabled && currentDownSpeed > 150 * 1024 {
                    isUserCurrentlyIdle = true
                    activateIdleGuard(reason: String(format: "已離座閒置 %.0f 分鐘", idleSecs / 60))
                }
            } else if idleSecs < 5.0 && isUserCurrentlyIdle {
                isUserCurrentlyIdle = false
                deactivateIdleGuard(reason: "滑鼠鍵盤操作")
            }
        }
        
        // 每 10 秒自動非同步重新偵測網路介面（動態感應插拔網線或切換手機熱點/Wi-Fi，零卡頓）
        if Int(now) % 10 == 0 {
            detectActiveNetwork()
        }
        
        // 每 5 秒自動掃描 P2P 違規風險（宿網防鎖孔）
        if Int(now) % 5 == 0 {
            checkP2PHazard()
        }
        
        // 00:00 換日大檔排程檢查 (00:05 額度重置後自動啟動千兆通道)
        let cal = Calendar.current
        let nowComp = cal.dateComponents([.hour, .minute], from: Date())
        let hour = nowComp.hour ?? 0
        let minute = nowComp.minute ?? 0
        if hour == 0 && minute >= 5 && minute <= 10 {
            if isMidnightScheduleEnabled && !hasTriggeredMidnightToday {
                hasTriggeredMidnightToday = true
                if isWiredTemporarilyDisabled {
                    restoreWiredNetwork(reason: "午夜 00:05 大檔排程啟動")
                }
                sendSystemNotification(
                    title: "🎉 興大宿網換日配額已就緒！",
                    body: "7GB 下載額度已充飽！午夜大檔極速通道已啟動。"
                )
            }
        } else if hour > 0 {
            hasTriggeredMidnightToday = false
        }
        
        let samples = readScopedInterfaces()
        sampledScopes = Dictionary(uniqueKeysWithValues: samples.map { ($0.counters.interfaceID, $0.scope) })
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = lastSampleUptime.map { max(uptime - $0, 0.001) } ?? 1
        let deltas = scopedAccumulator.ingest(samples, day: currentDateString, uptime: uptime)
        lastSampleUptime = uptime
        currentDownSpeed = 0
        currentUpSpeed = 0
        activeSpeedMeasured = false
        if samples.isEmpty || deltas.values.contains(where: { $0.delta.quality == .unknown }) {
            sampleGapCount += 1
        }
        for (name, value) in deltas where value.delta.quality == .measured {
            let rx = Double(value.delta.received)
            let tx = Double(value.delta.sent)
            if name == activeInterface {
                activeSpeedMeasured = true
                currentDownSpeed = rx / elapsed
                currentUpSpeed = tx / elapsed
            }
            switch value.scope {
            case .dorm: dormTodayInBytes += rx; dormTodayOutBytes += tx
            case .campusWifi: wifiTodayInBytes += rx; wifiTodayOutBytes += tx
            case .external: extTodayInBytes += rx; extTodayOutBytes += tx
            case .unknown: unattributedInBytes += rx; unattributedOutBytes += tx
            }
        }

        updateForecast(samples: samples, deltas: deltas, elapsed: elapsed)

        if Int(now) % 10 == 0 {
            savePersistedState()
        }
        
        // 興大網路環境 (宿網或校園 Wi-Fi) 下啟用流量預警推播與急停防護
        if isAlertEnabled && isQuotaRestricted {
            checkAndSendSmartAlerts()
        }
        
        updateStatusBar()
        if settingsWindowController?.window?.isVisible == true { syncSettingsModel() }
        if managementWindowController?.window?.isVisible == true { syncManagementModel() }
        
        if popover.isShown {
            pushDataToWebUI()
        }
    }

    var lastCriticalNotificationTime: TimeInterval = 0

    func updateForecast(samples: [ScopedInterfaceSample], deltas: [String: ScopedTrafficDelta], elapsed: Double) {
        let scope = sampledScopes[activeInterface] ?? .unknown
        guard isConnected, scope == .dorm || scope == .campusWifi else {
            predictionEngine.reset()
            predictionScope = .unknown
            predictionIdentity = []
            return
        }
        let scopedSamples = samples.filter { $0.scope == scope }
        let identity = Set(scopedSamples.map { $0.counters.interfaceID + "|" + $0.identity })
        if predictionScope != scope || predictionIdentity != identity {
            predictionEngine.reset()
            predictionScope = scope
            predictionIdentity = identity
        }
        guard !scopedSamples.isEmpty,
              !deltas.values.contains(where: { $0.delta.quality == .unknown || $0.scope == .unknown }),
              scopedSamples.allSatisfy({ deltas[$0.counters.interfaceID]?.scope == scope })
        else { predictionEngine.reset(); return }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for sample in scopedSamples {
            guard let delta = deltas[sample.counters.interfaceID]?.delta,
                  delta.quality == .measured else { predictionEngine.reset(); return }
            let (nextRx, rxOverflow) = rx.addingReportingOverflow(delta.received)
            let (nextTx, txOverflow) = tx.addingReportingOverflow(delta.sent)
            guard !rxOverflow, !txOverflow else { predictionEngine.reset(); return }
            rx = nextRx
            tx = nextTx
        }
        predictionEngine.append(TrafficRateSample(seconds: elapsed, received: rx, sent: tx))
    }

    private func localQuotaAssessment() -> LocalQuotaAssessment? {
        let scope = sampledScopes[activeInterface] ?? .unknown
        guard isConnected, isQuotaRestricted,
              (scope == .dorm && isDormNetwork) || (scope == .campusWifi && isCampusWifi) else { return nil }
        let (_, dl, ul) = getEffectiveUsedBytes()
        guard let received = UInt64(exactly: dl), let sent = UInt64(exactly: ul) else { return nil }
        return LocalQuotaPolicy.assess(received: received, sent: sent,
            receiveLimit: UInt64(dlQuotaBytes), sendLimit: UInt64(ulQuotaBytes), totalLimit: UInt64(totalQuotaBytes))
    }

    private func budgetLabel(_ budget: LimitingBudget) -> String {
        switch budget {
        case .download: return "下載"
        case .upload: return "上傳"
        case .total: return "總量"
        }
    }

    func forecastPresentation() -> (message: String, level: String) {
        guard let assessment = localQuotaAssessment() else { return ("配額未確認，暫不預測", "unknown") }
        let level = assessment.tier >= .high ? "danger" : (assessment.tier == .warning ? "warning" : "unknown")
        let (_, dl, ul) = getEffectiveUsedBytes()
        let label = budgetLabel(assessment.limitingBudget)
        let status = "本機估計：\(label)已用 \(Int(min(assessment.usageRatio * 100, 999)))%"
        guard !persistenceBlocked, sampleGapCount == 0,
              predictionScope == sampledScopes[activeInterface],
              let f = predictionEngine.forecast(receiveRemaining: UInt64(max(0, dlQuotaBytes - dl)),
                                                 sendRemaining: UInt64(max(0, ulQuotaBytes - ul)),
                                                 totalRemaining: UInt64(max(0, totalQuotaBytes - dl - ul)))
        else { return (status + "；暫無可靠耗盡預測", level) }
        if f.latestSeconds == 0 {
            return ("本機估計\(budgetLabel(f.limitingBudget))已達設定上限", "danger")
        }
        let low = max(1, Int(floor(f.earliestSeconds / 60)))
        let high = max(low, Int(ceil(f.latestSeconds / 60)))
        return ("若近期速率持續，\(budgetLabel(f.limitingBudget))約 \(low)–\(high) 分鐘達設定上限（估計）", level)
    }

    func checkAndSendSmartAlerts() {
        guard let assessment = localQuotaAssessment() else { return }
        let scope = sampledScopes[activeInterface] ?? .unknown
        guard quotaAlertLedger.shouldNotify(day: currentDateString, scope: scope,
                 tier: assessment.tier, enabled: isAlertEnabled) else { return }
        sendSystemNotification(title: "NetGuard 本機用量提醒",
            body: "本機估計\(budgetLabel(assessment.limitingBudget))已達 \(assessment.tier.rawValue == 3 ? "95" : assessment.tier.rawValue == 2 ? "85" : "70")% 設定額度。請核對實際配額，無自動斷網或停止程式。",
            isCritical: true, quotaAlert: true)
    }

    // Fixed AppleScript program; external titles/messages are argv data, not code.
    func sendSystemNotification(title: String, body: String, isCritical: Bool = false, quotaAlert: Bool = false) {
        guard isCritical else { return }
        if !quotaAlert {
            let now = Date().timeIntervalSince1970
            guard (now - lastCriticalNotificationTime) > 14400.0 else { return }
            lastCriticalNotificationTime = now
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "on run argv", "-e",
                "display notification (item 2 of argv) with title (item 1 of argv)",
                "-e", "end run", "--", title, body]
            try? process.run()
        }
    }

    func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1024 * 1024 {
            return String(format: "%.1fM/s", bytesPerSec / (1024 * 1024))
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0fK/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.0fB/s", bytesPerSec)
        }
    }

    func formatBytes(_ b: Double) -> String {
        if b >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
        } else if b >= 1024 * 1024 {
            return String(format: "%.1f MB", b / (1024 * 1024))
        } else if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        } else {
            return String(format: "%.0f B", b)
        }
    }

    func getEffectiveUsedBytes() -> (total: Double, dl: Double, ul: Double) {
        // Provider ranking has unverified units and measurement time. Never merge
        // it with interface counters; both sources are presented independently.
        let dl = isCampusWifi ? wifiTodayInBytes : dormTodayInBytes
        let ul = isCampusWifi ? wifiTodayOutBytes : dormTodayOutBytes
        return (dl + ul, dl, ul)
    }

    func updateStatusBar() {
        guard let button = statusItem.button else { return }
        
        if !isConnected {
            button.title = "⚠️ 網路斷線"
            return
        }
        
        if isQuotaRestricted {
            let (totalUsed, dlUsed, ulUsed) = getEffectiveUsedBytes()
            let remTotalGB = max(0, totalQuotaBytes - totalUsed) / (1024 * 1024 * 1024)
            let remDlGB = max(0, dlQuotaBytes - dlUsed) / (1024 * 1024 * 1024)
            let remUlGB = max(0, ulQuotaBytes - ulUsed) / (1024 * 1024 * 1024)
            let bottleneckRemGB = min(remTotalGB, remDlGB, remUlGB)
            let maxUsagePct = max((totalUsed / totalQuotaBytes) * 100.0, (dlUsed / dlQuotaBytes) * 100.0, (ulUsed / ulQuotaBytes) * 100.0)
            
            let statusIcon: String
            let dotIcon: String
            let warningThreshold = isCampusWifi ? 2.5 : 1.5
            let dangerThreshold = isCampusWifi ? 1.0 : 0.7
            
            if maxUsagePct >= 90.0 || bottleneckRemGB <= dangerThreshold {
                statusIcon = "🚨"
                dotIcon = "🔴"
            } else if maxUsagePct >= 75.0 || bottleneckRemGB <= warningThreshold {
                statusIcon = "⚠️"
                dotIcon = "🟡"
            } else {
                statusIcon = isCampusWifi ? "📶" : "🌐"
                dotIcon = "🟢"
            }
            
            let displayGB = remDlGB
            
            switch displayMode {
            case 0:
                button.title = String(format: "%@ %.2fG", statusIcon, displayGB)
            case 1:
                button.title = String(format: "%@ 剩 %.2fG", statusIcon, displayGB)
            case 2:
                button.title = String(format: "%@ ↓%@ ↑%@", statusIcon, formatSpeed(currentDownSpeed), formatSpeed(currentUpSpeed))
            case 3:
                button.title = String(format: "%@ %.2fG", dotIcon, displayGB)
            case 4:
                button.title = String(format: "%.2fG", displayGB)
            default:
                button.title = String(format: "%@ %.2fG", statusIcon, displayGB)
            }
        } else {
            // 非宿網 / 外部網路模式 (無配額限制，暢連無負擔)
            let extTotalBytes = extTodayInBytes + extTodayOutBytes
            let extTotalStr = formatBytes(extTotalBytes)
            let statusIcon = "⚡"
            
            switch displayMode {
            case 0:
                button.title = String(format: "%@ %@", statusIcon, extTotalStr)
            case 1:
                button.title = String(format: "%@ 已用 %@", statusIcon, extTotalStr)
            case 2:
                button.title = String(format: "%@ ↓%@ ↑%@", statusIcon, formatSpeed(currentDownSpeed), formatSpeed(currentUpSpeed))
            case 3:
                button.title = String(format: "🟢 %@", extTotalStr)
            case 4:
                button.title = extTotalStr
            default:
                button.title = String(format: "%@ %@", statusIcon, extTotalStr)
            }
        }
    }

    func syncWithTop100Server() {
        guard workflowPowerGuard.allowsOptionalProbes else { return }
        guard isDormNetwork, isConnected, !currentIP.isEmpty else {
            providerObservation = nil
            providerRequestID = UUID()
            providerRequestInFlight = false
            return
        }
        guard !providerRequestInFlight,
              providerLastAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        let expectedIP = currentIP
        let expectedDay = getTodayString()
        let requestID = UUID()
        providerRequestID = requestID
        providerLastAttempt = Date()
        providerRequestInFlight = true
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            var result: ProviderObservation?
            defer {
                let observation = result
                DispatchQueue.main.async {
                    guard self.providerRequestID == requestID else { return }
                    self.providerRequestInFlight = false
                    guard self.isConnected, self.isDormNetwork,
                          self.currentIP == expectedIP, self.getTodayString() == expectedDay else {
                        self.providerObservation = nil
                        return
                    }
                    self.providerObservation = observation
                    if self.popover != nil && self.popover.isShown { self.pushDataToWebUI() }
                }
            }
            guard let scriptPath = Bundle.main.url(forResource: "traffic_monitor", withExtension: "py")?.path else { return }
            guard case .success(let output) = ProbeRunner.run("/usr/bin/python3", [scriptPath, "--json"], timeout: 15),
                  let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["schema_version"] as? Int == 1,
                  json["ip"] as? String == expectedIP,
                  let top = json["top100"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: top),
                  let observation = try? JSONDecoder().decode(ProviderObservation.self, from: encoded)
            else { return }
            result = observation
        }
    }

    func isLaunchAtLoginEnabled() -> Bool {
        let launchAgentPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/tw.edu.nchu.dorm.traffic.plist").path
        return FileManager.default.fileExists(atPath: launchAgentPath)
    }

    func toggleLaunchAtLogin() {
        let launchAgentPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/tw.edu.nchu.dorm.traffic.plist").path
        
        if isLaunchAtLoginEnabled() {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            guard let appPath = Bundle.main.executableURL?.path else { return }
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: launchAgentPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            let escapedAppPath = appPath.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>tw.edu.nchu.dorm.traffic</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(escapedAppPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            try? plistContent.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        }
    }

    func showContextMenu() {
        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "⚙️ 網路流量監控 設定 (\(networkTypeName))", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        let nativeItem = NSMenuItem(title: nativePanelEnabled ? "返回完整管理面板" : "試用原生快速面板（預覽）", action: #selector(toggleNativePanelPreview), keyEquivalent: "")
        nativeItem.target = self
        menu.addItem(nativeItem)
        let historyItem = NSMenuItem(title: "歷史流量與 CSV 匯出", action: #selector(openHistoryAnalytics), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let settingsItem = NSMenuItem(title: "原生設定中心", action: #selector(openNativeSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let managementItem = NSMenuItem(title: "原生網路管理與診斷", action: #selector(openNativeManagement), keyEquivalent: "")
        managementItem.target = self
        menu.addItem(managementItem)
        menu.addItem(NSMenuItem.separator())
        
        let netModeMenu = NSMenu()
        let nAuto = NSMenuItem(title: "自動偵測 (目前: \(networkTypeName))", action: #selector(setNetModeAuto), keyEquivalent: "")
        nAuto.target = self; nAuto.state = (networkModeOverride == 0) ? .on : .off
        netModeMenu.addItem(nAuto)
        
        let nDorm = NSMenuItem(title: "強制興大宿網模式 (11GB 配額限制 / 鎖卡)", action: #selector(setNetModeDorm), keyEquivalent: "")
        nDorm.target = self; nDorm.state = (networkModeOverride == 1) ? .on : .off
        netModeMenu.addItem(nDorm)
        
        let nWifi = NSMenuItem(title: "強制興大校園 Wi-Fi (15GB 配額 / 超量限速不斷網)", action: #selector(setNetModeWifi), keyEquivalent: "")
        nWifi.target = self; nWifi.state = (networkModeOverride == 2) ? .on : .off
        netModeMenu.addItem(nWifi)
        
        let nExt = NSMenuItem(title: "強制非宿網/自由模式 (無上限)", action: #selector(setNetModeExt), keyEquivalent: "")
        nExt.target = self; nExt.state = (networkModeOverride == 3) ? .on : .off
        netModeMenu.addItem(nExt)
        
        let netModeParent = NSMenuItem(title: "🌐 網路環境模式: \(networkTypeName)", action: nil, keyEquivalent: "")
        netModeParent.submenu = netModeMenu
        menu.addItem(netModeParent)
        menu.addItem(NSMenuItem.separator())
        
        let autoLaunchItem = NSMenuItem(title: "🚀 開機自動啟動", action: #selector(handleToggleAutoLaunch), keyEquivalent: "")
        autoLaunchItem.target = self
        autoLaunchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(autoLaunchItem)
        
        let alertToggleItem = NSMenuItem(title: "🔔 啟用流量預警推播 (宿網 & 校園 Wi-Fi)", action: #selector(handleToggleAlert), keyEquivalent: "")
        alertToggleItem.target = self
        alertToggleItem.state = isAlertEnabled ? .on : .off
        menu.addItem(alertToggleItem)
        
        let lidGuardToggleItem = NSMenuItem(title: "🛡️ 盒蓋/睡眠防偷跑守護 (暫停串流與同步)", action: #selector(handleToggleLidGuard), keyEquivalent: "")
        lidGuardToggleItem.target = self
        lidGuardToggleItem.state = isLidGuardEnabled ? .on : .off
        menu.addItem(lidGuardToggleItem)
        
        let idleGuardToggleItem = NSMenuItem(title: "🚶 離座閒置防偷跑守護 (10分鐘無操作暫停)", action: #selector(handleToggleIdleGuard), keyEquivalent: "")
        idleGuardToggleItem.target = self
        idleGuardToggleItem.state = isIdleGuardEnabled ? .on : .off
        menu.addItem(idleGuardToggleItem)
        
        let failoverItem = NSMenuItem(title: "🔀 宿網耗盡自動切換 Wi-Fi (免拔線避難)", action: #selector(handleToggleWifiFailover), keyEquivalent: "")
        failoverItem.target = self
        failoverItem.state = isAutoWifiFailoverEnabled ? .on : .off
        menu.addItem(failoverItem)
        
        let splitItem = NSMenuItem(title: "🔀 興大校內/外雙軌智慧分流", action: #selector(handleToggleSplitRouting), keyEquivalent: "")
        splitItem.target = self
        splitItem.state = isSplitRoutingEnabled ? .on : .off
        menu.addItem(splitItem)
        
        let midnightItem = NSMenuItem(title: "🌙 00:00 換日大檔排程 (00:05 重置啟動)", action: #selector(handleToggleMidnightSchedule), keyEquivalent: "")
        midnightItem.target = self
        midnightItem.state = isMidnightScheduleEnabled ? .on : .off
        menu.addItem(midnightItem)
        
        let p2pShieldItem = NSMenuItem(title: "🛡️ 興大宿網 P2P 違規攔截盾 (自動防禦)", action: #selector(handleToggleP2PShield), keyEquivalent: "")
        p2pShieldItem.target = self
        p2pShieldItem.state = isP2PShieldAutoKillEnabled ? .on : .off
        menu.addItem(p2pShieldItem)
        
        let blocklistItem = NSMenuItem(title: "🔍 興大計中黑名單即時診斷", action: #selector(handleCheckBlocklistNow), keyEquivalent: "")
        blocklistItem.target = self
        menu.addItem(blocklistItem)
        
        if isWiredTemporarilyDisabled {
            let restoreItem = NSMenuItem(title: "🔌 立即恢復有線宿網 (目前處於 Wi-Fi 避難)", action: #selector(handleRestoreWired), keyEquivalent: "")
            restoreItem.target = self
            menu.addItem(restoreItem)
        } else if isDormNetwork {
            let switchWifiItem = NSMenuItem(title: "🔀 立即切換為校園 Wi-Fi (免拔線避難)", action: #selector(handleManualSwitchToWifi), keyEquivalent: "")
            switchWifiItem.target = self
            menu.addItem(switchWifiItem)
        }
        
        let panicTitle = pausedPIDs.isEmpty ? "⚡ 一鍵急救省流 (立即暫停串流與同步)" : "▶️ 解除省流 (恢復背景串流與同步)"
        let panicItem = NSMenuItem(title: panicTitle, action: #selector(handlePanicFreeze), keyEquivalent: "p")
        panicItem.target = self
        menu.addItem(panicItem)
        
        let modeMenu = NSMenu()
        let m0 = NSMenuItem(title: "精簡容量 (預設，固定寬度無跳動)", action: #selector(setMode0), keyEquivalent: "")
        m0.target = self; m0.state = (displayMode == 0) ? .on : .off
        modeMenu.addItem(m0)
        
        let m1 = NSMenuItem(title: "僅顯示容量 (例如: 剩 10.7G / 已用 1.2G)", action: #selector(setMode1), keyEquivalent: "")
        m1.target = self; m1.state = (displayMode == 1) ? .on : .off
        modeMenu.addItem(m1)
        
        let m2 = NSMenuItem(title: "僅顯示即時雙向網速 (例如: ↓ 1.2M ↑ 85K)", action: #selector(setMode2), keyEquivalent: "")
        m2.target = self; m2.state = (displayMode == 2) ? .on : .off
        modeMenu.addItem(m2)
        
        let m3 = NSMenuItem(title: "狀態安全燈 + 容量 (例如: 🟢 10.7G)", action: #selector(setMode3), keyEquivalent: "")
        m3.target = self; m3.state = (displayMode == 3) ? .on : .off
        modeMenu.addItem(m3)
        
        let m4 = NSMenuItem(title: "極簡純數字 (例如: 10.77G / 1.25G)", action: #selector(setMode4), keyEquivalent: "")
        m4.target = self; m4.state = (displayMode == 4) ? .on : .off
        modeMenu.addItem(m4)
        
        let modeParent = NSMenuItem(title: "🖥️ 選單列顯示樣式", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)
        
        menu.addItem(NSMenuItem.separator())
        
        let resetItem = NSMenuItem(title: "🧹 重置今日統計 (歸零)", action: #selector(manualResetToday), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "❌ 退出監控", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func setNetModeAuto() { networkModeOverride = 0; savePersistedState(); updateStatusBar(); pushDataToWebUI() }
    @objc func setNetModeDorm() { networkModeOverride = 1; savePersistedState(); updateStatusBar(); pushDataToWebUI() }
    @objc func setNetModeWifi() { networkModeOverride = 2; savePersistedState(); updateStatusBar(); pushDataToWebUI() }
    @objc func setNetModeExt() { networkModeOverride = 3; savePersistedState(); updateStatusBar(); pushDataToWebUI() }

    @objc func handleToggleAutoLaunch() { toggleLaunchAtLogin() }
    @objc func handleToggleAlert() { isAlertEnabled = !isAlertEnabled; savePersistedState() }
    @objc func handleToggleLidGuard() {
        isLidGuardEnabled = !isLidGuardEnabled
        savePersistedState()
        pushDataToWebUI()
        if !isLidGuardEnabled && isLidCurrentlyClosed {
            isLidCurrentlyClosed = false
            deactivateLidGuard(reason: "盒蓋防護已手動關閉")
        }
    }

    @objc func handleToggleIdleGuard() {
        isIdleGuardEnabled = !isIdleGuardEnabled
        savePersistedState()
        pushDataToWebUI()
        if !isIdleGuardEnabled && isUserCurrentlyIdle {
            isUserCurrentlyIdle = false
            deactivateIdleGuard(reason: "離座防護已手動關閉")
        }
    }

    @objc func handleToggleWifiFailover() {
        reportNetworkMutationUnavailable()
    }

    @objc func handleManualSwitchToWifi() {
        switchToWifi(reason: "手動觸發免拔線切換")
    }

    @objc func handleRestoreWired() {
        failoverCooldownUntil = Date().timeIntervalSince1970 + 600
        restoreWiredNetwork(reason: "手動恢復有線宿網")
    }

    @objc func handlePanicFreeze() {
        if !pausedPIDs.isEmpty {
            deactivateLidGuard(reason: "手動解除省流")
        } else {
            activateLidGuard(reason: "⚡ 一鍵急救省流")
        }
        pushDataToWebUI()
    }

    @objc func handleToggleSplitRouting() {
        reportNetworkMutationUnavailable()
    }

    @objc func handleToggleMidnightSchedule() {
        reportNetworkMutationUnavailable()
    }

    @objc func handleToggleSpeedAutoSwitch() {
        reportNetworkMutationUnavailable()
    }

    @objc func handleRunSpeedRaceNow() {
        evaluateDualNetworkSpeedAndSwitch(forceSpeedBurst: true, manualTrigger: true)
    }

    @objc func handleToggleP2PShield() {
        isP2PShieldAutoKillEnabled = false
        killCurrentP2PApp()
        pushDataToWebUI()
    }

    @objc func handleKillP2PApp() {
        killCurrentP2PApp()
    }

    @objc func handleCheckBlocklistNow() {
        checkIpBlocklist()
    }

    @objc func openIpBlock() {
        if let url = URL(string: "https://ipblock.nchu.edu.tw/cblocklist_public.php") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func setMode0() { displayMode = 0; savePersistedState(); updateStatusBar() }
    @objc func setMode1() { displayMode = 1; savePersistedState(); updateStatusBar() }
    @objc func setMode2() { displayMode = 2; savePersistedState(); updateStatusBar() }
    @objc func setMode3() { displayMode = 3; savePersistedState(); updateStatusBar() }
    @objc func setMode4() { displayMode = 4; savePersistedState(); updateStatusBar() }

    @objc func manualRefresh() {
        detectActiveNetwork()
        syncWithTop100Server()
        measurePingLatency()
        inspectTopAppConsumers()
        pushDataToWebUI()
    }

    @objc func manualResetToday() {
        if isCampusWifi {
            wifiTodayInBytes = 0.0
            wifiTodayOutBytes = 0.0
            alertTierSent = 0
        } else if isDormNetwork {
            dormTodayInBytes = 0.0
            dormTodayOutBytes = 0.0
            alertTierSent = 0
        } else {
            extTodayInBytes = 0.0
            extTodayOutBytes = 0.0
        }
        if isWiredTemporarilyDisabled {
            restoreWiredNetwork(reason: "今日流量重置歸零")
        }
        initHardwareCounters()
        sampleGapCount += 1
        savePersistedState()
        updateStatusBar()
        pushDataToWebUI()
    }

    @objc func openTop100() {
        if let url = URL(string: "https://top100.nchu.edu.tw") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openIPMS() {
        if let url = URL(string: "http://140.120.4.13/apply.php") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quitApp() {
        savePersistedState()
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = RealtimeTrafficApp()
app.delegate = delegate
app.run()
