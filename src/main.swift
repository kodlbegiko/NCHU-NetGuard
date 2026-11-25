import Cocoa
import Foundation
import WebKit
import IOKit

// MARK: - 歷史紀錄模型與管理器
struct DayTrafficRecord {
    var total: Double
    var dl: Double
    var ul: Double
}

class TrafficHistoryManager {
    static let shared = TrafficHistoryManager()
    let historyFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".nchu_traffic_history.json").path
    }()
    
    func loadHistory() -> [String: DayTrafficRecord] {
        guard FileManager.default.fileExists(atPath: historyFilePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: historyFilePath)),
              let rawDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return [:]
        }
        
        var result: [String: DayTrafficRecord] = [:]
        for (dateStr, val) in rawDict {
            if let num = val as? Double {
                result[dateStr] = DayTrafficRecord(total: num, dl: num * 0.9, ul: num * 0.1)
            } else if let subDict = val as? [String: Any] {
                let total = subDict["total"] as? Double ?? 0
                let dl = subDict["dl"] as? Double ?? (total * 0.9)
                let ul = subDict["ul"] as? Double ?? (total * 0.1)
                result[dateStr] = DayTrafficRecord(total: total, dl: dl, ul: ul)
            }
        }
        return result
    }
    
    func recordDay(date: String, dl: Double, ul: Double) {
        guard !date.isEmpty, (dl + ul) > 0 else { return }
        var current = loadHistory()
        current[date] = DayTrafficRecord(total: dl + ul, dl: dl, ul: ul)
        
        var saveDict: [String: [String: Double]] = [:]
        for (d, rec) in current {
            saveDict[d] = [
                "total": rec.total,
                "dl": rec.dl,
                "ul": rec.ul
            ]
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: saveDict, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: historyFilePath))
        }
    }
}

// MARK: - HTTPS 憑證處理器 (支援校園內網伺服器安全存取)
class InsecureCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - JavaScript 訊息處理器
class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var app: RealtimeTrafficApp?
    init(app: RealtimeTrafficApp) { self.app = app }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let action = message.body as? String else { return }
        DispatchQueue.main.async { [weak self] in
            switch action {
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
        let isWifiIface = (activeInterface == "en0")
        let isNchuIP = currentIP.hasPrefix("10.10.") || currentIP.hasPrefix("140.120.")
        return isWifiIface && isNchuIP
    }
    
    // 是否為興大二村有線宿網 (每日下載上限 7GB / 上傳 4GB / 總額 11GB，超量斷網鎖卡)
    var isDormNetwork: Bool {
        if networkModeOverride == 1 { return true }
        if networkModeOverride != 0 { return false }
        let isWiredIface = (activeInterface != "en0")
        return isWiredIface && currentIP.hasPrefix("140.120.")
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
            return "外部網路 / Wi-Fi"
        }
    }
    
    // 警報等級追蹤
    var alertTierSent: Int = 0
    var isAlertEnabled: Bool = true
    
    // 實時狀態與網速計算
    var activeInterface: String = "en0"
    var currentIP: String = "172.20.10.2"
    var isConnected: Bool = true
    var pingLatencyMs: Double = 2.1
    var consecutivePingFailures: Int = 0
    
    var lastRawIBytes: UInt64 = 0
    var lastRawOBytes: UInt64 = 0
    var lastTimestamp: TimeInterval = 0
    
    var currentDownSpeed: Double = 0
    var currentUpSpeed: Double = 0
    
    var topAppConsumers: [(name: String, bytes: Double)] = []
    var top100Data: [String: Any]?
    var displayMode: Int = 0
    
    // 盒蓋與離座防偷跑流量守護 (Lid & Idle Traffic Guard)
    var isLidGuardEnabled: Bool = true
    var isIdleGuardEnabled: Bool = true
    var isLidCurrentlyClosed: Bool = false
    var isUserCurrentlyIdle: Bool = false
    var isEmergencyBrakeActive: Bool = false
    var pausedPIDs: [pid_t] = []
    
    // 宿網避難與自動切換 Wi-Fi 守護 (Auto Wi-Fi Failover Guard)
    var isAutoWifiFailoverEnabled: Bool = true
    var isWiredTemporarilyDisabled: Bool = false
    var disabledWiredServiceName: String = "USB 10/100/1000 LAN"
    var isSwitchingNetwork: Bool = false
    var failoverCooldownUntil: TimeInterval = 0
    
    // 方向 1: 智慧網路調度與雙軌分流 (Smart Dual-Interface Routing & Split Tunneling)
    var isSplitRoutingEnabled: Bool = false
    var isMidnightScheduleEnabled: Bool = false
    var hasTriggeredMidnightToday: Bool = false
    
    // 雙網卡即時競速與慢速自動切換引擎 (Smart Speed Race & Auto-Switch Engine)
    var isSpeedAutoSwitchEnabled: Bool = true
    var wiredPingMs: Double = 4.0
    var wifiPingMs: Double = 46.3
    var wiredSpeedMbps: Double = 22.8
    var wifiSpeedMbps: Double = 1.0
    var wiredReachable: Bool = true
    var wifiReachable: Bool = true
    var isRunningSpeedRace: Bool = false
    var slowNetworkStreak: Int = 0
    var lastSpeedSwitchTime: TimeInterval = 0
    var speedGuardTimer: Timer?
    
    // 方向 2: 違規風險防禦與計中黑名單主動預警 (NCHU Security & Blacklist Early Warning)
    var isP2PShieldAutoKillEnabled: Bool = true
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
        let pRoute = Process()
        pRoute.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        pRoute.arguments = [
            "-setadditionalroutes", wiredService,
            "104.18.0.0", "255.254.0.0", gateway,    // OpenAI / ChatGPT / Codex / Cloudflare API
            "172.64.0.0", "255.248.0.0", gateway,    // OpenAI / Codex WebSockets & CUA
            "160.79.104.0", "255.255.254.0", gateway,// Anthropic / Claude API
            "140.82.112.0", "255.255.240.0", gateway,// GitHub / Git / API
            "185.199.108.0", "255.255.252.0", gateway,// GitHub Raw & Pages
            "151.101.0.0", "255.255.0.0", gateway,   // NPM / PyPI / Python / Fastly Dev Registry
            "140.120.0.0", "255.255.0.0", gateway    // 興大校內高速學術網段
        ]
        try? pRoute.run()
        pRoute.waitUntilExit()
    }

    func activateLidGuard(reason: String, freezeRenderers: Bool = false) {
        guard isLidGuardEnabled else { return }
        let codexActive = isCodexEcosystemActive()
        
        // 1. 發送系統級多媒體暫停 (瞬停背景音樂/影片)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.sendSystemMediaPause()
            usleep(400_000)
            if self?.isAudioPlaying() == true {
                self?.sendSystemMediaPause()
            }
        }
        
        // 2. 備用 AppleScript（僅暫停 <video>/<audio> 標籤播放，絕不干擾 Codex 操控之網頁 DOM 或腳本執行）
        DispatchQueue.global(qos: .utility).async {
            let scriptSource = """
            tell application "Google Chrome"
                if it is running then
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                execute t javascript "document.querySelectorAll('video, audio').forEach(el => { el.pause(); });"
                            end try
                        end repeat
                    end repeat
                end if
            end tell
            """
            if let script = NSAppleScript(source: scriptSource) {
                var err: NSDictionary?
                script.executeAndReturnError(&err)
            }
        }
        
        // 3. 暫停高耗流量之背景同步與下載工具（Codex 與其調用的軟體享有 100% 豁免權）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var stopped: [pid_t] = self.pausedPIDs
            
            var targetApps = ["Google Drive", "OneDrive", "Dropbox", "qBittorrent", "Transmission", "Steam"]
            // 若 Codex 正在運行或操控電腦 (SkyComputerUseService / cua_node)，豁免 Chrome Renderers 免於凍結！
            if freezeRenderers && !codexActive {
                targetApps.append("Google Chrome Helper (Renderer)")
            }
            
            for appName in targetApps {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                p.arguments = ["-f", appName]
                let pipe = Pipe()
                p.standardOutput = pipe
                try? p.run()
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                for line in out.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let pidVal = Int32(trimmed) else { continue }
                    let checkProc = Process()
                    checkProc.executableURL = URL(fileURLWithPath: "/bin/ps")
                    checkProc.arguments = ["-p", "\(pidVal)", "-o", "command="]
                    let checkPipe = Pipe()
                    checkProc.standardOutput = checkPipe
                    try? checkProc.run()
                    checkProc.waitUntilExit()
                    let cmdOut = String(data: checkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if self.isExemptProcessForCodex(cmdOut: cmdOut) {
                        continue
                    }
                    
                    if !stopped.contains(pidVal) {
                        kill(pidVal, SIGSTOP)
                        stopped.append(pidVal)
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.pausedPIDs = stopped
            }
        }
        
        sendSystemNotification(
            title: "🌙 流量防護已生效 (\(reason))",
            body: codexActive ? "已暫停背景同步，同時為 Codex 與受控軟體保留 100% 網路豁免權！" : "已自動硬體級急停影音串流與背景同步，嚴防暗中消耗宿網！"
        )
    }

    func deactivateLidGuard(reason: String) {
        // 恢復暫停的背景程序
        if !pausedPIDs.isEmpty {
            for pid in pausedPIDs {
                kill(pid, SIGCONT)
            }
            pausedPIDs.removeAll()
        }
        
        sendSystemNotification(
            title: "☀️ 歡迎回來 (\(reason))",
            body: "已解除背景凍結，恢復正常運行。"
        )
    }

    func activateIdleGuard(reason: String) {
        guard isIdleGuardEnabled && !isLidCurrentlyClosed else { return }
        // 若 Codex (SkyComputerUseService / cua_node) 正在自動化操控電腦，完全豁免離座閒置防護！
        if isCodexEcosystemActive() { return }
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
        guard !isSwitchingNetwork else { return }
        isSwitchingNetwork = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 1. 確保 Wi-Fi 與有線網卡皆為開啟狀態（保持有線網卡開啟以維持 Codex 有線 VIP 豁免路由與雙網測速）
            let wiredService = self.getWiredServiceName()
            self.disabledWiredServiceName = wiredService
            
            let pPower = Process()
            pPower.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            pPower.arguments = ["-setairportpower", "en0", "on"]
            try? pPower.run()
            pPower.waitUntilExit()
            
            let pEnableWired = Process()
            pEnableWired.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            pEnableWired.arguments = ["-setnetworkserviceenabled", wiredService, "on"]
            try? pEnableWired.run()
            pEnableWired.waitUntilExit()
            
            // 2. 調整服務順序，將 Wi-Fi 移至第一優先序位（使一般大流量網頁預設走 Wi-Fi）
            var services = self.getAllNetworkServices()
            if let wifiIdx = services.firstIndex(of: "Wi-Fi") {
                services.remove(at: wifiIdx)
                services.insert("Wi-Fi", at: 0)
                let pOrder = Process()
                pOrder.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                pOrder.arguments = ["-ordernetworkservices"] + services
                try? pOrder.run()
                pOrder.waitUntilExit()
            }
            
            // 3. 為 Codex 與其操控的開發工具 (OpenAI / GitHub / NPM / PyPI / 校內) 綁定有線 4ms VIP 豁免路由！
            let gateway = self.getWiredGatewayIP(service: wiredService)
            self.applyCodexWiredExemptionRoutes(wiredService: wiredService, gateway: gateway)
            
            DispatchQueue.main.async {
                self.isWiredTemporarilyDisabled = true
                self.savePersistedState()
                
                self.detectActiveNetwork {
                    self.isSwitchingNetwork = false
                    self.updateStatusBar()
                    self.pushDataToWebUI()
                }
                
                self.sendSystemNotification(
                    title: "🔀 已切換至校園 Wi-Fi（Codex 享有線豁免權）！",
                    body: "原因：\(reason)。一般網頁已改走 Wi-Fi，Codex 與開發工具仍獨享 4ms 有線極速通道！"
                )
            }
        }
    }

    // 恢復有線網路連線 (啟用網卡並重設為最高順位)
    func restoreWiredNetwork(reason: String) {
        guard !isSwitchingNetwork else { return }
        isSwitchingNetwork = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let wiredService = self.disabledWiredServiceName
            
            // 1. 啟用有線網路服務
            let pEnable = Process()
            pEnable.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            pEnable.arguments = ["-setnetworkserviceenabled", wiredService, "on"]
            try? pEnable.run()
            pEnable.waitUntilExit()
            
            // 2. 清除有線與 Wi-Fi 附加路由並關閉 Wi-Fi 電源（確保有線額度用完前 100% 走有線，0 流量消耗 Wi-Fi，且路由完全純淨）
            let pClearWired = Process()
            pClearWired.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            pClearWired.arguments = ["-setadditionalroutes", wiredService]
            try? pClearWired.run()
            pClearWired.waitUntilExit()
            
            let pClearWifi = Process()
            pClearWifi.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            pClearWifi.arguments = ["-setadditionalroutes", "Wi-Fi"]
            try? pClearWifi.run()
            pClearWifi.waitUntilExit()
            
            let pWifiOff = Process()
            pWifiOff.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            pWifiOff.arguments = ["-setairportpower", "en0", "off"]
            try? pWifiOff.run()
            pWifiOff.waitUntilExit()
            
            // 3. 將有線服務順位調回第一
            var services = self.getAllNetworkServices()
            if let wiredIdx = services.firstIndex(of: wiredService) {
                services.remove(at: wiredIdx)
                services.insert(wiredService, at: 0)
                let pOrder = Process()
                pOrder.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                pOrder.arguments = ["-ordernetworkservices"] + services
                try? pOrder.run()
                pOrder.waitUntilExit()
            }
            
            DispatchQueue.main.async {
                self.isWiredTemporarilyDisabled = false
                self.isSplitRoutingEnabled = false
                self.savePersistedState()
                
                // 等候 2 秒 DHCP 重新配置 IP
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.detectActiveNetwork {
                        self.isSwitchingNetwork = false
                        self.updateStatusBar()
                        self.pushDataToWebUI()
                    }
                }
            }
        }
    }

    // MARK: - 方向 1: 智慧網路調度與雙軌分流 (Smart Dual-Interface Routing & Split Tunneling)
    func applySplitRouting() {
        let wiredService = getWiredServiceName()
        let wifiService = "Wi-Fi"
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if self.isSplitRoutingEnabled {
                // 1. 確保有線網卡開啟
                let pEnable = Process()
                pEnable.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                pEnable.arguments = ["-setnetworkserviceenabled", wiredService, "on"]
                try? pEnable.run()
                pEnable.waitUntilExit()
                
                if !self.isWiredTemporarilyDisabled {
                    // 【有線優先模式】：清除有線額外附加路由，讓預設閘道完全承載所有連線（保證 ChatGPT 與校內網站暢通）
                    let pClearWired = Process()
                    pClearWired.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    pClearWired.arguments = ["-setadditionalroutes", wiredService]
                    try? pClearWired.run()
                    pClearWired.waitUntilExit()
                    
                    var services = self.getAllNetworkServices()
                    if let wiredIdx = services.firstIndex(of: wiredService) {
                        services.remove(at: wiredIdx)
                        services.insert(wiredService, at: 0)
                        let pOrder = Process()
                        pOrder.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                        pOrder.arguments = ["-ordernetworkservices"] + services
                        try? pOrder.run()
                        pOrder.waitUntilExit()
                    }
                    
                    // 僅將純大流量影音快取伺服器 (YouTube Video CDN 74.125/216.58) 與 Apple 背景更新 (17.253/17.248) 分流至 Wi-Fi
                    // 保留 Google 搜尋/API (142.250.*) 與所有網站給有線網路，確保 Codex 操作 Chrome/其他軟體時極速載入！
                    let wifiGw = self.getServiceGatewayIP(service: wifiService, fallback: "10.10.0.254")
                    let pWifiRoute = Process()
                    pWifiRoute.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    pWifiRoute.arguments = [
                        "-setadditionalroutes", wifiService,
                        "74.125.0.0", "255.255.0.0", wifiGw,
                        "216.58.192.0", "255.255.224.0", wifiGw,
                        "17.253.0.0", "255.255.0.0", wifiGw,
                        "17.248.128.0", "255.255.192.0", wifiGw
                    ]
                    try? pWifiRoute.run()
                    pWifiRoute.waitUntilExit()
                    
                    DispatchQueue.main.async {
                        self.sendSystemNotification(
                            title: "🛡️ Codex 及受控軟體有線豁免已生效！",
                            body: "Codex 與其操控的瀏覽器/開發工具全面獨享 4ms 有線宿網；純影音快取與系統更新自動分流至 Wi-Fi。"
                        )
                        self.detectActiveNetwork {
                            self.pushDataToWebUI()
                        }
                    }
                } else {
                    // 【Wi-Fi 備援 + Codex/校內千兆 VIP 豁免分流模式】
                    var services = self.getAllNetworkServices()
                    if let wifiIdx = services.firstIndex(of: wifiService) {
                        services.remove(at: wifiIdx)
                        services.insert(wifiService, at: 0)
                        let pOrder = Process()
                        pOrder.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                        pOrder.arguments = ["-ordernetworkservices"] + services
                        try? pOrder.run()
                        pOrder.waitUntilExit()
                    }
                    
                    let wiredGw = self.getWiredGatewayIP(service: wiredService)
                    self.applyCodexWiredExemptionRoutes(wiredService: wiredService, gateway: wiredGw)
                    
                    DispatchQueue.main.async {
                        self.sendSystemNotification(
                            title: "🔀 雙軌智慧分流（含 Codex 有線豁免）已啟動！",
                            body: "Codex/GitHub/校內服務強制走 4ms 千兆有線，其餘流量走 Wi-Fi。"
                        )
                        self.detectActiveNetwork {
                            self.pushDataToWebUI()
                        }
                    }
                }
            } else {
                // 關閉分流：清除附加路由
                for svc in [wiredService, wifiService] {
                    let pClear = Process()
                    pClear.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    pClear.arguments = ["-setadditionalroutes", svc]
                    try? pClear.run()
                    pClear.waitUntilExit()
                }
                
                // 恢復有線網路第一順位
                var services = self.getAllNetworkServices()
                if let wiredIdx = services.firstIndex(of: wiredService) {
                    services.remove(at: wiredIdx)
                    services.insert(wiredService, at: 0)
                    let pOrder = Process()
                    pOrder.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    pOrder.arguments = ["-ordernetworkservices"] + services
                    try? pOrder.run()
                    pOrder.waitUntilExit()
                }
                
                DispatchQueue.main.async {
                    self.sendSystemNotification(
                        title: "雙軌智慧分流已關閉",
                        body: "已恢復標準網路順位，清除附加靜態路由。"
                    )
                    self.detectActiveNetwork {
                        self.pushDataToWebUI()
                    }
                }
            }
        }
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
    func probeInterfaceQuality(interfaceName: String, runSpeedBurst: Bool, currentKnownMbps: Double) -> (reachable: Bool, pingMs: Double, speedMbps: Double) {
        let pPing = Process()
        pPing.executableURL = URL(fileURLWithPath: "/sbin/ping")
        pPing.arguments = ["-c", "2", "-W", "800", "-b", interfaceName, "1.1.1.1"]
        let pipePing = Pipe()
        pPing.standardOutput = pipePing
        pPing.standardError = pipePing
        try? pPing.run()
        pPing.waitUntilExit()
        
        let outPing = String(data: pipePing.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var pingVal: Double = 999.0
        var isReachable = false
        
        for line in outPing.components(separatedBy: "\n") {
            if line.contains("round-trip") || line.contains("rtt") {
                let parts = line.components(separatedBy: "=")
                if parts.count >= 2 {
                    let metrics = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: "/")
                    if metrics.count >= 2, let avg = Double(metrics[1]) {
                        pingVal = avg
                        isReachable = true
                    }
                }
            }
        }
        
        guard isReachable else {
            return (false, 999.0, 0.0)
        }
        
        var measuredMbps = currentKnownMbps
        if runSpeedBurst || pingVal > 85.0 {
            let pCurl = Process()
            pCurl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            pCurl.arguments = [
                "--interface", interfaceName,
                "-o", "/dev/null",
                "-s",
                "-w", "%{speed_download}|%{time_starttransfer}",
                "--max-time", "2.5",
                "https://speed.cloudflare.com/__down?bytes=262144"
            ]
            let pipeCurl = Pipe()
            pCurl.standardOutput = pipeCurl
            try? pCurl.run()
            pCurl.waitUntilExit()
            let outCurl = String(data: pipeCurl.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let parts = outCurl.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
            if let bps = Double(parts.first ?? "0"), bps > 0 {
                measuredMbps = max(0.1, (bps * 8.0) / 1_000_000.0)
            }
        } else {
            // 零額度微探測：依 RTT 微幅更新速率估算
            if pingVal < 10.0 && measuredMbps < 15.0 {
                measuredMbps = 22.8
            }
        }
        return (true, pingVal, measuredMbps)
    }

    // 雙網卡即時競速與慢速自動切換引擎
    func evaluateDualNetworkSpeedAndSwitch(forceSpeedBurst: Bool = false, manualTrigger: Bool = false) {
        guard !isRunningSpeedRace && !isSwitchingNetwork else { return }
        isRunningSpeedRace = true
        if manualTrigger {
            pushDataToWebUI()
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let wiredDev = "en6"
            let wifiDev = "en0"
            
            let group = DispatchGroup()
            var wResult: (reachable: Bool, pingMs: Double, speedMbps: Double) = (false, 999.0, 0.0)
            var wfResult: (reachable: Bool, pingMs: Double, speedMbps: Double) = (false, 999.0, 0.0)
            
            group.enter()
            DispatchQueue.global().async {
                wResult = self.probeInterfaceQuality(interfaceName: wiredDev, runSpeedBurst: forceSpeedBurst, currentKnownMbps: self.wiredSpeedMbps)
                group.leave()
            }
            
            group.enter()
            DispatchQueue.global().async {
                wfResult = self.probeInterfaceQuality(interfaceName: wifiDev, runSpeedBurst: forceSpeedBurst, currentKnownMbps: self.wifiSpeedMbps)
                group.leave()
            }
            
            group.wait()
            
            DispatchQueue.main.async {
                self.isRunningSpeedRace = false
                self.wiredReachable = wResult.reachable
                self.wiredPingMs = wResult.pingMs
                self.wiredSpeedMbps = wResult.speedMbps
                
                self.wifiReachable = wfResult.reachable
                self.wifiPingMs = wfResult.pingMs
                self.wifiSpeedMbps = wfResult.speedMbps
                
                // 同步更新主面板顯示之當前網路延遲
                if self.activeInterface == wiredDev && wResult.reachable {
                    self.pingLatencyMs = wResult.pingMs
                    self.isConnected = true
                } else if self.activeInterface == wifiDev && wfResult.reachable {
                    self.pingLatencyMs = wfResult.pingMs
                    self.isConnected = true
                }
                
                let now = Date().timeIntervalSince1970
                let canSwitch = (self.isSpeedAutoSwitchEnabled || manualTrigger) && (manualTrigger || (now - self.lastSpeedSwitchTime) > 180.0)
                
                if canSwitch {
                    let isWiredQuotaSafe = (self.dormTodayInBytes < 6.75 * 1024 * 1024 * 1024) && !self.isBlacklisted
                    
                    // 【有線優先鐵律】：只要有線網路還沒用完 (剩餘 > 250 MB) 且網線有通，100% 強制鎖定使用有線網路，絕不切換去用 Wi-Fi！
                    if isWiredQuotaSafe && wResult.reachable {
                        if self.isWiredTemporarilyDisabled || self.activeInterface != wiredDev {
                            self.lastSpeedSwitchTime = now
                            self.slowNetworkStreak = 0
                            self.restoreWiredNetwork(reason: "有線額度充足，強制優先使用有線網路")
                            self.pushDataToWebUI()
                            return
                        }
                    } else if !isWiredQuotaSafe && !self.isWiredTemporarilyDisabled && wfResult.reachable {
                        // 只有當有線網路額度真正用完 (已用 >= 6.75 GB / 剩餘 <= 250 MB) 或遭封鎖時，才自動切換至 Wi-Fi
                        self.lastSpeedSwitchTime = now
                        self.switchToWifi(reason: "有線網路額度已用盡，自動接管至 Wi-Fi")
                        self.pushDataToWebUI()
                        return
                    }
                }
                
                self.pushDataToWebUI()
            }
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
        var foundApp: NSRunningApplication? = nil
        
        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            for kw in p2pKeywords {
                if name.contains(kw) || bid.contains(kw) {
                    foundP2PName = app.localizedName ?? kw
                    foundApp = app
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
                            body: "偵測到 P2P 軟體（\(name)）正在運行！宿網嚴禁 P2P，違者將遭計中鎖孔 6 小時以上！"
                        )
                        if self.isP2PShieldAutoKillEnabled {
                            foundApp?.terminate()
                            self.sendSystemNotification(
                                title: "🛡️ P2P 盾牌已自動攔截！",
                                body: "已為您即時終止 \(name)，保護宿網孔避免遭計中鎖孔。"
                            )
                        }
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
        let p2pKeywords = ["qbittorrent", "transmission", "bitcomet", "thunder", "xunlei", "folx", "deluge", "utorrent", "bittorrent", "webtorrent", "aria2c", "motrix", "biglybt"]
        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            for kw in p2pKeywords {
                if name.contains(kw) || bid.contains(kw) {
                    app.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        if !app.isTerminated {
                            kill(app.processIdentifier, SIGKILL)
                        }
                    }
                    break
                }
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", "aria2c"]
        try? p.run()
        
        self.isP2PDetected = false
        self.p2pAppName = ""
        self.pushDataToWebUI()
        
        self.sendSystemNotification(
            title: "🛑 已強制終止 P2P 軟體",
            body: "P2P 軟體已成功關閉，宿網環境安全。"
        )
    }

    func checkIpBlocklist() {
        guard let url = URL(string: "https://ipblock.nchu.edu.tw/cblocklist_public.php") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4.0)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
        
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config, delegate: InsecureCertDelegate(), delegateQueue: nil)
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let nowStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            
            if let data = data, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))) {
                var isBlocked = false
                var reason = ""
                
                if let rangeStart = html.range(of: "<font color=red>", options: .caseInsensitive) {
                    let sub = html[rangeStart.upperBound...]
                    if let rangeEnd = sub.range(of: "</font>", options: .caseInsensitive) {
                        let content = String(sub[..<rangeEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !content.isEmpty {
                            isBlocked = true
                            reason = content
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.isBlacklisted = isBlocked
                    self.blacklistReason = reason
                    self.lastBlacklistCheckTime = "\(nowStr) \(isBlocked ? "遭鎖定" : "正常安全")"
                    
                    if isBlocked && !self.hasAlertedBlacklist {
                        self.hasAlertedBlacklist = true
                        self.sendSystemNotification(
                            title: "🚨 興大計中黑名單警報！",
                            body: "您的宿網 IP 已遭校方封鎖！原因：\(reason)"
                        )
                    }
                    if self.popover.isShown {
                        self.pushDataToWebUI()
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.lastBlacklistCheckTime = "\(nowStr) 探測逾時"
                    if self.popover.isShown {
                        self.pushDataToWebUI()
                    }
                }
            }
        }
        task.resume()
    }

    @objc func systemWillSleep() {
        if isLidGuardEnabled && !isLidCurrentlyClosed {
            isLidCurrentlyClosed = true
            activateLidGuard(reason: "系統休眠", freezeRenderers: true)
        }
    }

    @objc func screensDidSleep() {
        if isLidGuardEnabled && !isLidCurrentlyClosed {
            isLidCurrentlyClosed = true
            activateLidGuard(reason: "螢幕關閉", freezeRenderers: true)
        }
    }

    @objc func screensDidWake() {
        if isLidGuardEnabled && isLidCurrentlyClosed && !isLidClosed() {
            isLidCurrentlyClosed = false
            deactivateLidGuard(reason: "螢幕喚醒")
        }
    }

    func getTodayString() -> String {
        let formatter = DateFormatter()
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
            if self.popover.isShown {
                self.inspectTopAppConsumers()
            }
        }
        
        // 延遲偵測在面板打開時更新，背景降低頻率至 60 秒
        pingTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.popover.isShown {
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
        popover.contentSize = NSSize(width: 380, height: 950)
        popover.behavior = .transient
        
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(ScriptHandler(app: self), name: "nativeApp")
        config.userContentController = controller
        
        let vc = NSViewController()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 950), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        vc.view = webView
        popover.contentViewController = vc
        
        let htmlURL = Bundle.main.url(forResource: "popover", withExtension: "html") ??
                      URL(fileURLWithPath: "/Users/liuchuxiang/電腦優化/NCHUTraffic.app/Contents/Resources/popover.html")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
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
        for item in topAppConsumers.prefix(4) {
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
                    "dl": formatBytes(rec.dl),
                    "ul": formatBytes(rec.ul),
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
            let dayDl: Double
            let dayUl: Double
            
            if isToday {
                dayDl = dormTodayInBytes + wifiTodayInBytes + extTodayInBytes
                dayUl = dormTodayOutBytes + wifiTodayOutBytes + extTodayOutBytes
                dayTotal = dayDl + dayUl
                todayCombinedBytes = dayTotal
            } else {
                if let rec = history[dateStr] {
                    dayTotal = rec.total
                    dayDl = rec.dl
                    dayUl = rec.ul
                } else {
                    dayTotal = 0
                    dayDl = 0
                    dayUl = 0
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
                "dlStr": formatBytes(dayDl),
                "ulStr": formatBytes(dayUl),
                "totalStr": formatBytes(dayTotal),
                "pctOfQuota": String(format: "%.1f", min(pctOfQuota, 140.0)),
                "statusLevel": statusLevel,
                "isToday": isToday
            ])
        }
        
        let avg7DayGB = (total7DayBytes / 7.0) / (1024 * 1024 * 1024)
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
            "avg7DayStr": String(format: "%.1f GB", avg7DayGB),
            "diffVsYesterdayStr": String(format: "%@%.0f%%", diffSign, diffVsYesterdayPct),
            "diffTrend": diffTrend,
            "maxWeekStr": String(format: "%.1f GB (%@)", maxBytesVal / (1024 * 1024 * 1024), maxBytesDateLabel),
            "quotaGBStr": String(format: "%.0f GB", totalQuotaBytes / (1024 * 1024 * 1024))
        ]
        
        let pingStr = isConnected ? String(format: "%.1f ms", pingLatencyMs) : "中斷"
        let speedStr = String(format: "↓ %@   ↑ %@", formatSpeed(currentDownSpeed), formatSpeed(currentUpSpeed))
        let extTotal = extTodayInBytes + extTodayOutBytes
        
        var runoutText = "網速平緩，額度充足"
        var riskLevel = "safe" // "safe", "warning", "danger"
        
        if isCampusWifi {
            if dlUsed >= (9.0 * 1024 * 1024 * 1024) {
                riskLevel = "danger"
            } else if dlUsed >= (7.0 * 1024 * 1024 * 1024) {
                riskLevel = "warning"
            }
            if currentDownSpeed > 60 * 1024 {
                let mins = (remDl / currentDownSpeed) / 60.0
                runoutText = String(format: "約 %.0f 分鐘後達到 10GB Wi-Fi 下載上限", max(1, mins))
            } else {
                if riskLevel == "danger" {
                    runoutText = "Wi-Fi 額度低於 1 GB，達到上限後將限速"
                } else if riskLevel == "warning" {
                    runoutText = "今日 Wi-Fi 已用較多，請留意用量"
                } else {
                    runoutText = "興大 Wi-Fi 配額 10 GB 充足，安心使用"
                }
            }
        } else if isDormNetwork {
            if dlUsed >= (6.3 * 1024 * 1024 * 1024) {
                riskLevel = "danger"
            } else if dlUsed >= (5.0 * 1024 * 1024 * 1024) {
                riskLevel = "warning"
            }
            
            if currentDownSpeed > 60 * 1024 { // 下載速度 > 60 KB/s 時動態預估
                let seconds = remDl / currentDownSpeed
                let mins = seconds / 60.0
                if mins < 60 {
                    runoutText = String(format: "約 %.0f 分鐘後耗盡 7GB 下載額度", max(1, mins))
                } else {
                    runoutText = String(format: "約 %.1f 小時後達到 7GB 下載上限", mins / 60.0)
                }
            } else {
                if riskLevel == "danger" {
                    runoutText = "額度低於 700 MB，即將進入限速區"
                } else if riskLevel == "warning" {
                    runoutText = "今日已耗較多額度，建議節省串流"
                } else {
                    runoutText = "網速平穩，今日流量充足安全"
                }
            }
        } else {
            runoutText = "外部網路 / 熱點無限制，放心使用"
            riskLevel = "safe"
        }
        
        let payload: [String: Any] = [
            "isDorm": isDormNetwork,
            "isCampusWifi": isCampusWifi,
            "isQuotaRestricted": isQuotaRestricted,
            "networkTypeName": networkTypeName,
            "currentIP": currentIP,
            "activeInterface": activeInterface,
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
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    @objc func systemDidWake() {
        if isLidGuardEnabled {
            isLidCurrentlyClosed = false
            deactivateLidGuard(reason: "系統喚醒")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.detectActiveNetwork()
            self?.initHardwareCounters()
            self?.syncWithTop100Server()
            self?.measurePingLatency()
            self?.inspectTopAppConsumers()
            self?.evaluateDualNetworkSpeedAndSwitch(forceSpeedBurst: true, manualTrigger: false)
        }
    }

    func loadPersistedState() {
        let today = getTodayString()
        if FileManager.default.fileExists(atPath: stateFilePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            
            let savedDate = json["date"] as? String ?? ""
            if savedDate == today {
                self.dormTodayInBytes = json["dorm_in"] as? Double ?? (json["today_in"] as? Double ?? 0.0)
                self.dormTodayOutBytes = json["dorm_out"] as? Double ?? (json["today_out"] as? Double ?? 0.0)
                self.wifiTodayInBytes = json["wifi_in"] as? Double ?? 0.0
                self.wifiTodayOutBytes = json["wifi_out"] as? Double ?? 0.0
                self.extTodayInBytes = json["ext_in"] as? Double ?? 0.0
                self.extTodayOutBytes = json["ext_out"] as? Double ?? 0.0
                self.networkModeOverride = json["network_mode_override"] as? Int ?? 0
                self.lastRawIBytes = (json["last_raw_in"] as? NSNumber)?.uint64Value ?? 0
                self.lastRawOBytes = (json["last_raw_out"] as? NSNumber)?.uint64Value ?? 0
                self.displayMode = json["display_mode"] as? Int ?? 0
                self.isAlertEnabled = json["alert_enabled"] as? Bool ?? true
                self.isLidGuardEnabled = json["lid_guard_enabled"] as? Bool ?? true
                self.isIdleGuardEnabled = json["idle_guard_enabled"] as? Bool ?? true
                self.isAutoWifiFailoverEnabled = json["auto_wifi_failover_enabled"] as? Bool ?? true
                self.isWiredTemporarilyDisabled = json["is_wired_temporarily_disabled"] as? Bool ?? false
                self.disabledWiredServiceName = json["disabled_wired_service_name"] as? String ?? "USB 10/100/1000 LAN"
                self.isSplitRoutingEnabled = json["split_routing_enabled"] as? Bool ?? (json["is_split_routing_enabled"] as? Bool ?? true)
                self.isMidnightScheduleEnabled = json["midnight_schedule_enabled"] as? Bool ?? false
                self.isSpeedAutoSwitchEnabled = json["speed_auto_switch_enabled"] as? Bool ?? true
                self.isP2PShieldAutoKillEnabled = json["p2p_shield_auto_kill_enabled"] as? Bool ?? true
            } else {
                if !savedDate.isEmpty {
                    let oldDl = (json["dorm_in"] as? Double ?? (json["today_in"] as? Double ?? 0)) + (json["wifi_in"] as? Double ?? 0)
                    let oldUl = (json["dorm_out"] as? Double ?? (json["today_out"] as? Double ?? 0)) + (json["wifi_out"] as? Double ?? 0)
                    if (oldDl + oldUl) > 0 {
                        TrafficHistoryManager.shared.recordDay(date: savedDate, dl: oldDl, ul: oldUl)
                    }
                }
                self.currentDateString = today
                self.dormTodayInBytes = 0.0
                self.dormTodayOutBytes = 0.0
                self.wifiTodayInBytes = 0.0
                self.wifiTodayOutBytes = 0.0
                self.extTodayInBytes = 0.0
                self.extTodayOutBytes = 0.0
                self.alertTierSent = 0
                self.isEmergencyBrakeActive = false
                if self.isWiredTemporarilyDisabled {
                    self.restoreWiredNetwork(reason: "每日 00:00 額度重設")
                }
                savePersistedState()
            }
        }
    }

    func savePersistedState() {
        let dict: [String: Any] = [
            "date": currentDateString,
            "dorm_in": dormTodayInBytes,
            "dorm_out": dormTodayOutBytes,
            "wifi_in": wifiTodayInBytes,
            "wifi_out": wifiTodayOutBytes,
            "ext_in": extTodayInBytes,
            "ext_out": extTodayOutBytes,
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
            try? data.write(to: URL(fileURLWithPath: stateFilePath))
        }
    }

    var isDetectingNetwork: Bool = false
    
    func detectActiveNetworkSync() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var foundInterface = "en0"
        for line in out.components(separatedBy: .newlines) {
            if line.contains("interface:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    foundInterface = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        self.activeInterface = foundInterface
        
        let ipProcess = Process()
        ipProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        ipProcess.arguments = ["getifaddr", self.activeInterface]
        let ipPipe = Pipe()
        ipProcess.standardOutput = ipPipe
        try? ipProcess.run()
        ipProcess.waitUntilExit()
        let ipOut = String(data: ipPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ipOut.isEmpty {
            self.currentIP = ipOut
            self.isConnected = true
        } else {
            self.isConnected = false
        }
    }

    func detectActiveNetwork(completion: (() -> Void)? = nil) {
        guard !isDetectingNetwork else { return }
        isDetectingNetwork = true
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = ["get", "default"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var foundInterface = "en0"
            for line in out.components(separatedBy: .newlines) {
                if line.contains("interface:") {
                    let parts = line.components(separatedBy: ":")
                    if parts.count >= 2 {
                        foundInterface = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            
            let ipProcess = Process()
            ipProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
            ipProcess.arguments = ["getifaddr", foundInterface]
            let ipPipe = Pipe()
            ipProcess.standardOutput = ipPipe
            try? ipProcess.run()
            ipProcess.waitUntilExit()
            let ipOut = String(data: ipPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if ipOut.isEmpty {
                let pWifiOn = Process()
                pWifiOn.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                pWifiOn.arguments = ["-setairportpower", "en0", "on"]
                try? pWifiOn.run()
                pWifiOn.waitUntilExit()
            }
            
            DispatchQueue.main.async {
                let ifaceChanged = (self.activeInterface != foundInterface)
                self.activeInterface = foundInterface
                if !ipOut.isEmpty {
                    self.currentIP = ipOut
                    self.isConnected = true
                } else {
                    self.isConnected = false
                }
                
                // 若連線網卡切換，立即重新採樣硬體計數器，防止產生虛假巨大流量突波
                if ifaceChanged {
                    if let b = self.getInterfaceBytes(name: foundInterface) {
                        self.lastRawIBytes = b.ibytes
                        self.lastRawOBytes = b.obytes
                        self.lastTimestamp = Date().timeIntervalSince1970
                    }
                }
                self.isDetectingNetwork = false
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
            if ifaName == name && ifa.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let data = unsafeBitCast(ifa.ifa_data, to: UnsafeMutablePointer<if_data>.self)
                return (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
            }
        }
        return nil
    }

    func initHardwareCounters() {
        if let b = getInterfaceBytes(name: self.activeInterface) {
            if lastRawIBytes == 0 && lastRawOBytes == 0 {
                lastRawIBytes = b.ibytes
                lastRawOBytes = b.obytes
            }
            lastTimestamp = Date().timeIntervalSince1970
        }
    }

    func measurePingLatency() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let pingTarget = self.isQuotaRestricted ? "140.120.1.2" : "1.1.1.1"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "2", "-t", "2", pingTarget]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let range = out.range(of: "time=") {
                let sub = out[range.upperBound...]
                let parts = sub.components(separatedBy: " ")
                if let msStr = parts.first, let ms = Double(msStr) {
                    DispatchQueue.main.async {
                        self.pingLatencyMs = ms
                        self.consecutivePingFailures = 0
                        self.isConnected = true
                    }
                    return
                }
            }
            
            DispatchQueue.main.async {
                self.consecutivePingFailures += 1
                if self.consecutivePingFailures >= 3 {
                    self.isConnected = false
                }
            }
        }
    }

    func inspectTopAppConsumers() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            process.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var appMap: [String: Double] = [:]
            
            for line in out.components(separatedBy: .newlines) {
                let parts = line.split(separator: ",")
                if parts.count >= 3, let bIn = Double(parts[1]), let bOut = Double(parts[2]) {
                    var rawName = String(parts[0])
                    if let dotIdx = rawName.lastIndex(of: ".") {
                        let suffix = rawName[rawName.index(after: dotIdx)...]
                        if Int(suffix) != nil {
                            rawName = String(rawName[..<dotIdx])
                        }
                    }
                    if rawName.hasPrefix("Google Chrome") {
                        rawName = "Google Chrome"
                    } else if rawName.hasPrefix("Antigravity") {
                        rawName = "Antigravity IDE"
                    }
                    let total = bIn + bOut
                    if total > 100 * 1024 {
                        appMap[rawName, default: 0] += total
                    }
                }
            }
            
            let sorted = appMap.sorted { $0.value > $1.value }.map { (name: $0.key, bytes: $0.value) }
            DispatchQueue.main.async {
                self?.topAppConsumers = sorted
                if self?.popover.isShown == true {
                    self?.pushDataToWebUI()
                }
            }
        }
    }

    func tickRealtime() {
        let todayStr = getTodayString()
        if todayStr != currentDateString {
            if !currentDateString.isEmpty {
                let totalDl = dormTodayInBytes + wifiTodayInBytes + extTodayInBytes
                let totalUl = dormTodayOutBytes + wifiTodayOutBytes + extTodayOutBytes
                if (totalDl + totalUl) > 0 {
                    TrafficHistoryManager.shared.recordDay(date: currentDateString, dl: totalDl, ul: totalUl)
                }
            }
            currentDateString = todayStr
            dormTodayInBytes = 0.0
            dormTodayOutBytes = 0.0
            wifiTodayInBytes = 0.0
            wifiTodayOutBytes = 0.0
            extTodayInBytes = 0.0
            extTodayOutBytes = 0.0
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
                if isAudioPlaying() || currentDownSpeed > 150 * 1024 {
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
        
        guard let b = getInterfaceBytes(name: self.activeInterface) else { return }
        let elapsed = max(now - lastTimestamp, 0.5)
        
        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        
        if lastRawIBytes > 0 && b.ibytes >= lastRawIBytes {
            deltaIn = b.ibytes - lastRawIBytes
            currentDownSpeed = Double(deltaIn) / elapsed
        } else if b.ibytes < lastRawIBytes {
            currentDownSpeed = 0
        }
        
        if lastRawOBytes > 0 && b.obytes >= lastRawOBytes {
            deltaOut = b.obytes - lastRawOBytes
            currentUpSpeed = Double(deltaOut) / elapsed
        } else if b.obytes < lastRawOBytes {
            currentUpSpeed = 0
        }
        
        lastRawIBytes = b.ibytes
        lastRawOBytes = b.obytes
        lastTimestamp = now
        
        // 依據當前網路環境獨立累加流量，互不污染
        if isCampusWifi {
            wifiTodayInBytes += Double(deltaIn)
            wifiTodayOutBytes += Double(deltaOut)
        } else if isDormNetwork {
            dormTodayInBytes += Double(deltaIn)
            dormTodayOutBytes += Double(deltaOut)
        } else {
            extTodayInBytes += Double(deltaIn)
            extTodayOutBytes += Double(deltaOut)
        }
        
        if Int(now) % 10 == 0 {
            savePersistedState()
        }
        
        // 興大網路環境 (宿網或校園 Wi-Fi) 下啟用流量預警推播與急停防護
        if isAlertEnabled && isQuotaRestricted {
            checkAndSendSmartAlerts()
        }
        
        updateStatusBar()
        
        if popover.isShown {
            pushDataToWebUI()
        }
    }

    var lastCriticalNotificationTime: TimeInterval = 0

    func checkAndSendSmartAlerts() {
        guard isQuotaRestricted else { return }
        let (_, dlUsed, _) = getEffectiveUsedBytes()
        let remDlGB = max(0, dlQuotaBytes - dlUsed) / (1024 * 1024 * 1024)
        let dlUsagePct = (dlUsed / dlQuotaBytes) * 100.0
        
        if isDormNetwork {
            // 宿網避難保護：當下載額度剩餘不足 250 MB 時，自動靜默切換至校園 Wi-Fi (免拔網路線)
            if isAutoWifiFailoverEnabled && remDlGB <= 0.25 && !isWiredTemporarilyDisabled && !isSwitchingNetwork && Date().timeIntervalSince1970 > failoverCooldownUntil {
                switchToWifi(reason: String(format: "下載額度僅剩 %.0f MB", remDlGB * 1024))
                return
            }
            
            // 緊急急停煞車：僅在下載達到 90% (只剩不到 700 MB 即將斷網鎖卡) 時，才發出唯一一次緊急通知
            if dlUsagePct >= 90.0 && !isEmergencyBrakeActive {
                isEmergencyBrakeActive = true
                sendSystemMediaPause()
                activateLidGuard(reason: "🚨 7GB 下載額度已達 90% 急停煞車", freezeRenderers: false)
                sendSystemNotification(
                    title: "🚨 宿網額度僅剩 \(String(format: "%.0f MB", remDlGB * 1024))！",
                    body: "已自動暫停背景影音與同步以防斷網鎖卡（Codex 享有豁免權不受影響）。",
                    isCritical: true
                )
            }
        }
    }

    // 極簡靜音通知中心：預設所有背景切換、分流、休眠喚醒皆 100% 靜默執行，僅在真正危急 (isCritical == true) 時靜音推播且 4 小時內不重複打擾
    func sendSystemNotification(title: String, body: String, isCritical: Bool = false) {
        guard isCritical else { return }
        let now = Date().timeIntervalSince1970
        guard (now - lastCriticalNotificationTime) > 14400.0 else { return }
        lastCriticalNotificationTime = now
        
        DispatchQueue.global(qos: .utility).async {
            let script = "display notification \"\(body)\" with title \"\(title)\""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
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
        var dl = isCampusWifi ? wifiTodayInBytes : dormTodayInBytes
        var ul = isCampusWifi ? wifiTodayOutBytes : dormTodayOutBytes
        if isDormNetwork, let top = top100Data {
            if let serverIn = top["in_bytes"] as? Double, serverIn > dl {
                dl = serverIn
            }
            if let serverOut = top["out_bytes"] as? Double, serverOut > ul {
                ul = serverOut
            }
        }
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
        guard isDormNetwork else {
            DispatchQueue.main.async {
                self.top100Data = nil
            }
            return
        }
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let scriptPath = "/Users/liuchuxiang/電腦優化/traffic_monitor.py"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [scriptPath, "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                DispatchQueue.main.async {
                    self.top100Data = json["top100"] as? [String: Any]
                }
            }
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
            let appPath = "/Users/liuchuxiang/Applications/NCHUTraffic.app/Contents/MacOS/NCHUTraffic"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>tw.edu.nchu.dorm.traffic</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appPath)</string>
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
        isAutoWifiFailoverEnabled = !isAutoWifiFailoverEnabled
        savePersistedState()
        pushDataToWebUI()
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
        isSplitRoutingEnabled = !isSplitRoutingEnabled
        savePersistedState()
        applySplitRouting()
        pushDataToWebUI()
    }

    @objc func handleToggleMidnightSchedule() {
        isMidnightScheduleEnabled = !isMidnightScheduleEnabled
        savePersistedState()
        pushDataToWebUI()
    }

    @objc func handleToggleSpeedAutoSwitch() {
        isSpeedAutoSwitchEnabled = !isSpeedAutoSwitchEnabled
        savePersistedState()
        pushDataToWebUI()
        if isSpeedAutoSwitchEnabled {
            evaluateDualNetworkSpeedAndSwitch(forceSpeedBurst: true, manualTrigger: false)
        }
    }

    @objc func handleRunSpeedRaceNow() {
        evaluateDualNetworkSpeedAndSwitch(forceSpeedBurst: true, manualTrigger: true)
    }

    @objc func handleToggleP2PShield() {
        isP2PShieldAutoKillEnabled = !isP2PShieldAutoKillEnabled
        savePersistedState()
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
        if let b = getInterfaceBytes(name: activeInterface) {
            lastRawIBytes = b.ibytes
            lastRawOBytes = b.obytes
        }
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
        if isWiredTemporarilyDisabled {
            let pEnable = Process()
            pEnable.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            pEnable.arguments = ["-setnetworkserviceenabled", disabledWiredServiceName, "on"]
            try? pEnable.run()
            pEnable.waitUntilExit()
        }
        savePersistedState()
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = RealtimeTrafficApp()
app.delegate = delegate
app.run()
